"""Cycle-exact RTL verification for DSP-14 stft_welch.

A Python oracle mirrors the wrapper FSM and the observable cycle behaviour
of the instantiated window_mult / fft64 / mag_squared / sig_sdp_ram cores,
emitting a per-cycle fixture (inputs + expected outputs).  A generated
iverilog testbench drives inputs on the negedge and compares every output
every cycle, which covers held-output stability automatically.  Mutating an
expected field must make vvp fail (mutation rejection).  The emitted
record values are additionally compared against the independent streaming
bit-exact model in models/reference.py.
"""
import os
import sys
import json
import random
import subprocess
import hashlib
import math
from pathlib import Path
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
import reference as R

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
# lib BEFORE bin: external MinGW DLLs on PATH can crash the tools
env['PATH'] = (str(tool / 'lib') + os.pathsep + str(tool / 'bin')
               + os.pathsep + env['PATH'])
RTL = [BASE / 'rtl/stft_welch.sv',
       BASE.parent / 'spectrum/rtl/window_cos_rom.sv',
       BASE.parent / 'spectrum/rtl/window_mult.sv',
       BASE.parent / 'spectrum/rtl/mag_squared.sv',
       ROOT / 'cores/signal_processing/transforms/src/fft64.v',
       ROOT / 'cores/signal_processing/transforms/src/sig_sdp_ram.v',
       ROOT / 'cores/signal_processing/transforms/src/tw_rom_cos.v',
       ROOT / 'cores/signal_processing/transforms/src/tw_rom_sin.v']
BSRAM_SIM = ROOT / 'cores/signal_processing/transforms/sim/gowin_bsram_sim.v'

IDLE, LOAD, START, RUN, READ, CFGW, CFGM = range(7)


class W:
    """Cycle-exact mirror of stft_welch + instantiated cores."""

    def __init__(self):
        self.rows = []
        self.reset()

    def reset(self):
        self.cfg_obj = R.Config()
        self.cw, self.ch, self.ct = 0, 3, 0
        self.cam, self.cav, self.cws, self.cps = 0, 0, 0, 0
        self.st = IDLE
        self.fill = 0
        self.wptr = 0
        self.fbp = 0
        self.li = 0
        self.ldv = False
        self.ldcnt = 0
        self.buf = [0] * 128
        self.bufq = 0
        self.ri = 0
        self.rdv = False
        self.rdv_bin = 0
        self.pk = 0
        self.blk = 0
        self.accv = [0] * 64
        self.accd = [0, 0, 0, 0]
        self.accram = [0] * 64
        self.accq = 0
        self.fftq = (0, 0)
        self.mv = False
        self.md = 0
        self.mu = 0
        self.busy = False
        self.cin = 0
        self.cfr = 0
        self.crc = 0
        self.clip = False
        self.cd = self.ce = 0
        # window_mult submodel
        self.wwt = 0
        self.wsh = 0
        self.widx = 0
        self.wup = 0
        self.tram = [0] * 64
        self.wpipe = [None] * 4
        self.wmv = False
        self.wmd = 0
        self.wmu = 0
        # fft64 submodel
        self.xre = [0] * 64
        self.xim = [0] * 64
        self.fre = [0] * 64
        self.fim = [0] * 64
        self.farmed = False
        self.fcnt = 0
        # mag_squared submodel
        self.msh = 0
        self.mpipe = [None] * 3
        self.pmv = False
        self.pd = 0
        self.pu = 0
        # bookkeeping
        self.produced = []
        self.epoch = []
        self.bp_seen = False
        self.clip_seen = False

    # ------------------------------------------------------------------
    def tick(self, rst=1, cv=0, cw=0, ch=0, ct=0, cam=0, cav=0, cws=0,
             cps=0, cov=0, cod=0, sv=0, sd=0, mr=1):
        st = self.st
        cfg = self.cfg_obj
        hop = 8 << self.ch
        emit_last = 63 if self.ct else 32
        blk_a = 1 << self.cav
        blk_final = (self.cam == 0) and (self.blk == blk_a - 1)

        # ---- combinational evaluation ---------------------------------
        tok = self.wwt != 4 or self.wup >= 64
        wsr = bool(rst and tok and st != CFGW)
        win_fire = self.ldv and wsr
        ld_issue = st == LOAD and self.li < 64 and (not self.ldv or win_fire)
        p_ready = (not self.mv) or bool(mr)
        madv = bool(rst and ((not self.pmv) or p_ready))
        msr = bool(rst and madv and st != CFGM)
        mag_fire = self.rdv and msr
        rd_issue = st == READ and self.ri < 64 and (not self.rdv or mag_fire)
        p_fire = self.pmv and p_ready
        emit_en = p_fire and self.pk <= emit_last and \
            (self.cam == 1 or blk_final)
        frame_end = p_fire and self.pk == 63
        fill0 = self.fill            # cycle-start value (pre-edge)
        sr = bool(rst and self.fill < 128 and not cv
                  and st not in (CFGW, CFGM))
        s_fire = bool(sv and sr)
        cr = bool(rst and st == IDLE and not self.mv)
        cor = bool(rst and not self.wmv and not any(self.wpipe)
                   and st != CFGW and not win_fire and self.wup < 64)
        fdone = self.farmed and self.fcnt == 0

        if sv and not sr:
            self.bp_seen = True
        if self.clip:
            self.clip_seen = True

        self.rows.append(
            f'{rst} {cv} {cw:x} {ch:x} {ct} {cam} {cav:x} '
            f'{cws & 31:x} {cps:x} {cov} {cod & 0x3ffff:x} {sv} '
            f'{sd & 0xffff:x} {mr} {int(sr)} {int(cr)} {int(cor)} '
            f'{self.cd} {self.ce} {int(self.mv)} {self.md & 0xffffffff:x} '
            f'{self.mu} {int(self.busy)} {self.cin:x} {self.cfr:x} '
            f'{self.crc:x} {int(self.clip)}')
        self.cd = self.ce = 0
        if not rst:
            self.reset()
            return sr, cr, cor

        # ---- sequential update ----------------------------------------
        if self.mv and mr:
            self.produced.append((self.md, self.mu))
            self.mv = False

        # emitted beat (uses pre-increment pk)
        if p_fire:
            p = self.pd
            accv = self.accd[3]
            if self.cam == 0:
                anew = accv + p
                res = min(R.SR.rne(anew, 1 << self.cav), 0xFFFFFFFF)
                wd = 0 if blk_final else anew
            else:
                anew = accv + (((p << 8) - accv) >> self.cav)
                res = min(R.SR.rne(anew, 256), 0xFFFFFFFF)
                wd = anew
            self.accram[self.pk] = wd & ((1 << 42) - 1)
            self.accv[self.pk & 63] = 1
            if emit_en:
                self.mv = True
                self.md = res
                self.mu = ((2 if self.pk == emit_last else 0)
                           | (1 if self.pk == 0 else 0))
                if self.pk == emit_last:
                    self.crc = (self.crc + 1) & 0xFFFF
            self.pk += 1

        # clip observation
        if (self.wmv and self.wmu) or (p_fire and self.pu):
            self.clip = True

        # input capture
        if s_fire:
            self.buf[self.wptr] = sd & 0xffff
            if self.buf[self.wptr] >= 0x8000:
                self.buf[self.wptr] -= 0x10000
            self.wptr = (self.wptr + 1) & 127
            self.cin = (self.cin + 1) & 0xFFFFF
            self.epoch.append(sd)
        self.fill += int(s_fire)
        if frame_end:
            self.fill -= hop
            self.fbp = (self.fbp + hop) & 127
            self.cfr = (self.cfr + 1) & 0xFFFF
            if self.cam == 0:
                self.blk = 0 if blk_final else self.blk + 1

        # ---- LOAD: fft load capture uses current-cycle window output ---
        ld_en = self.wmv and st == LOAD
        frame_last_load = ld_en and self.ldcnt == 63
        if ld_en:
            self.xre[self.ldcnt] = self.wmd
            self.xim[self.ldcnt] = 0
            self.ldcnt += 1

        # window pipe (advance always: m_tready tied 1); the entry stores
        # the bufq value consumed this cycle, so this must run before the
        # bufq update below (mirrors nonblocking semantics)
        p4 = self.wpipe[3]
        self.wmv = p4 is not None
        if p4 is not None:
            self.wmd, self.wmu = R.SR.window_sample(
                p4[0], p4[1], 6, p4[2], p4[3], self.tram)
        neww = ((self.bufq, self.widx, self.wwt, self.wsh)
                if win_fire else None)
        self.wpipe = [neww] + self.wpipe[:3]
        if win_fire:
            self.widx = (self.widx + 1) & 63

        # buffer RAM registered read: bufq for next cycle
        if ld_issue:
            self.bufq = self.buf[(self.fbp + self.li) & 127]
            self.li += 1
            self.ldv = True
        elif win_fire:
            self.ldv = False

        # ---- READ: fft -> mag -> acc/emit ------------------------------
        if madv:
            p3 = self.mpipe[2]
            self.pmv = p3 is not None
            if p3 is not None:
                self.pd, self.pu = R.SR.mag_squared(p3[0], p3[1], self.msh)
            newm = self.fftq if mag_fire else None
            self.mpipe = [newm] + self.mpipe[:2]
            a0 = (self.accq if self.accv[self.rdv_bin] else 0) \
                if mag_fire else 0
            self.accd = [a0] + self.accd[:3]
        if rd_issue:
            self.fftq = (self.fre[self.ri], self.fim[self.ri])
            self.accq = self.accram[self.ri]
            self.rdv_bin = self.ri & 63
            self.ri += 1
            self.rdv = True
        elif mag_fire:
            self.rdv = False

        # fft busy countdown (768 enabled beats after accepted start)
        if self.fcnt > 0:
            self.fcnt -= 1

        # ---- FSM -------------------------------------------------------
        self.busy = st != IDLE
        if st == IDLE:
            if cv and cr:
                if R.valid_cfg(cw, ch, ct, cam, cav,
                               _s5(cws), cps):
                    self.cw, self.ch, self.ct = cw, ch, ct
                    self.cam, self.cav = cam, cav
                    self.cws, self.cps = _s5(cws), cps
                    self.cfg_obj = R.Config(cw, ch, ct, cam, cav,
                                            _s5(cws), cps)
                    self.fill = 0
                    self.wptr = 0
                    self.fbp = 0
                    self.li = 0
                    self.ldv = False
                    self.ldcnt = 0
                    self.ri = 0
                    self.rdv = False
                    self.pk = 0
                    self.blk = 0
                    self.accv = [0] * 64
                    self.rdv_bin = 0
                    self.cin = 0
                    self.cfr = 0
                    self.crc = 0
                    self.clip = False
                    self.epoch = []
                    self.produced = []
                    self.st = CFGW
                else:
                    self.ce = 1
            elif fill0 >= 64:
                self.li = 0
                self.ldv = False
                self.ldcnt = 0
                self.st = LOAD
        elif st == LOAD:
            if frame_last_load:
                self.st = START
        elif st == START:
            self.farmed = True
            self.fcnt = 768
            self.fre, self.fim = R.GM.fft64(self.xre, self.xim)
            self.st = RUN
        elif st == RUN:
            if fdone:
                self.ri = 0
                self.rdv = False
                self.rdv_bin = 0
                self.pk = 0
                self.st = READ
        elif st == READ:
            if frame_end:
                self.st = IDLE
        elif st == CFGW:
            # window_mult commits its config on this edge
            self.wwt = self.cw
            self.wsh = self.cws
            self.widx = 0
            self.wup = 0
            self.st = CFGM
        elif st == CFGM:
            self.msh = self.cps
            self.cd = 1
            self.st = IDLE
        else:
            self.st = IDLE

        # coefficient upload (window_mult passthrough)
        if cov and cor:
            self.tram[self.wup] = cod - (0x40000 if cod & 0x20000 else 0)
            self.wup += 1

        return sr, cr, cor


def _s5(v):
    v &= 31
    return v - 32 if v >= 16 else v


rng = random.Random(0x57F7)
o = W()
cases = []
metrics = {}


def rdy(fz):
    return int(not fz or (len(o.rows) % 397 >= 51 and rng.random() < .72))


def configure(cfg, randomize=False):
    req = dict(cv=1, cw=cfg.window, ch=cfg.hop_sel, ct=cfg.twosided,
               cam=cfg.avgmode, cav=cfg.avg, cws=cfg.wshift,
               cps=cfg.pshift)
    for _ in range(300000):
        _, cr, _ = o.tick(mr=rdy(randomize), **req)
        if cr:
            break
    else:
        raise AssertionError('config timeout')
    for _ in range(20):
        if o.cd or o.ce:
            return o.cd, o.ce
        o.tick(mr=1)
    raise AssertionError('config done/error missing')


def feed(x, randomize=False):
    if randomize:
        for _ in range(rng.randrange(3)):
            o.tick(mr=rdy(True))
    for _ in range(300000):
        sr, _, _ = o.tick(sv=1, sd=x, mr=rdy(randomize))
        if sr:
            return
    raise AssertionError('feed timeout')


def feed_stream(xs, randomize=False):
    for x in xs:
        feed(x, randomize)


def upload(cs, randomize=False):
    for v in cs:
        if randomize:
            for _ in range(rng.randrange(2)):
                o.tick(mr=rdy(True))
        for _ in range(300000):
            _, _, cor = o.tick(cov=1, cod=v, mr=rdy(randomize))
            if cor:
                break
        else:
            raise AssertionError('coefficient upload timeout')


def settle(n=40, randomize=False):
    for _ in range(n):
        o.tick(mr=rdy(randomize))


def wait_drain(limit=600000):
    # busy flickers 0 for one cycle between back-to-back frames; a new
    # frame can only start when fill >= 64, so require that too
    for _ in range(limit):
        if not o.busy and not o.mv and o.fill < 64:
            return
        o.tick(mr=1)
    raise AssertionError('drain timeout')


def expect_records():
    """produced beats == independent streaming bit-exact records."""
    exp = R.records(o.epoch, o.cfg_obj, o.tram)
    flat = []
    for rec in exp:
        for i, v in enumerate(rec):
            mu = (1 if i == 0 else 0) | (2 if i == len(rec) - 1 else 0)
            flat.append((v, mu))
    if o.produced != flat:
        for i, (a, b) in enumerate(zip(o.produced, flat)):
            if a != b:
                raise AssertionError(
                    f'record mismatch at beat {i}: produced={a} '
                    f'expected={b}; totals {len(o.produced)}/{len(flat)} '
                    f'cfg={o.cfg_obj} frames={o.cfr} epoch={len(o.epoch)}')
        raise AssertionError(
            f'record length mismatch: produced={len(o.produced)} '
            f'expected={len(flat)} cfg={o.cfg_obj}')


def tone(k, amp, n, phase=0.0):
    return [int(round(amp * 32768 * math.cos(2 * math.pi * k * i / n + phase)))
            for i in range(n)]


for _ in range(3):
    o.tick(rst=0)
o.tick()

# =====================================================================
# 1. default config: unity window, hop64, one-sided, A=1
# =====================================================================
xs = tone(4, 0.25, 192)
feed_stream(xs)
wait_drain()
expect_records()
assert o.cfr == 3 and o.crc == 3
cases.append({'kind': 'default_unity_h64', 'frames': 3, 'records': o.crc})

# =====================================================================
# 2. config sweep: windows x hops x avg modes, protocol fuzz
# =====================================================================
sweep = [(1, 1, 0, 0, 1, True), (2, 2, 1, 0, 0, True),
         (3, 0, 1, 1, 2, True), (1, 3, 0, 0, 2, False),
         (0, 2, 1, 1, 8, True), (3, 1, 0, 1, 1, True),
         (2, 3, 1, 0, 3, True), (0, 0, 0, 0, 0, True)]
for wt, hs, two, am, av, fz in sweep:
    cfg = R.Config(wt, hs, two, am, av)
    assert configure(cfg) == (1, 0)
    h = 8 << hs
    xs = [a + b for a, b in zip(tone(4, 0.2, 400), tone(9, 0.1, 400))]
    xs = [max(-32768, min(32767, v + rng.randrange(-2000, 2001)))
          for v in xs]
    feed_stream(xs[:64 + 4 * h], fz)
    wait_drain()
    expect_records()
    cases.append({'kind': 'sweep', 'cfg': repr(cfg),
                  'samples': 64 + 4 * h, 'records': o.crc})

# block average A=4 and A=8 (full block emitted once)
for av in (2, 3):
    cfg = R.Config(0, 3, 0, 0, av)
    assert configure(cfg) == (1, 0)
    feed_stream(tone(4, 0.25, 64 + ((1 << av) - 1) * 64), True)
    wait_drain()
    expect_records()
    cases.append({'kind': 'block_avg', 'A': 1 << av, 'records': o.crc})

# =====================================================================
# 3. buffer-full backpressure: continuous maximal-rate feed
# =====================================================================
o.bp_seen = False
cfg = R.Config(0, 3, 0, 0, 0)
assert configure(cfg) == (1, 0)
for x in [rng.randrange(-32768, 32768) for _ in range(300)]:
    feed(x)                      # never inserts gaps: fill reaches 128
wait_drain()
expect_records()
assert o.bp_seen, 'input never backpressured at capacity'
cases.append({'kind': 'buffer_full_backpressure', 'samples': 300,
              'records': o.crc})

# =====================================================================
# 4. held output + random ready fuzz on a long record
# =====================================================================
cfg = R.Config(1, 3, 1, 0, 0)
assert configure(cfg) == (1, 0)
feed_stream(tone(4, 0.25, 64))
for _ in range(300):
    o.tick(mr=0)                 # stall before first output
for _ in range(2000):
    o.tick(mr=rdy(True))
wait_drain()
expect_records()
cases.append({'kind': 'held_output_fuzz', 'records': o.crc})

# =====================================================================
# 5. mid-stream reset discards in-flight work
# =====================================================================
cfg = R.Config(1, 1, 0, 0, 1)
assert configure(cfg) == (1, 0)
feed_stream(tone(4, 0.25, 100))
for _ in range(320):
    o.tick(mr=1)                 # mid LOAD/RUN
for _ in range(2):
    o.tick(rst=0)
o.tick()
assert o.cin == 0 and o.cfr == 0 and not o.busy
cfg = R.Config(2, 2, 0, 1, 3)
assert configure(cfg) == (1, 0)
feed_stream(tone(9, 0.3, 64 + 3 * 32), True)
wait_drain()
expect_records()
cases.append({'kind': 'midstream_reset', 'records': o.crc})

# =====================================================================
# 6. illegal configs reject all fields and preserve state/epoch
# =====================================================================
cfg = R.Config(1, 1, 0, 0, 0)
assert configure(cfg) == (1, 0)
feed_stream(tone(4, 0.25, 40))
bad = [dict(cw=5), dict(cw=7), dict(cam=0, cav=9), dict(cam=1, cav=0),
       dict(cam=1, cav=9), dict(cws=-9), dict(cws=-16), dict(cps=16),
       dict(cps=31)]
for b in bad:
    req = dict(cv=1, cw=cfg.window, ch=cfg.hop_sel, ct=cfg.twosided,
               cam=cfg.avgmode, cav=cfg.avg, cws=cfg.wshift,
               cps=cfg.pshift)
    req.update(b)
    for _ in range(300000):
        _, cr, _ = o.tick(mr=1, **req)
        if cr:
            break
    else:
        raise AssertionError('illegal cfg not answered')
    assert o.ce == 1 and o.cd == 0, b
assert o.cfg_obj == cfg and len(o.epoch) == 40
feed_stream(tone(4, 0.25, 104), True)
wait_drain()
expect_records()
cases.append({'kind': 'illegal_config_reject', 'configs': len(bad)})

# =====================================================================
# 7. custom window upload: incomplete table stalls load, then resumes
# =====================================================================
cfg = R.Config(4, 3, 0, 0, 0)
assert configure(cfg) == (1, 0)
feed_stream(tone(4, 0.25, 80))
tab = R.window_table(R.Config(1, 3, 0, 0, 0))   # hann table as custom
upload(tab[:40])
for _ in range(3000):
    o.tick(mr=1)
assert o.cfr == 0, 'frame ran with incomplete custom table'
upload(tab[40:])
wait_drain()
expect_records()
assert o.cfr == 1
cases.append({'kind': 'custom_window_upload', 'records': o.crc})

# =====================================================================
# 8. PSD accuracy metrics vs float model (bin tone + inter-bin leakage)
# =====================================================================
cfg = R.Config(0, 3, 0, 0, 0)                   # unity, two-sided? no
cfg = R.Config(0, 3, 1, 0, 0)                   # unity hop64 two-sided
assert configure(cfg) == (1, 0)
feed_stream(tone(4, 0.5, 64))
wait_drain()
expect_records()
u_q = R.window_power_sum(0)
rec = [v for v, _ in o.produced]
fp = R.float_frame_power(tone(4, 0.5, 64), cfg)
scale = (1 << cfg.pshift) / float(1 << 18)
fpmax = max(fp)
# significant bins by relative error; near-zero bins are quant-noise so
# they get an absolute bound instead (scales with peak)
err = max(abs(rec[k] * scale - fp[k]) / fp[k] for k in range(64)
          if fp[k] > 0.01 * fpmax)
aerr = max(abs(rec[k] * scale - fp[k]) for k in range(64))
metrics['bin4_tone_max_rel_err'] = err
metrics['bin4_tone_max_abs_err'] = aerr
assert err < 0.05 and aerr < 0.005 * fpmax
metrics['bin4_peak_bin'] = max(range(64), key=lambda k: rec[k])
# real cosine tone: bins 4 and 60 are a conjugate pair, quantization can
# tip either above the other by an LSB
assert metrics['bin4_peak_bin'] in (4, 60)
assert abs(rec[4] - rec[60]) <= max(1, rec[4] // 100)

cfg = R.Config(1, 3, 1, 0, 0)                   # hann two-sided
assert configure(cfg) == (1, 0)
feed_stream(tone(4.5, 0.5, 64))
wait_drain()
expect_records()
rec = [v for v, _ in o.produced]
fp = R.float_frame_power(tone(4.5, 0.5, 64), cfg)
scale = (1 << cfg.pshift) / float(1 << 18)
fpmax = max(fp)
# relative bound on significant bins, absolute bound near the quant noise
# floor (one output LSB = scale real units)
rel_err = max(abs(rec[k] * scale - fp[k]) / fp[k] for k in range(64)
              if fp[k] > 0.01 * fpmax)
abs_err = max(abs(rec[k] * scale - fp[k]) for k in range(64))
metrics['interbin_hann_max_rel_err'] = rel_err
metrics['interbin_hann_max_abs_err'] = abs_err
# quantized FFT granularity: power error ~2*|X|*e per bin, so the absolute
# floor scales with the peak; measured ~0.07% of peak
assert rel_err < 0.05, rel_err
assert abs_err < 0.005 * fpmax, abs_err
metrics['window_U_q'] = {'unity': R.window_power_sum(0),
                         'hann': R.window_power_sum(1),
                         'hamming': R.window_power_sum(2),
                         'blackman': R.window_power_sum(3)}
metrics['hann_coherent_gain'] = R.coherent_gain(1)

# frame timing measurement for the SPEC throughput contract
metrics['cycles'] = len(o.rows)

# =====================================================================
# fixture + generated testbench
# =====================================================================
fixture = '\n'.join(o.rows) + '\n'
(OUT / 'vectors.txt').write_text(fixture)
(OUT / 'tb.sv').write_text('''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,ct=0,cam=0,cov=0,sv=0,mr=0;
reg[2:0]cw=0;reg[1:0]ch=0;reg[3:0]cav=0;reg signed[4:0]cws=0;
reg[4:0]cps=0;reg signed[17:0]cod=0;reg signed[15:0]sd=0;
wire sr,cr,cor,cd,ce,mv,busy,clip;wire[31:0]md;wire[1:0]mu;
wire[19:0]cin;wire[15:0]cfr,crc;
stft_welch dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.m_tdata(md),.m_tuser(mu),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_window(cw),.cfg_hop(ch),
 .cfg_twosided(ct),.cfg_avgmode(cam),.cfg_avg(cav),.cfg_wshift(cws),
 .cfg_pshift(cps),.cfg_done(cd),.cfg_error(ce),.coe_tdata(cod),
 .coe_tvalid(cov),.coe_tready(cor),.busy(busy),.cnt_in(cin),
 .cnt_frames(cfr),.cnt_recs(crc),.clip_sticky(clip));
integer f,n,row,rr,vv,ww,hh,tt,aa,avv,covv,svv,rrr,esr,ecr,ecor,ecd,ece,
 ev,eu,eb,ec;reg[4:0]wsh,psh;reg[17:0]cc;reg[15:0]dd;
reg[31:0]ex,ei;reg[19:0]eic;reg[15:0]efc,erc;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %h %h %d %d %h %h %h %d %h %d %h %d %d %d %d %d %d %d %h %d %d %h %h %h %d\\n",
   rr,vv,ww,hh,tt,aa,avv,wsh,psh,covv,cc,svv,dd,rrr,esr,ecr,ecor,ecd,ece,
   ev,ex,eu,eb,eic,efc,erc,ec);
  if(n!=27)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;cv=vv;cw=ww;ch=hh;ct=tt;cam=aa;cav=avv;cws=wsh;cps=psh;
  cov=covv;cod=cc;sv=svv;sd=dd;mr=rrr;#1;
  if({sr,cr,cor,cd,ce,mv,busy,clip}!=={esr[0],ecr[0],ecor[0],ecd[0],
     ece[0],ev[0],eb[0],ec[0]})
   $fatal(1,"ctrl row=%0d got=%b exp=%b",row,
    {sr,cr,cor,cd,ce,mv,busy,clip},
    {esr[0],ecr[0],ecor[0],ecd[0],ece[0],ev[0],eb[0],ec[0]});
  if(mv && {md,mu}!=={ex,eu[1:0]})
   $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,ex,eu[1:0]);
  if({cin,cfr,crc}!=={eic,efc,erc})
   $fatal(1,"count row=%0d got=%h/%h/%h exp=%h/%h/%h",row,cin,cfr,crc,
    eic,efc,erc);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
''')


def run(cmd, name, reject=False):
    p = subprocess.run(cmd, cwd=OUT, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / name).write_text(p.stdout)
    ok = (p.returncode != 0) if reject else (p.returncode == 0)
    if not ok:
        raise RuntimeError(name + ': ' + p.stdout[-3000:])


run([str(tool / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
     '-o', 'test.vvp'] + [str(f) for f in RTL] + ['tb.sv'], 'compile.log')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'run.log')

# ---- mutation rejection -------------------------------------------------
negatives = []


def mutate(rows, field, where, transform):
    out = rows.copy()
    cells = out[where].split()
    cells[field] = transform(cells[field])
    out[where] = ' '.join(cells)
    return out


flip1 = lambda c: str(int(c) ^ 1)
hflip = lambda c: f'{int(c, 16) ^ 1:x}'
for field, label, tr in [(20, 'data', hflip), (19, 'valid', flip1),
                         (14, 'sready', flip1), (15, 'cfgready', flip1),
                         (21, 'user', flip1), (18, 'cfgerr', flip1),
                         (24, 'framecount', hflip)]:
    idx = next(i for i, r in enumerate(o.rows)
               if i > 20 and r.split()[19] == '1')
    (OUT / 'vectors.txt').write_text(
        '\n'.join(mutate(o.rows, field, idx, tr)) + '\n')
    run([str(tool / 'bin/vvp.exe'), 'test.vvp'],
        f'negative_{label}.log', reject=True)
    negatives.append(label)
(OUT / 'vectors.txt').write_text(fixture)

# swap two emitted beats -> ordering must be rejected
indices = [i for i, r in enumerate(o.rows) if r.split()[19] == '1']
a, b = indices[len(indices) // 3], indices[len(indices) // 3 + 1]
rows2 = o.rows.copy()
ca, cb = rows2[a].split(), rows2[b].split()
ca[20], cb[20] = cb[20], ca[20]
rows2[a], rows2[b] = ' '.join(ca), ' '.join(cb)
(OUT / 'vectors.txt').write_text('\n'.join(rows2) + '\n')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'],
    'negative_output_order.log', reject=True)
negatives.append('output_order')
(OUT / 'vectors.txt').write_text(fixture)

# RAM_REGS=0 (DPX9B path) smoke run with the gowin bsram sim model
(OUT / 'tb_regs0.sv').write_text(
    (OUT / 'tb.sv').read_text().replace(
        'stft_welch dut', 'stft_welch #(.RAM_REGS(0)) dut'))
run([str(tool / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
     '-o', 'regs0.vvp'] + [str(f) for f in RTL]
    + [str(BSRAM_SIM), 'tb_regs0.sv'], 'regs0_compile.log')
run([str(tool / 'bin/vvp.exe'), 'regs0.vvp'], 'regs0_run.log')

summary = {'status': 'PASS', 'cycles': len(o.rows), 'cases': cases,
           'metrics': metrics, 'negative_tests': negatives,
           'rtl_sha256': hashlib.sha256(
               (BASE / 'rtl/stft_welch.sv').read_bytes()).hexdigest(),
           'scope': 'serialized-FFT STFT/Welch; no II1/P&R/board claim'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print('PASS cycles', len(o.rows), 'cases', len(cases), 'metrics', metrics)
