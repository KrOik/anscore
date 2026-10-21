"""Cycle-exact RTL verification for DSP-08 carrier_loop + timing_loop.

Generates per-cycle fixtures (inputs + expected outputs) from the Python
cycle oracle (models/model.py), drives iverilog testbenches that compare
every output every cycle, then proves the checkers reject mutated fixtures.

Behavioural assertions (acquisition, lock, residual error, BER, pull/lock
range boundaries, graceful out-of-range behaviour) are evaluated on the
model trace; the TBs prove the RTL is bit-identical, so model assertions
transfer to the RTL.  Deterministic seeds only; no board access.
"""
import os, sys, json, math, random, subprocess, hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
import model as M

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(tool / 'bin') + os.pathsep + str(tool / 'lib')
               + os.pathsep + env['PATH'])
RTL_C = [BASE / 'rtl/nco.sv', BASE / 'rtl/pi_loop.sv',
         BASE / 'rtl/lock_det.sv', BASE / 'rtl/carrier_loop.sv']
RTL_T = [BASE / 'rtl/pi_loop.sv', BASE / 'rtl/lock_det.sv',
         BASE / 'rtl/timing_loop.sv']
rng = random.Random(0xD508)

report = {'carrier': {}, 'timing': {}}

# ============================================================================
# CARRIER LOOP fixture
#   cfg word: [31:0]fcw [36:32]kp [41:37]ki [57:42]lthr [65:58]ln [66]clear
#   row: rst sv sd mr cv cfgw | sr mv md lk lv fe ph cr cd ce
# ============================================================================
cm = M.CarrierCycle()
crows = []
cacc = []           # accepted input-sample index per row, -1 otherwise
cout = []           # (m_tvalid, m_tdata, lock, freq_est_s32, level) per row
cst = {'accepts': 0, 'outputs': 0, 'cfg_done': 0, 'cfg_err': 0,
       'resets': 0, 'stalls': 0, 'lockrise': []}
csample = 0
_prev_lock = 0


def cpack(c):
    if c is None:
        return 0
    return ((c.fcw & 0xFFFFFFFF)
            | (c.kp & 0x1F) << 32
            | (c.ki & 0x1F) << 37
            | (c.lthr & 0xFFFF) << 42
            | (c.ln & 0xFF) << 58
            | (c.clear & 1) << 66)


def ctick(rst=1, sv=0, sd=0, mr=1, cfg=None):
    global csample, _prev_lock
    cv = int(cfg is not None)
    o = cm.tick(rst=rst, sv=sv, sd=sd, mr=mr, cfg=cfg)
    crows.append('%d %d %x %d %d %x %d %d %x %d %x %x %x %d %d %d' % (
        rst, sv, sd & 0xFFFFFFFF, mr, cv, cpack(cfg),
        o['s_tready'], o['m_tvalid'], o['m_tdata'], o['lock'], o['level'],
        o['freq_est'], o['phase'], o['cfg_ready'], o['cfg_done'],
        o['cfg_error']))
    cout.append((o['m_tvalid'], o['m_tdata'], o['lock'],
                 M.s32(o['freq_est']), o['level']))
    if o['lock'] and not _prev_lock:
        cst['lockrise'].append(len(crows) - 1)
    _prev_lock = o['lock']
    if not rst:
        cst['resets'] += 1
        cacc.append(-1)
    else:
        if sv and o['s_tready']:
            cacc.append(csample)
            csample += 1
            cst['accepts'] += 1
        else:
            cacc.append(-1)
        if o['m_tvalid'] and mr:
            cst['outputs'] += 1
        if o['m_tvalid'] and not mr:
            cst['stalls'] += 1
        if o['cfg_done']:
            cst['cfg_done'] += 1
        if o['cfg_error']:
            cst['cfg_err'] += 1
    return o


def ccfg(cfg, fuzz=True):
    """Present cfg until the accept edge; wait for the done/error pulse."""
    for _ in range(20000):
        o = ctick(mr=int(rng.random() < .8 if fuzz else 1), cfg=cfg)
        if o['cfg_ready']:
            break
    else:
        raise AssertionError('carrier cfg accept timeout')
    for _ in range(64):
        o = ctick(mr=int(rng.random() < .8 if fuzz else 1))
        if o['cfg_done']:
            return o['cfg_done'], o['cfg_error']
    raise AssertionError('carrier cfg done timeout')


def cfeed(i, q, fuzz=True):
    if fuzz:
        while rng.random() < .25:      # occasional input gap (upstream holds)
            ctick(mr=int(rng.random() < .9))
    for _ in range(200000):
        o = ctick(sv=1, sd=((q & 0xFFFF) << 16) | (i & 0xFFFF),
                  mr=0 if (fuzz and rng.random() < .25) else 1)
        if o['s_tready']:
            return
    raise AssertionError('carrier feed timeout')


def cstream(I, Q, fuzz=True):
    for i, q in zip(I, Q):
        cfeed(i, q, fuzz=fuzz)


def cidle(n=8):
    for _ in range(n):
        ctick(mr=1)


def first_lockrise(start):
    r = [x for x in cst['lockrise'] if x >= start]
    return r[0] if r else None


# -- carrier stimulus program ------------------------------------------------
ctick(rst=0); ctick(rst=0); ctick(rst=0)

# segment A: acquire df=+Fs/64 at SPS=4, fuzzed handshakes
segA = len(crows)
baseA = csample
Ia, Qa, bits_a = M.gen_bpsk_iq(2500, 4, 1 / 64, A=0.7, seed=3)
cstream(Ia, Qa)
lr = first_lockrise(segA)
assert lr is not None, 'carrier never locked at df=+Fs/64'
report['carrier']['lock_cycle_df_p64'] = lr - segA
assert lr - segA < 8000, 'acquisition too slow'
fe = sum(o[3] for o in cout[-2000:] if o[0]) /     max(1, sum(1 for o in cout[-2000:] if o[0])) / 2.0**32
report['carrier']['freq_est_df_p64'] = fe
assert abs(fe - 1 / 64) < 2e-4, 'residual freq err %g' % abs(fe - 1 / 64)
tail_qr = [abs(M.s16((d >> 16) & 0xFFFF)) for v, d, lk, f, l in
           cout[-4000:] if v]
report['carrier']['mean_abs_Qr_postlock'] = sum(tail_qr) / len(tail_qr)
assert report['carrier']['mean_abs_Qr_postlock'] < 1500
# BER: m_tvalid in row r corresponds to the sample accepted at row r-1.
# BPSK Costas locking has an inherent +-180 deg ambiguity: resolve the
# polarity once from the first post-lock decisions, then count errors.
dec = []
for r in range(segA, len(crows)):
    v, d, lk, f, l = cout[r]
    a = cacc[r - 1]
    if v and a >= baseA and (a - baseA) % 4 == 2 and r > lr + 4000:
        dec.append(((1 if M.s16(d & 0xFFFF) >= 0 else -1),
                    bits_a[(a - baseA) // 4]))
assert len(dec) > 200, 'too few post-lock decisions'
direct = sum(1 for s, b in dec if s == b)
inv = len(dec) - direct
assert max(direct, inv) == len(dec), \
    'carrier BER fail %d/%d' % (min(direct, inv), len(dec))
report['carrier']['ber_postlock'] = \
    '0 errors / %d decisions (polarity=%s)' % (len(dec),
                                             'direct' if direct > inv
                                             else 'inverted')
report['carrier']['phase_ambiguity'] = \
    'BPSK Costas locks modulo pi; absolute phase needs preamble/differential'

# segment B: opposite-sign offset df=-Fs/96 (re-acquire or seamless track)
segB = len(crows)
Ib, Qb, bits_b = M.gen_bpsk_iq(2200, 4, -1 / 96, A=0.7, seed=4)
cstream(Ib, Qb)
lr = first_lockrise(segB)
seamless = all(o[2] for o in cout[segB:])
assert lr is not None or seamless, 'carrier never locked at df=-Fs/96'
report['carrier']['lock_cycle_df_m96'] = (lr - segB) if lr else 'seamless'
assert cout[-1][2] == 1, 'carrier not locked at end of df=-Fs/96 segment'
fe = sum(o[3] for o in cout[-2000:] if o[0]) /     max(1, sum(1 for o in cout[-2000:] if o[0])) / 2.0**32
assert abs(fe + 1 / 96) < 2e-4
report['carrier']['freq_est_df_m96'] = fe

# segment C: cold pull-in at the verified boundary df=+Fs/32.
# cfg clear re-zeros the integrator -- the designed re-acquisition path
# (a bare offset jump across the whole pull range takes arbitrarily long).
d, e = ccfg(M.CarrierCfg(fcw=0, clear=1))
assert (d, e) == (1, 0)
cidle()
segC = len(crows)
Ic, Qc, bits_c = M.gen_bpsk_iq(2600, 4, 1 / 32, A=0.7, seed=9)
cstream(Ic, Qc)
lr = first_lockrise(segC)
assert lr is not None, 'carrier never locked at df=+Fs/32 (pull edge)'
report['carrier']['lock_cycle_df_p32'] = lr - segC
assert lr - segC < 14000
fe = sum(o[3] for o in cout[-2000:] if o[0]) /     max(1, sum(1 for o in cout[-2000:] if o[0])) / 2.0**32
assert abs(fe - 1 / 32) < 5e-4
report['carrier']['freq_est_df_p32'] = fe

# segment C2: fcw preset assist -- exact fcw for df=+Fs/20 acquires fast
d, e = ccfg(M.CarrierCfg(fcw=int(2**32 / 20), clear=1))
assert (d, e) == (1, 0)
cidle()
segC2 = len(crows)
Ic2, Qc2, bits_c2 = M.gen_bpsk_iq(800, 4, 1 / 20, A=0.7, seed=14)
cstream(Ic2, Qc2)
lr = first_lockrise(segC2)
assert lr is not None, 'carrier never locked at df=+Fs/20 (fcw preset)'
report['carrier']['lock_cycle_df_p20_preset'] = lr - segC2
assert lr - segC2 < 6000
# mean of the post-lock frequency word (single samples jitter)
fe = sum(o[3] for o in cout[-1500:] if o[0]) / \
    max(1, sum(1 for o in cout[-1500:] if o[0])) / 2.0**32
assert abs(fe - 1 / 20) < 5e-4
report['carrier']['freq_est_df_p20'] = fe

# segment D: out of pull range, df=+Fs/16 -> documented graceful failure
d, e = ccfg(M.CarrierCfg(fcw=0, clear=1))
assert (d, e) == (1, 0)
cidle()
segD = len(crows)
Id, Qd, bits_d = M.gen_bpsk_iq(1500, 4, 1 / 16, A=0.7, seed=10)
cstream(Id, Qd)
assert first_lockrise(segD) is None, \
    'carrier FALSELY locked at out-of-range df=+Fs/16'
assert cout[-1][2] == 0, 'lock still high after out-of-range segment'
report['carrier']['out_of_range_lock'] = 0
fe = cout[-1][3] / 2.0**32
report['carrier']['out_of_range_freq_est'] = fe
assert abs(fe) < 0.01, 'freq_est ran away at out-of-range input'

# segment E: illegal configs reject atomically; legal cfg still works
bad_cfgs = [M.CarrierCfg(kp=8, ki=8),      # ki <= kp
            M.CarrierCfg(kp=8, ki=4),      # ki < kp
            M.CarrierCfg(fcw=1073741825),  # |fcw| > 2^30
            M.CarrierCfg(fcw=-1073741825),
            M.CarrierCfg(lthr=4),          # lthr < 8
            M.CarrierCfg(ln=2)]            # ln < 4
for bad in bad_cfgs:
    d, e = ccfg(bad, fuzz=False)
    assert (d, e) == (1, 1), ('carrier illegal cfg not rejected', bad)
d, e = ccfg(M.CarrierCfg(fcw=0, kp=4, ki=8, lthr=2500, ln=64, clear=1))
assert (d, e) == (1, 0)
report['carrier']['illegal_cfgs_rejected'] = len(bad_cfgs)

# segment F: tracking -- offset steps inside lock range while locked
segF = len(crows)
Is, Qs, _ = M.gen_bpsk_iq(600, 4, -1 / 96, A=0.7, seed=11)
cstream(Is, Qs)
Ie, Qe, _b = M.gen_bpsk_iq(1600, 4, 1 / 96, A=0.7, seed=11)
cstream(Ie, Qe)
assert cout[-1][2] == 1, 'carrier lost lock across in-range offset step'
fe = cout[-1][3] / 2.0**32
assert abs(fe - 1 / 96) < 5e-4
report['carrier']['track_step_ok'] = True

# mid-stream reset twice + re-acquire
for _ in range(2):
    Ir_, Qr_, _b = M.gen_bpsk_iq(300, 4, 1 / 64, A=0.7, seed=12)
    cstream(Ir_, Qr_)
    ctick(rst=0); ctick(rst=0)
d, e = ccfg(M.CarrierCfg(clear=1))
assert (d, e) == (1, 0)
cidle()
segG = len(crows)
Ig, Qg, _b = M.gen_bpsk_iq(1500, 4, 1 / 64, A=0.7, seed=13)
cstream(Ig, Qg)
lr = first_lockrise(segG)
assert lr is not None, 'carrier never re-locked after mid-stream reset'
report['carrier']['relock_after_reset'] = lr - segG

assert cst['accepts'] > 25000 and cst['outputs'] > 25000
assert cst['stalls'] > 0 and cst['resets'] >= 5
assert cst['cfg_done'] >= 8 and cst['cfg_err'] >= 6
report['carrier']['stats'] = {k: v for k, v in cst.items()
                              if k != 'lockrise'}
report['carrier']['stats']['lockrises'] = len(cst['lockrise'])

CFIX = '\n'.join(crows) + '\n'
(OUT / 'vectors_carrier.txt').write_text(CFIX)

# ============================================================================
# TIMING LOOP fixture
#   cfg word: [1:0]sps [6:2]kp [11:7]ki [27:12]lthr [35:28]ln [36]clear
#   row: rst sv sd cv cfgw | sr pk pd pb lk lv re ph cr cd ce
# ============================================================================
tm = M.TimingCycle()
trows = []
tacc = []
tout = []
tst = {'accepts': 0, 'picks': 0, 'cfg_done': 0, 'cfg_err': 0,
       'resets': 0, 'lockrise': []}
tsample = 0
_prev_tlock = 0


def tpack(c):
    if c is None:
        return 0
    return ((c.sps & 0x3)
            | (c.kp & 0x1F) << 2
            | (c.ki & 0x1F) << 7
            | (c.lthr & 0xFFFF) << 12
            | (c.ln & 0xFF) << 28
            | (c.clear & 1) << 36)


def ttick(rst=1, sv=0, sd=0, cfg=None):
    global tsample, _prev_tlock
    cv = int(cfg is not None)
    o = tm.tick(rst=rst, sv=sv, sd=sd, cfg=cfg)
    trows.append('%d %d %x %d %x %d %d %x %d %d %x %x %x %d %d %d' % (
        rst, sv, sd & 0xFFFF, cv, tpack(cfg),
        o['s_tready'], o['pick'], o['pick_data'], o['pick_bit'], o['lock'],
        o['level'], o['rate_est'], o['phase'], o['cfg_ready'], o['cfg_done'],
        o['cfg_error']))
    tout.append((o['pick'], o['pick_data'], o['pick_bit'], o['lock'],
                 M.s32(o['rate_est'])))
    if o['lock'] and not _prev_tlock:
        tst['lockrise'].append(len(trows) - 1)
    _prev_tlock = o['lock']
    if not rst:
        tst['resets'] += 1
        tacc.append(-1)
    else:
        if sv and o['s_tready']:
            tacc.append(tsample)
            tsample += 1
            tst['accepts'] += 1
        else:
            tacc.append(-1)
        if o['pick']:
            tst['picks'] += 1
        if o['cfg_done']:
            tst['cfg_done'] += 1
        if o['cfg_error']:
            tst['cfg_err'] += 1
    return o


def tcfg(cfg):
    for _ in range(20000):
        o = ttick(cfg=cfg)
        if o['cfg_ready']:
            break
    else:
        raise AssertionError('timing cfg accept timeout')
    for _ in range(64):
        o = ttick()
        if o['cfg_done']:
            return o['cfg_done'], o['cfg_error']
    raise AssertionError('timing cfg done timeout')


def tfeed(x, fuzz=True):
    if fuzz:
        while rng.random() < .25:      # occasional gap between samples
            ttick()
    ttick(sv=1, sd=x)


def tstream(y, fuzz=True):
    for x in y:
        tfeed(x, fuzz=fuzz)


def tidle(n=8):
    for _ in range(n):
        ttick()


def first_tlockrise(start):
    r = [x for x in tst['lockrise'] if x >= start]
    return r[0] if r else None


def pick_rows(start):
    """rows r>start where pick=1; each pick decides the sample accepted in
    row r-1."""
    return [r for r in range(start, len(trows)) if tout[r][0]]


# -- timing stimulus program -------------------------------------------------
ttick(rst=0); ttick(rst=0); ttick(rst=0)

# segment T1: SPS=4 (default), tau=0.37 symbol
segT1 = len(trows)
baseT1 = tsample
y1, bits1, sym1 = M.gen_bpsk_real(1800, 4, 0.37, A=0.7, seed=5)
tstream(y1)
lr = first_tlockrise(segT1)
assert lr is not None, 'timing never locked (SPS=4, tau=0.37)'
report['timing']['lock_cycle_sps4'] = lr - segT1
assert lr - segT1 < 5000
# decision correctness on picked samples (pick row r -> input row r-1)
good = tot = 0
pk = pick_rows(lr)
for r in pk[-400:]:
    a = tacc[r - 1]
    if 0 <= a - baseT1 < len(sym1):
        tot += 1
        good += int(tout[r][2] == (1 if bits1[sym1[a - baseT1]] > 0 else 0))
assert tot > 200 and good == tot, 'timing BER fail %d/%d' % (good, tot)
report['timing']['ber_postlock_sps4'] = '0 errors / %d picks' % tot
# pick rate sanity: ~1 pick per SPS accepted samples (pick row r marks
# the sample accepted in row r-1)
pidx = [tacc[r - 1] for r in pk]
delta = [b - a for a, b in zip(pidx, pidx[1:]) if a >= 0 and b >= 0]
mean_d = sum(delta) / len(delta)
assert 3.5 < mean_d < 4.5, 'pick spacing mean %.2f' % mean_d
report['timing']['pick_spacing_mean_sps4'] = mean_d

# segment T2: SPS=8 via config, tau=-0.2
d, e = tcfg(M.TimingCfg(sps=1, clear=1))
assert (d, e) == (1, 0)
tidle()
segT2 = len(trows)
baseT2 = tsample
y2, bits2, sym2 = M.gen_bpsk_real(1200, 8, -0.2, A=0.7, seed=6)
tstream(y2)
lr = first_tlockrise(segT2)
assert lr is not None, 'timing never locked (SPS=8, tau=-0.2)'
report['timing']['lock_cycle_sps8'] = lr - segT2
good = tot = 0
for r in pick_rows(lr)[-300:]:
    a = tacc[r - 1]
    if 0 <= a - baseT2 < len(sym2):
        tot += 1
        good += int(tout[r][2] == (1 if bits2[sym2[a - baseT2]] > 0 else 0))
assert tot > 200 and good == tot, 'timing SPS=8 BER fail %d/%d' % (good, tot)
report['timing']['ber_postlock_sps8'] = '0 errors / %d picks' % tot

# segment T3: symbol-rate offset +4% at SPS=4 -> integrator must track
d, e = tcfg(M.TimingCfg(sps=0, clear=1))
assert (d, e) == (1, 0)
tidle()
segT3 = len(trows)
baseT3 = tsample
y3, bits3, sym3 = M.gen_bpsk_real(1500, 4, 0.0, A=0.7, seed=7, ppm=0.04)
tstream(y3)
lr = first_tlockrise(segT3)
assert lr is not None, 'timing never locked (+4% rate offset)'
re_ = tout[-1][4]
report['timing']['rate_est_ppm4'] = re_
# expected corr ~ +0.04 * STEP0 = 655; allow +-50%
assert abs(re_ - 655) < 400, 'rate_est %d off' % re_
good = tot = 0
for r in pick_rows(lr)[-400:]:
    a = tacc[r - 1]
    if 0 <= a - baseT3 < len(sym3):
        tot += 1
        good += int(tout[r][2] == (1 if bits3[sym3[a - baseT3]] > 0 else 0))
assert tot > 200 and good == tot, 'timing +4%ppm BER fail %d/%d' % (good, tot)
report['timing']['track_ppm4'] = True

# segment T4: no data transitions -- TED blind, documented behaviour:
# loop must not hang; picks keep firing at nominal rate; lock state is
# unspecified (TED sees no error).  Recovery verified in T5.
segT4 = len(trows)
y4 = [int(0.7 * 32768 * 0.875)] * 1200
tstream(y4)
np4 = sum(1 for r in range(segT4, len(trows)) if tout[r][0])
assert 250 < np4 < 350, 'timing stalled without transitions: %d picks' % np4
report['timing']['no_transition_picks'] = np4

# segment T5: recovery after transition-free run -- asserted by recovered
# decision quality (lock flag may legitimately stay high through T4 since
# the TED sees zero error on a transition-free input: documented blindness)
tidle()
segT5 = len(trows)
baseT5 = tsample
y5, bits5, sym5 = M.gen_bpsk_real(1500, 4, 0.5, A=0.7, seed=8)
tstream(y5)
good = tot = 0
for r in pick_rows(segT5)[-400:]:
    a = tacc[r - 1]
    if 0 <= a - baseT5 < len(sym5):
        tot += 1
        good += int(tout[r][2] == (1 if bits5[sym5[a - baseT5]] > 0 else 0))
assert tot > 200 and good == tot, \
    'timing did not recover after no-transition input %d/%d' % (good, tot)
report['timing']['recover_after_no_transitions'] = '0 errors / %d' % tot

# segment T6: illegal configs reject atomically
bad_t = [M.TimingCfg(sps=2),              # only 4/8 supported
         M.TimingCfg(sps=3),
         M.TimingCfg(ki=19, kp=19),       # ki <= kp
         M.TimingCfg(ki=10, kp=19),
         M.TimingCfg(lthr=4),
         M.TimingCfg(ln=2)]
for bad in bad_t:
    d, e = tcfg(bad)
    assert (d, e) == (1, 1), ('timing illegal cfg not rejected', bad)
d, e = tcfg(M.TimingCfg(sps=0, clear=1))
assert (d, e) == (1, 0)
report['timing']['illegal_cfgs_rejected'] = len(bad_t)

# mid-stream reset + reacquire
y6, _b6, _s6 = M.gen_bpsk_real(400, 4, 0.2, A=0.7, seed=9)
tstream(y6)
ttick(rst=0); ttick(rst=0)
tidle()
segT7 = len(trows)
baseT7 = tsample
y7, bits7, sym7 = M.gen_bpsk_real(1500, 4, 0.6, A=0.7, seed=10)
tstream(y7)
lr = first_tlockrise(segT7)
assert lr is not None, 'timing never re-locked after reset'
report['timing']['relock_after_reset'] = lr - segT7

assert tst['accepts'] > 30000 and tst['picks'] > 7000
assert tst['resets'] >= 4 and tst['cfg_err'] >= 6
report['timing']['stats'] = {k: v for k, v in tst.items()
                             if k != 'lockrise'}
report['timing']['stats']['lockrises'] = len(tst['lockrise'])

TFIX = '\n'.join(trows) + '\n'
(OUT / 'vectors_timing.txt').write_text(TFIX)

# ============================================================================
# testbenches
# ============================================================================
TB_C = '''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,cv=0;reg[31:0]sd=0;reg[66:0]cw=0;
wire sr,mv,lk,cr,cd,ce;wire[31:0]md,fe,ph;wire[17:0]lv;
carrier_loop dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.m_tdata(md),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_fcw(cw[31:0]),.cfg_kp(cw[36:32]),
 .cfg_ki(cw[41:37]),.cfg_lthr(cw[57:42]),.cfg_ln(cw[65:58]),
 .cfg_clear(cw[66]),.cfg_done(cd),.cfg_error(ce),.lock(lk),
 .lock_level(lv),.freq_est(fe),.phase_out(ph));
integer f,n,row,rr,ss,ready,vv;reg[31:0]xd;reg[66:0]co;
reg esr,ev,elk,ecr,ecd,ece;reg[31:0]emd,efe,eph;reg[17:0]elv;
initial begin f=$fopen("vectors_carrier.txt","r");row=0;@(posedge clk);#1;
while(!$feof(f))begin @(negedge clk);
n=$fscanf(f,"%d %d %h %d %d %h %d %d %h %d %h %h %h %d %d %d\\n",
 rr,ss,xd,ready,vv,co,esr,ev,emd,elk,elv,efe,eph,ecr,ecd,ece);
if(n!=16)$fatal(1,"fixture row=%0d n=%0d",row,n);
rst_n=rr;sv=ss;sd=xd;mr=ready;cv=vv;cw=co;#1;
if({sr,mv,lk,cr,cd,ce}!=={esr,ev,elk,ecr,ecd,ece})
 $fatal(1,"ctrl row=%0d got=%b exp=%b",row,{sr,mv,lk,cr,cd,ce},
 {esr,ev,elk,ecr,ecd,ece});
if({lv,fe,ph}!=={elv,efe,eph})
 $fatal(1,"status row=%0d got=%h/%h/%h exp=%h/%h/%h",row,lv,fe,ph,elv,efe,eph);
if(mv && md!==emd)
 $fatal(1,"data row=%0d got=%h exp=%h",row,md,emd);
@(posedge clk);#1;row=row+1;end
$display("PASS rows=%0d",row);$finish;end endmodule
'''
(OUT / 'tb_carrier.sv').write_text(TB_C)

TB_T = '''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,cv=0;reg signed[15:0]sd=0;reg[36:0]cw=0;
wire sr,pk,pb,lk,cr,cd,ce;wire signed[15:0]pd;wire[17:0]lv;
wire signed[31:0]re;wire[15:0]ph;
timing_loop dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.pick(pk),.pick_data(pd),.pick_bit(pb),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_sps(cw[1:0]),.cfg_kp(cw[6:2]),
 .cfg_ki(cw[11:7]),.cfg_lthr(cw[27:12]),.cfg_ln(cw[35:28]),
 .cfg_clear(cw[36]),.cfg_done(cd),.cfg_error(ce),.lock(lk),
 .lock_level(lv),.rate_est(re),.phase_out(ph));
integer f,n,row,rr,ss,vv;reg[15:0]xd;reg[36:0]co;
reg esr,epk,epb,elk,ecr,ecd,ece;reg[15:0]epd,eph;reg[17:0]elv;reg[31:0]ere;
initial begin f=$fopen("vectors_timing.txt","r");row=0;@(posedge clk);#1;
while(!$feof(f))begin @(negedge clk);
n=$fscanf(f,"%d %d %h %d %h %d %d %h %d %d %h %h %h %d %d %d\\n",
 rr,ss,xd,vv,co,esr,epk,epd,epb,elk,elv,ere,eph,ecr,ecd,ece);
if(n!=16)$fatal(1,"fixture row=%0d n=%0d",row,n);
rst_n=rr;sv=ss;sd=xd;cv=vv;cw=co;#1;
if({sr,pk,pb,lk,cr,cd,ce}!=={esr,epk,epb,elk,ecr,ecd,ece})
 $fatal(1,"ctrl row=%0d got=%b exp=%b",row,{sr,pk,pb,lk,cr,cd,ce},
 {esr,epk,epb,elk,ecr,ecd,ece});
if({lv,re,ph}!=={elv,ere,eph})
 $fatal(1,"status row=%0d got=%h/%h/%h exp=%h/%h/%h",row,lv,re,ph,elv,ere,eph);
if(pk && pd!==epd)
 $fatal(1,"data row=%0d got=%h exp=%h",row,pd,epd);
@(posedge clk);#1;row=row+1;end
$display("PASS rows=%0d",row);$finish;end endmodule
'''
(OUT / 'tb_timing.sv').write_text(TB_T)


def run(cmd, name, reject=False):
    p = subprocess.run(cmd, cwd=OUT, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / name).write_text(p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(name + ':\n' + p.stdout)
    return p.stdout


iverilog = str(tool / 'bin/iverilog.exe')
vvp = str(tool / 'bin/vvp.exe')

# carrier TB
run([iverilog, '-g2012', '-Wall', '-s', 'tb', '-o', 'carrier.vvp']
    + [str(r) for r in RTL_C] + ['tb_carrier.sv'], 'compile_carrier.log')
run([vvp, 'carrier.vvp'], 'run_carrier.log')

# timing TB
run([iverilog, '-g2012', '-Wall', '-s', 'tb', '-o', 'timing.vvp']
    + [str(r) for r in RTL_T] + ['tb_timing.sv'], 'compile_timing.log')
run([vvp, 'timing.vvp'], 'run_timing.log')

# ---------------------------------------------------------------------------
# mutation rejection: corrupt each expected field / ordering
# ---------------------------------------------------------------------------
negatives = []
# carrier columns: 0 rst 1 sv 2 sd 3 mr 4 cv 5 cfgw |
#   6 sr 7 mv 8 md 9 lock 10 lvl 11 fe 12 ph 13 crdy 14 cdone 15 cerr
for field, label in [(6, 's_ready'), (7, 'valid'), (8, 'data'), (9, 'lock'),
                     (10, 'level'), (11, 'freq_est'), (12, 'phase'),
                     (13, 'cfg_ready'), (14, 'cfg_done'), (15, 'cfg_error')]:
    altered = crows.copy()
    if field == 8:
        # m_tdata is only checked when m_tvalid=1
        idx = next(i for i, r in enumerate(crows)
                   if i > 40 and r.split()[7] == '1'
                   and int(r.split()[8], 16) != 0)
    else:
        idx = next(i for i, r in enumerate(crows)
                   if i > 40 and int(r.split()[field], 16) != 0)
    cells = altered[idx].split()
    if field in (8, 10, 11, 12):
        cells[field] = '%x' % (int(cells[field], 16) ^ 1)
    else:
        cells[field] = str(int(cells[field]) ^ 1)
    altered[idx] = ' '.join(cells)
    (OUT / 'vectors_carrier.txt').write_text('\n'.join(altered) + '\n')
    run([vvp, 'carrier.vvp'], 'negative_c_%s.log' % label, reject=True)
    negatives.append('carrier_' + label)
(OUT / 'vectors_carrier.txt').write_text(CFIX)

# timing columns: 0 rst 1 sv 2 sd 3 cv 4 cfgw |
#   5 sr 6 pick 7 pd 8 pb 9 lock 10 lvl 11 re 12 ph 13 crdy 14 cdone 15 cerr
for field, label in [(5, 's_ready'), (6, 'pick'), (7, 'pick_data'),
                     (8, 'pick_bit'), (9, 'lock'), (10, 'level'),
                     (11, 'rate_est'), (12, 'phase'), (13, 'cfg_ready'),
                     (14, 'cfg_done'), (15, 'cfg_error')]:
    altered = trows.copy()
    if field == 7:
        # pick_data is only checked when pick=1
        idx = next(i for i, r in enumerate(trows)
                   if i > 40 and r.split()[6] == '1'
                   and int(r.split()[7], 16) != 0)
    else:
        idx = next(i for i, r in enumerate(trows)
                   if i > 40 and int(r.split()[field], 16) != 0)
    cells = altered[idx].split()
    if field in (7, 10, 11, 12):
        cells[field] = '%x' % (int(cells[field], 16) ^ 1)
    else:
        cells[field] = str(int(cells[field]) ^ 1)
    altered[idx] = ' '.join(cells)
    (OUT / 'vectors_timing.txt').write_text('\n'.join(altered) + '\n')
    run([vvp, 'timing.vvp'], 'negative_t_%s.log' % label, reject=True)
    negatives.append('timing_' + label)
(OUT / 'vectors_timing.txt').write_text(TFIX)

# pick-order mutation: swap two pick_data values between pick rows
altered = trows.copy()
idxs = [i for i, r in enumerate(trows) if r.split()[6] == '1']
j = next(j for j in range(len(idxs) - 1)
         if trows[idxs[j]].split()[7] != trows[idxs[j + 1]].split()[7])
a, b = idxs[j:j + 2]
ca, cb = altered[a].split(), altered[b].split()
ca[7], cb[7] = cb[7], ca[7]
altered[a], altered[b] = ' '.join(ca), ' '.join(cb)
(OUT / 'vectors_timing.txt').write_text('\n'.join(altered) + '\n')
run([vvp, 'timing.vvp'], 'negative_t_order.log', reject=True)
negatives.append('timing_order')
(OUT / 'vectors_timing.txt').write_text(TFIX)

summary = {'status': 'PASS',
           'rtl_sha256': {str(r.name): hashlib.sha256(r.read_bytes()).hexdigest()
                          for r in RTL_C + RTL_T[2:]},
           'cycles': {'carrier': len(crows), 'timing': len(trows)},
           'report': report,
           'negative_tests': negatives,
           'reference_config': 'BPSK; carrier loop on complex I/Q at SPS=4; '
                               'timing loop on real baseband at SPS in {4,8}',
           'scope': 'cycle-level RTL simulation only; no routed timing or '
                    'board acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
