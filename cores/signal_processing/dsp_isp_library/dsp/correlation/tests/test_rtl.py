import os, sys, json, random, subprocess, hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (StreamModel, Config, frame_results, pack_taps,
                       pack_sample, pack_acc, MAX_TAPS, POS_MAX, SMIN, SMAX)
BASE = Path(__file__).resolve().parents[1]; ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f')); OUT.mkdir(parents=True)
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'; env = os.environ.copy()
env['PATH'] = str(tool / 'bin') + os.pathsep + str(tool / 'lib') + os.pathsep + env['PATH']
RTL = BASE / 'rtl/correlation_stream.sv'
rng = random.Random(0xC06E1); o = StreamModel()
rows = []; clock = 0; handshakes = []; emitted = []; peaks = []; rises = []
cfg_events = []; resets = 0; prev_mv = 0; prev_pv = 0; p_rises = []

def tick(rst=1, sv=0, sd=(0, 0), su=0, sl=0, mr=1, pr=1, cfg=None):
    """Apply one cycle of inputs, record expected outputs, advance state."""
    global clock, resets, prev_mv, prev_pv
    cv = int(cfg is not None)
    nt, md, tl, tp = cfg if cv else (0, 0, 0, [(0, 0)] * MAX_TAPS)
    outs = o.outputs(rst, cv)
    rows.append(f'{rst} {cv} {nt} {md} {tl} {pack_taps(tp):x} {sv} '
                f'{pack_sample(*sd):08x} {su} {sl} {mr} {pr} '
                f'{outs["s_tready"]} {outs["cfg_ready"]} {outs["cfg_done"]} '
                f'{outs["cfg_error"]} {outs["marker_error"]} '
                f'{outs["m_valid"]} {pack_acc(outs["m_re"], outs["m_im"]):024x} '
                f'{outs["m_pos"]:x} {outs["m_tuser"]} {outs["m_tlast"]} '
                f'{outs["p_valid"]} {outs["p_pos"]:x} '
                f'{pack_acc(outs["p_re"], outs["p_im"]):024x} {outs["p_mag"]:x} '
                f'{outs["p_error"]}')
    if rst and outs['s_tready'] and sv:
        handshakes.append(clock)
    if outs['m_valid'] and not prev_mv:
        rises.append(clock)
    if outs['p_valid'] and not prev_pv:
        p_rises.append(clock)
    prev_mv = outs['m_valid']; prev_pv = outs['p_valid']
    if rst and outs['m_valid'] and mr:
        emitted.append((clock, outs['m_re'], outs['m_im'], outs['m_pos'],
                        outs['m_tuser'], outs['m_tlast']))
    if rst and outs['p_valid'] and pr:
        peaks.append((clock, outs['p_pos'], outs['p_re'], outs['p_im'],
                      outs['p_mag'], outs['p_error']))
    o.edge(rst, cv, nt, md, tl, tp, sv, sd[0], sd[1], su, sl, mr, pr)
    if not rst:
        resets += 1
    clock += 1
    return outs['s_tready'], outs['cfg_ready']

def rbit(p=.75):
    return int(rng.random() < p)

def make_cfg(ntaps, cplx=0, dir=0, conj=0, tail=0, taps=None, pad=(0, 0)):
    """Full-width request; pad fills unused tap slots (ignored by the core)."""
    if taps is None:
        taps = [(rng.randrange(SMIN, SMAX + 1),
                 rng.randrange(SMIN, SMAX + 1)) for _ in range(ntaps)]
    mode = (1 if cplx else 0) | (2 if dir else 0) | (4 if conj else 0)
    return (ntaps, mode, tail, list(taps) + [pad] * (MAX_TAPS - len(taps)))

def configure(cfg, fuzz=False):
    """Hold cfg_valid until accepted at a clean boundary; return error flag."""
    for _ in range(800000):
        _, cr = tick(mr=rbit() if fuzz else 1, pr=rbit() if fuzz else 1, cfg=cfg)
        if cr:
            return o.cfg_error
    raise AssertionError('config timeout')

def feed(xs, fuzz=False, drop_user=False, extra_user=-1, mark_last=True,
         first_index=0, mr_hold=None, pr_hold=None):
    """Feed frame samples; xs is a list of (re,im). su on the sample with
    index first_index and sl on the last sample unless marker-fault
    injection is requested. mr_hold/pr_hold force the ready lines."""
    n = len(xs)
    for i, x in enumerate(xs):
        if fuzz:
            for _ in range(rng.randrange(4)):
                tick(mr=rbit(), pr=rbit())
        su = int(i == first_index and not drop_user)
        if i == extra_user:
            su = 1
        sl = int(mark_last and i == n - 1)
        for _ in range(800000):
            mrv = mr_hold if mr_hold is not None else (rbit() if fuzz else 1)
            prv = pr_hold if pr_hold is not None else (rbit() if fuzz else 1)
            sr, _ = tick(sv=1, sd=x, su=su, sl=sl, mr=mrv, pr=prv)
            if sr:
                break
        else:
            raise AssertionError('input timeout')

def drain_data(target, fuzz=False, stall_first=0):
    """Data beats are streamed during feeding, so target is absolute."""
    for _ in range(stall_first):
        tick(mr=0, pr=rbit() if fuzz else 1)
    for _ in range(800000):
        tick(mr=rbit() if fuzz else 1, pr=rbit() if fuzz else 1)
        if len(emitted) >= target:
            break
    else:
        raise AssertionError('data drain timeout')

def wait_idle():
    """Tick with both ready lines high until the oracle reaches IDLE."""
    for _ in range(800000):
        tick()
        if o.state == 0:
            return
    raise AssertionError('idle timeout')

def drain_peak(target, fuzz=False, stall=0):
    for _ in range(stall):
        tick(pr=0)
    for _ in range(800000):
        tick(mr=rbit() if fuzz else 1, pr=rbit() if fuzz else 1)
        if len(peaks) >= target:
            break
    else:
        raise AssertionError('peak drain timeout')

frames = []
def run_frame(xs, cfg=None, fuzz=False, stall_first=0, tag=''):
    """Configure unless None (keep current), feed one marker-delimited frame,
    drain its data beats and peak summary, compare with the independent
    bit-exact functional model."""
    if cfg is not None:
        nt, md, tl, tp = cfg
        err = configure(cfg, fuzz)
        assert not err, ('unexpected cfg reject', nt, md, tl)
        cfg_events.append((nt, md, tl, 0))
        cplx = md & 1
        mcfg = Config(nt, bool(cplx), bool(md & 2), bool(md & 4), tl,
                      tuple(tp))
    else:
        mcfg = Config(o.ntaps, bool(o.cplx), bool(o.dir), bool(o.conj),
                      o.tail, tuple(zip(o.tap_re, o.tap_im)))
        nt, tl, cplx = o.ntaps, o.tail, o.cplx
    r0 = len(rises); e0 = len(emitted); p0 = len(peaks)
    feed(xs, fuzz)
    want_outs, want_peak = frame_results(xs, mcfg)
    drain_data(e0 + len(want_outs), fuzz, stall_first)
    drain_peak(p0 + 1, fuzz)
    got = emitted[e0:]; gotp = peaks[p0:]
    assert len(gotp) == 1
    assert [(g[1], g[2]) for g in got] == [(w['re'], w['im']) for w in want_outs], \
        (tag, got, want_outs)
    assert [g[3] for g in got] == [w['pos'] for w in want_outs]
    assert [g[4] for g in got] == [w['user'] for w in want_outs]
    assert [g[5] for g in got] == [w['last'] for w in want_outs]
    pk = gotp[0]
    assert pk[1] == want_peak['pos'] and pk[2] == want_peak['re'] and \
        pk[3] == want_peak['im'] and pk[4] == want_peak['mag'] and \
        pk[5] == want_peak['error'], (tag, pk, want_peak)
    steps = 2 * nt if cplx else nt
    frames.append({'tag': tag, 'n': len(xs), 'ntaps': nt, 'cplx': cplx,
                   'tail': tl, 'outputs': len(want_outs), 'steps': steps,
                   'timed': not fuzz and not stall_first,
                   'accept_cycles': handshakes[-len(xs):],
                   'rise_cycles': rises[r0:], 'p_rise': p_rises[-1]})

tick(rst=0); tick(rst=0)
# Default post-reset config: real ntaps=1 tap=+32767 VALID -> y=32767*x.
for xs in [[(v, 0) for v in (0, 1, -1, 1000, -32768, 32767)],
           [(7, 9)], [(-30000, 0), (30000, 0)]]:
    run_frame(xs, tag='reset_default')

# Sweep ntaps / complex / direction / conjugate / tail.
taps4 = [(3, 0), (-2, 0), (5, 0), (1, 0)]
sweep = [
    (1, 0, 0, 0, 0), (2, 0, 1, 0, 0), (4, 0, 0, 0, 1), (7, 0, 1, 0, 1),
    (16, 0, 0, 0, 0), (33, 0, 1, 0, 1), (64, 0, 0, 0, 0),
    (2, 1, 0, 0, 0), (4, 1, 0, 1, 1), (8, 1, 1, 0, 0), (8, 1, 1, 1, 1),
    (16, 1, 0, 1, 1), (64, 1, 1, 1, 0)]
for nt, cplx, d, cj, tl in sweep:
    cfg = make_cfg(nt, cplx=cplx, dir=d, conj=cj, tail=tl)
    xs = rx = [(rng.randrange(-5000, 5001),
                rng.randrange(-5000, 5001) if cplx else 0)
               for _ in range(nt + rng.randrange(0, 9))]
    run_frame(xs, cfg, tag=f'sw_m{nt}_c{cplx}_d{d}_j{cj}_t{tl}')

# Deterministic embedded-template detection, both directions.
M, N, p = 5, 24, 9
tp = [(rng.randrange(-8000, 8001), 0) for _ in range(M)]
xs = [(rng.randrange(-100, 101), 0) for _ in range(N)]
for i in range(M):
    xs[p + i] = tp[i]
run_frame(xs, make_cfg(M, dir=0, tail=1, taps=tp), tag='embed_dir0')
assert peaks[-1][1] == p + M - 1
xr = [(rng.randrange(-100, 101), 0) for _ in range(N)]
for i in range(M):
    xr[p + i] = tp[M - 1 - i]
run_frame(xr, make_cfg(M, dir=1, tail=1, taps=tp), tag='embed_dir1')
assert peaks[-1][1] == p + M - 1
# Complex conjugate matched filter: peak bin carries the template energy.
tc = [(rng.randrange(-4000, 4001), rng.randrange(-4000, 4001)) for _ in range(6)]
xc = [(rng.randrange(-100, 101), rng.randrange(-100, 101)) for _ in range(20)]
for i, t in enumerate(tc):
    xc[4 + i] = t
run_frame(xc, make_cfg(6, cplx=1, conj=1, dir=0, tail=1, taps=tc),
          tag='cplx_conj_embed')
assert peaks[-1][1] == 4 + 6 - 1
assert peaks[-1][2] == sum(r * r + i * i for r, i in tc) and peaks[-1][3] == 0

# VALID frame shorter than the template: zero data beats, p_error=1.
run_frame([(5, 0), (-3, 0)], make_cfg(4, tail=0), tag='short_frame')
assert peaks[-1][5] == 1 and peaks[-1][1] == POS_MAX
# Single-sample frame, single-tap FULL: N+M-1 = 1 output.
run_frame([(11, 0)], make_cfg(3, tail=1, taps=[(1, 0), (0, 0), (0, 0)]),
          tag='single_full')
assert [e[3] for e in emitted[-3:]] == [0, 1, 2]

# Unused config slots may carry arbitrary values without causing rejection.
cfg = make_cfg(5, cplx=1, conj=1, tail=1, pad=(SMAX, SMIN))
run_frame([(rng.randrange(-99, 100), rng.randrange(-99, 100)) for _ in range(9)],
          cfg, tag='unused_slots')

# Illegal requests reject atomically; retained config proven by a fresh frame.
assert not configure(make_cfg(4, taps=[(1, 0), (2, 0), (4, 0), (8, 0)]))
illegal = [
    (0, 0, 0, [(0, 0)] * MAX_TAPS),                                  # ntaps=0
    (MAX_TAPS + 1, 0, 0, [(0, 0)] * MAX_TAPS),                       # ntaps>64
    (4, 0, 2, [(0, 0)] * MAX_TAPS),                                  # tail=2
    (4, 4, 0, [(0, 0)] * MAX_TAPS),                                  # conj w/o cplx
    (4, 8, 0, [(0, 0)] * MAX_TAPS)]                                  # mode bit3
for bad in illegal:
    err = configure(bad)
    assert err, ('illegal not rejected', bad[:3])
    cfg_events.append((bad[0], bad[1], bad[2], 1))
    assert o.ntaps == 4 and o.cplx == 0
run_frame([(100, 0), (-200, 0), (300, 0), (-400, 0), (500, 0)],
          tag='retained_after_illegal')

# cfg_valid held mid-frame: never accepted early; frame uses the old config.
old_cfg = make_cfg(3, tail=0, taps=[(1, 0), (1, 0), (1, 0)])
assert not configure(old_cfg)
new_cfg = make_cfg(4, cplx=1, conj=1, tail=1)
xs = [(rng.randrange(-500, 501), 0) for _ in range(8)]
feed(xs[:3], mark_last=False)
e0 = len(emitted); p0 = len(peaks)
for i, x in enumerate(xs[3:], 3):
    for _ in range(800000):
        sr, cr = tick(sv=1, sd=x, su=0, sl=int(i == 7), cfg=new_cfg)
        assert not cr, 'mid-frame config accepted'
        if sr:
            break
    else:
        raise AssertionError('feed timeout')
# Hold cfg_valid through the drain; accepted only once the frame boundary and
# the pending peak have cleared.
for _ in range(800000):
    sr, cr = tick(mr=1, pr=1, cfg=new_cfg)
    if o.ntaps == 4 and len(peaks) - p0 >= 1:
        break
else:
    raise AssertionError('boundary config timeout')
assert not o.cfg_error and o.cplx == 1
want_outs, _ = frame_results(xs, Config(3, 0, 0, 0, 0,
    ((1, 0), (1, 0), (1, 0)) + ((0, 0),) * (MAX_TAPS - 3)))
assert [(g[1], g[2]) for g in emitted[e0:]] == [(w['re'], w['im']) for w in want_outs]
run_frame([(rng.randrange(-300, 301), rng.randrange(-300, 301)) for _ in range(7)],
          tag='after_midframe_cfg')

# Mid-frame reset aborts; recovery is clean after reconfiguration.
run_frame([(rng.randrange(-1000, 1001), 0) for _ in range(6)],
          make_cfg(4, tail=0), tag='pre_reset')
for x in [(5, 0), (6, 0)]:
    for _ in range(800000):
        sr, _ = tick(sv=1, sd=x, su=int(x == (5, 0)), sl=0)
        if sr:
            break
tick(rst=0); tick(rst=0, sv=1, sd=(9, 0), su=1, sl=1)
run_frame([(rng.randrange(-32768, 32768), 0) for _ in range(6)],
          make_cfg(4, tail=0), tag='post_reset')
# Reset while a data output is stalled pending: result discarded.
assert not configure(make_cfg(3, tail=1))
xs2 = [(7, 0), (-9, 0), (4, 0), (2, 0)]
feed(xs2[:-1], mark_last=False)
wait_idle()   # drain the third sample's pending emit before stalling
for _ in range(800000):
    sr, _ = tick(sv=1, sd=xs2[-1], su=0, sl=1, mr=0, pr=0)
    if sr:
        break
else:
    raise AssertionError('stall feed timeout')
for _ in range(60):
    tick(mr=0, pr=0)
    if o.m_valid:
        break
assert o.m_valid, 'no stalled data beat to reset'
for _ in range(10):
    tick(mr=0, pr=0)
tick(rst=0, mr=0, pr=0); tick(rst=0)
# Reset while the peak summary is stalled pending.
assert not configure(make_cfg(3, tail=1))
feed([(3, 0), (-5, 0), (6, 0)], pr_hold=0)
for _ in range(200):
    tick(pr=0)
    if o.p_valid:
        break
assert o.p_valid, 'no stalled peak to reset'
for _ in range(10):
    tick(pr=0)
tick(rst=0, pr=0); tick(rst=0)
run_frame([(rng.randrange(-2000, 2001), 0) for _ in range(5)],
          make_cfg(3, tail=1), tag='post_stall_reset')

# Long stalls on pending outputs: fields stay constant (per-row compare).
xs = [(rng.randrange(-32768, 32768), 0) for _ in range(16)]
run_frame(xs, make_cfg(6, tail=1), stall_first=64, fuzz=True, tag='long_stall')

# Marker faults: missing SOF then a mid-frame SOF; sticky flag, recovery.
# Pending beats drain passively during the wait for the peak beat.
assert o.marker_error == 0
feed([(3, 0), (4, 0), (5, 0)], drop_user=True)
assert o.marker_error == 1
drain_peak(len(peaks) + 1)
feed([(1, 0), (2, 0), (3, 0), (4, 0)], extra_user=2)
assert o.marker_error == 1
drain_peak(len(peaks) + 1)
tick(rst=0); tick(rst=0)
assert o.marker_error == 0
run_frame([(2, 0), (3, 0)], make_cfg(2, tail=1), tag='post_marker_reset')

# Randomized soak across legal configurations.
for i in range(14):
    nt = rng.choice([1, 2, 3, 5, 8, 16, 31, 64])
    cplx = rng.randrange(2); d = rng.randrange(2)
    cj = rng.randrange(2) if cplx else 0
    tl = rng.randrange(2)
    cfg = make_cfg(nt, cplx=cplx, dir=d, conj=cj, tail=tl)
    n = rng.randrange(nt if tl == 0 else 1, nt + 12)
    xs = [(rng.randrange(SMIN, SMAX + 1),
           rng.randrange(SMIN, SMAX + 1) if cplx else 0) for _ in range(n)]
    run_frame(xs, cfg, fuzz=(i % 3 == 0), tag=f'soak{i}')

for _ in range(10):
    tick()
# Timing: first m_valid rise = accept + steps + 1; tail-driven emit gap =
# steps + 1; sample-driven emit gap = steps + 2; p_valid rises one cycle
# after the last data beat is accepted.
for f in frames:
    steps = f['steps']
    assert len(f['rise_cycles']) == f['outputs'], f
    if f['timed'] and f['outputs']:
        # First emitted beat rises steps+1 cycles after the accept that
        # produced it (accept index ntaps-1 in VALID mode, index 0 in FULL).
        acc = f['accept_cycles']
        prod = 0 if f['tail'] or f['ntaps'] == 1 else f['ntaps'] - 1
        assert f['rise_cycles'][0] == acc[prod] + steps + 1, (f, acc[prod])
        gaps = [b - a for a, b in zip(f['rise_cycles'], f['rise_cycles'][1:])]
        assert all(g in (steps + 1, steps + 2) for g in gaps), f
fixture = '\n'.join(rows) + '\n'
(OUT / 'vectors.txt').write_text(fixture)
TB = '''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,su=0,sl=0,mr=0,pr=0;
reg[6:0]cn=0;reg[3:0]cm=0;reg[1:0]ct=0;reg[2047:0]ctaps=0;reg[31:0]sd=0;
wire sr,cr,cd,ce,mv,mu,ml,pv,pe,me;wire[95:0]md,pd;wire[15:0]mp,pp;wire[48:0]pm;
correlation_stream dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_pos(mp),.m_tuser(mu),.m_tlast(ml),.m_tvalid(mv),.m_ready(mr),
 .p_pos(pp),.p_tdata(pd),.p_mag(pm),.p_error(pe),.p_valid(pv),.p_ready(pr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_ntaps(cn),.cfg_mode(cm),.cfg_tail(ct),
 .cfg_taps(ctaps),.cfg_done(cd),.cfg_error(ce),.marker_error(me));
integer f,nn,row,rr,vv,cn_,cm_,ctl_,ss,su_,sl_,rdy,prr,esr,ecr,ecd,ece,eme,ev,mp_,mu_,ml_,pv_,pp_,pe_;
reg[31:0]dd;reg[2047:0]ctp_;reg[95:0]emd,epd;reg[48:0]epm;
initial begin f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin @(negedge clk);
  nn=$fscanf(f,"%d %d %d %d %d %h %d %h %d %d %d %d %d %d %d %d %d %d %h %h %d %d %d %h %h %h %d\\n",
   rr,vv,cn_,cm_,ctl_,ctp_,ss,dd,su_,sl_,rdy,prr,esr,ecr,ecd,ece,eme,ev,emd,mp_,mu_,ml_,pv_,pp_,epd,epm,pe_);
  if(nn!=27)$fatal(1,"fixture row=%0d n=%0d",row,nn);
  rst_n=rr;cv=vv;cn=cn_[6:0];cm=cm_[3:0];ct=ctl_[1:0];ctaps=ctp_;sv=ss;sd=dd;su=su_;sl=sl_;mr=rdy;pr=prr;#1;
  if({sr,cr,cd,ce,me,mv,mu,ml,pv,pe}!=={esr[0],ecr[0],ecd[0],ece[0],eme[0],ev[0],mu_[0],ml_[0],pv_[0],pe_[0]})
   $fatal(1,"control row=%0d got=%b expected=%b",row,{sr,cr,cd,ce,me,mv,mu,ml,pv,pe},
    {esr[0],ecr[0],ecd[0],ece[0],eme[0],ev[0],mu_[0],ml_[0],pv_[0],pe_[0]});
  if(md!==emd||mp!==mp_[15:0]||pp!==pp_[15:0]||pd!==epd||pm!==epm)
   $fatal(1,"data row=%0d got=%h/%0d/%0d/%h/%h expected=%h/%0d/%0d/%h/%h",row,
    md,mp,pp,pd,pm,emd,mp_,pp_,epd,epm);
  @(posedge clk);#1;row=row+1;end
 $display("PASS rows=%0d",row);$finish;end
endmodule
'''
(OUT / 'tb.sv').write_text(TB)
def run(cmd, name, reject=False):
    p = subprocess.run(cmd, cwd=OUT, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / name).write_text(p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(name + ': ' + p.stdout)
run([str(tool / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb', '-o',
     'test.vvp', str(RTL), 'tb.sv'], 'compile.log')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'run.log')
negatives = []
# Expected-side field mutations must be caught by the checker.
# columns: 0rst 1cv 2nt 3mode 4tail 5taps 6sv 7sd 8su 9sl 10mr 11pr
# 12sr 13cr 14cd 15ce 16me 17mv 18mdata 19mpos 20mu 21ml 22pv 23ppos
# 24pdata 25pmag 26pe
for field, label, ishex in [(18, 'm_data', True), (17, 'm_valid', False),
                            (19, 'm_pos', True), (21, 'm_last', False),
                            (20, 'm_user', False), (22, 'p_valid', False),
                            (24, 'p_data', True), (25, 'p_mag', True),
                            (26, 'p_error', False), (12, 's_ready', False),
                            (13, 'cfg_ready', False), (14, 'cfg_done', False),
                            (15, 'cfg_error', False), (16, 'marker_error', False)]:
    altered = rows.copy()
    if label in ('m_data', 'm_pos', 'm_last', 'm_user', 'm_valid'):
        idx = next(i for i, r in enumerate(altered)
                   if i > 20 and r.split()[17] == '1')
    elif label in ('p_valid', 'p_data', 'p_mag', 'p_error'):
        idx = next(i for i, r in enumerate(altered)
                   if i > 20 and r.split()[22] == '1')
    elif label == 'cfg_done':
        idx = next(i for i, r in enumerate(altered) if r.split()[14] == '1')
    elif label == 'cfg_error':
        idx = next(i for i, r in enumerate(altered) if r.split()[15] == '1')
    elif label == 'marker_error':
        idx = next(i for i, r in enumerate(altered) if r.split()[16] == '1')
    else:
        idx = 40
    cells = altered[idx].split()
    cells[field] = f'{int(cells[field], 16) ^ 1:x}' if ishex else str(int(cells[field]) ^ 1)
    altered[idx] = ' '.join(cells)
    (OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
    run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'negative_' + label + '.log', reject=True)
    negatives.append(label)
(OUT / 'vectors.txt').write_text(fixture)
# Output-order mutation: swap two different emitted expected values.
altered = rows.copy()
indices = [i for i, r in enumerate(rows)
           if r.split()[17] == '1' and r.split()[10] == '1']
j = next(j for j in range(len(indices) - 1)
         if rows[indices[j]].split()[18] != rows[indices[j + 1]].split()[18])
a, bb = indices[j:j + 2]; ca, cb = altered[a].split(), altered[bb].split()
ca[18], cb[18] = cb[18], ca[18]
altered[a] = ' '.join(ca); altered[bb] = ' '.join(cb)
(OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'negative_output_order.log', reject=True)
negatives.append('output_order')
(OUT / 'vectors.txt').write_text(fixture)
# Stimulus mutation: a corrupted accepted sample must change the results.
altered = rows.copy()
idx = next(i for i, r in enumerate(rows)
           if i > 5 and r.split()[6] == '1' and r.split()[12] == '1')
cells = altered[idx].split(); cells[7] = f'{int(cells[7], 16) ^ 1:08x}'
altered[idx] = ' '.join(cells)
(OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'negative_stimulus.log', reject=True)
negatives.append('stimulus')
(OUT / 'vectors.txt').write_text(fixture)
summary = {'status': 'PASS', 'cycles': len(rows), 'frames': len(frames),
           'inputs_accepted': len(handshakes), 'data_emitted': len(emitted),
           'peaks_emitted': len(peaks), 'config_events': cfg_events,
           'resets': resets, 'negative_tests': negatives,
           'timing': {'first_m_valid_rise_minus_accept': 'steps + 1',
                      'emit_gap': 'steps + 1 (tail) / steps + 2 (sample)',
                      'p_valid_rise': 'last data accept + 1'},
           'rtl_sha256': hashlib.sha256(RTL.read_bytes()).hexdigest(),
           'scope': 'cycle-level RTL simulation only; no routed timing or board acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT); print('PASS cycles', len(rows), 'frames', len(frames),
                  'emitted', len(emitted), 'peaks', len(peaks))
