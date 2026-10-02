"""Cycle-exact RTL verification for DSP-07 agc_stream.

Generates a per-cycle fixture (inputs + expected outputs) from the Python
cycle oracle, drives an iverilog testbench that compares every output every
cycle (held-output stability included), then proves the checker rejects
mutated fixtures.  No board access; RTL simulation only.
"""
import os, sys, json, math, random, subprocess, hashlib
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
env['PATH'] = (str(tool / 'bin') + os.pathsep + str(tool / 'lib')
               + os.pathsep + env['PATH'])
RTL = BASE / 'rtl/agc_stream.sv'
rng = random.Random(0xA6C7)
o = R.CycleModel()
rows = []
stats = {'accepts': 0, 'outputs': 0, 'configs': 0, 'config_errors': 0,
         'resets': 0, 'clip_seen': 0, 'sof': 0, 'eol': 0,
         'stalled_cycles': 0}


def pack_cfg(f):
    """cfg word layout (LSB->MSB): clear,bypass,mute,mode,est[7:4],
    release[11:8], attack[15:12], gmax[24:16] s9, gmin[33:25] s9,
    target[40:34]."""
    full = dict(target=100, gmin=-96, gmax=32, attack=3, release=10,
                est=6, mode=0, mute=0, bypass=0, clear=0)
    if f:
        full.update(f)
    return ((full['target'] & 0x7f) << 34
            | (full['gmin'] & 0x1ff) << 25
            | (full['gmax'] & 0x1ff) << 16
            | (full['attack'] & 0xf) << 12
            | (full['release'] & 0xf) << 8
            | (full['est'] & 0xf) << 4
            | (full['mode'] & 1) << 3
            | (full['mute'] & 1) << 2
            | (full['bypass'] & 1) << 1
            | (full['clear'] & 1))


def tick(rst=1, cfg=None, sv=0, x=0, su=0, sl=0, mr=1):
    cv = int(cfg is not None)
    exp = o.tick(rst=rst, cfg=cfg, sv=sv, x=x, su=su, sl=sl, mr=mr)
    rows.append('%d %d %x %d %x %d %d %d %d %d %d %x %d %d %d %d %d %x %x' % (
        rst, cv, pack_cfg(cfg), sv, x & 0xffff, su, sl, mr,
        exp['s_tready'], exp['cfg_ready'], exp['m_tvalid'],
        exp['m_tdata'] & 0xffff, exp['m_tuser'], exp['m_tlast'],
        exp['cfg_done'], exp['cfg_error'], exp['clip_sticky'],
        exp['env_code'], exp['gain_code'] & 0x3ff))
    if not rst:
        stats['resets'] += 1
    else:
        if sv and exp['s_tready']:
            stats['accepts'] += 1
            stats['sof'] += su
            stats['eol'] += sl
        if exp['m_tvalid'] and mr:
            stats['outputs'] += 1
        if exp['m_tvalid'] and not mr:
            stats['stalled_cycles'] += 1
        if exp['clip_sticky']:
            stats['clip_seen'] += 1
        if exp['cfg_done']:
            stats['configs'] += 1
        if exp['cfg_error']:
            stats['config_errors'] += 1
    return exp


def configure(f=None, fuzz=False):
    for _ in range(20000):
        e = tick(cfg=f or {}, mr=int(rng.random() < .8 if fuzz else 1))
        if e['cfg_ready']:
            return e
    raise AssertionError('cfg timeout')


def feed(x, su=0, sl=0, fuzz=True, hold_check=True):
    if fuzz:
        for _ in range(rng.randrange(3)):
            tick(mr=int(rng.random() < .8))
    for _ in range(20000):
        e = tick(sv=1, x=x, su=su, sl=sl,
                 mr=int(rng.random() < .8 if fuzz else 1))
        if e['s_tready']:
            return e
    raise AssertionError('feed timeout')


def feed_frame(xs, fuzz=True):
    for i, x in enumerate(xs):
        feed(x, su=int(i == 0), sl=int(i == len(xs) - 1), fuzz=fuzz)


def drain(n=20000):
    for _ in range(n):
        e = tick(mr=int(rng.random() < .9))
        if not e['m_tvalid'] and all(p is None for p in o.v):
            return
    raise AssertionError('drain timeout')


def tone(amp, k, n):
    return [max(-32768, min(32767, int(round(amp * 32768 *
            math.sin(2 * math.pi * k * i / 64))))) for i in range(n)]


def wait_done(limit=32):
    """cfg_done/cfg_error pulse the row after the accept edge."""
    for _ in range(limit):
        if o.cfg_done or o.cfg_error:
            return o.cfg_done, o.cfg_error
        tick(mr=1)
    raise AssertionError('cfg done/error timeout')


# ---------------------------------------------------------------------------
# stimulus program
# ---------------------------------------------------------------------------
tick(rst=0); tick(rst=0); tick(rst=0)

# default config: frames with SOF/EOL, fuzzed handshake
for i in range(4):
    feed_frame(tone(0.3 - 0.05 * i, 3 + i, 24 + 8 * i))
drain()

# level step: loud -> quiet -> loud, markers on
for _ in range(3):
    feed_frame(tone(0.8, 5, 96))
    feed_frame(tone(0.01, 5, 160))
drain()

# config sweep incl. linear mode, mute, bypass, clear retain
sweep = [
    dict(target=96, attack=2, release=8, est=4, clear=1),
    dict(target=110, gmin=-60, gmax=60, attack=0, release=0, est=0),
    dict(target=80, attack=5, release=12, est=8, mode=1),
    dict(target=100, mode=1, attack=15, release=15, est=3),
    dict(target=90, mute=1),
    dict(target=90, mute=0, bypass=1),
    dict(target=100, bypass=0, clear=1),
    dict(target=120, gmax=16, attack=1, release=1, est=2),   # heavy clipping
    dict(target=60, gmin=-8, gmax=-4, attack=4, release=4, est=6),
]
for f in sweep:
    configure(f, fuzz=True)
    assert wait_done() == (1, 0)
    feed_frame(tone(0.4, 4, 64))
    feed_frame([rng.randrange(-32768, 32768) for _ in range(48)])
drain()

# illegal configs: whole-request reject, state preserved
legal = dict(target=96, attack=2, release=8, est=5)
configure(legal)
assert wait_done() == (1, 0)
for bad in [dict(target=121), dict(target=127), dict(gmin=20, gmax=-20),
            dict(gmin=0, gmax=-1), dict(target=120, gmin=100, gmax=-100)]:
    configure(dict(legal, **bad))
    assert wait_done() == (1, 1), bad   # done pulses, error flags reject
feed_frame(tone(0.3, 4, 64))
drain()

# cfg_valid held while pipe busy: held, not accepted early
feed_frame(tone(0.5, 6, 32))
for _ in range(6):
    e = tick(cfg=dict(target=70), sv=1, x=1234, mr=0)  # cfg blocked, stalled
assert o.cfg_done == 0
drain()
configure(dict(target=70, clear=1))
assert wait_done() == (1, 0)
feed_frame(tone(0.5, 6, 64))
drain()

# mid-stream reset mid-frame and mid-output
for _ in range(6):
    feed_frame(tone(0.6, 7, 40), fuzz=True)
    for _ in range(rng.randrange(8)):
        tick(mr=int(rng.random() < .5), sv=1, x=999)
    tick(rst=0, mr=0)
    tick(rst=0)
    configure(dict(target=100, clear=1))
    assert wait_done() == (1, 0)
    feed_frame(tone(0.2, 3, 40))
drain()

# long output stall: hold m_ready low across a frame boundary
feed_frame(tone(0.7, 2, 40))
for _ in range(200):
    tick(mr=0, sv=int(rng.random() < .4), x=rng.randrange(-32768, 32768))
drain()

# randomized soak: mixed frames, random reconfig, resets
for k in range(40):
    r = rng.random()
    if r < 0.15:
        configure(dict(target=rng.randrange(0, 121),
                       gmin=rng.randrange(-96, 33),
                       gmax=rng.randrange(-96, 97),
                       attack=rng.randrange(16), release=rng.randrange(16),
                       est=rng.randrange(16), mode=rng.randrange(2),
                       mute=rng.randrange(2), bypass=rng.randrange(2),
                       clear=rng.randrange(2)), fuzz=True)
        wait_done()
    elif r < 0.25:
        tick(rst=0)
    else:
        n = rng.randrange(4, 80)
        feed_frame([rng.randrange(-32768, 32768) for _ in range(n)],
                   fuzz=rng.random() < .7)
drain()

assert stats['accepts'] > 3000 and stats['outputs'] > 3000
assert stats['sof'] == stats['eol'] > 0
assert stats['clip_seen'] > 0 and stats['stalled_cycles'] > 0
assert stats['configs'] > 10 and stats['config_errors'] >= 5

fixture = '\n'.join(rows) + '\n'
(OUT / 'vectors.txt').write_text(fixture)

TB = '''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,su=0,sl=0,mr=0;reg[40:0]cw=0;reg signed[15:0]sd=0;
wire sr,cr,mv,mu,ml,cd,ce,st;wire signed[15:0]md;wire[6:0]ec;wire signed[9:0]gc;
agc_stream dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.s_tuser(su),.s_tlast(sl),.m_tdata(md),.m_tuser(mu),
 .m_tlast(ml),.m_tvalid(mv),.m_tready(mr),.cfg_valid(cv),.cfg_ready(cr),
 .cfg_target(cw[40:34]),.cfg_gmin(cw[33:25]),.cfg_gmax(cw[24:16]),
 .cfg_attack(cw[15:12]),.cfg_release(cw[11:8]),.cfg_est(cw[7:4]),
 .cfg_mode(cw[3]),.cfg_mute(cw[2]),.cfg_bypass(cw[1]),.cfg_clear(cw[0]),
 .cfg_done(cd),.cfg_error(ce),.clip_sticky(st),.env_code(ec),.gain_code(gc));
integer f,n,row,rr,vv,ss,uu,ll,ready,esr,ecr,ev,eu,el,ed,ee,es;reg[40:0]co;
reg[15:0]xd,yd;reg[6:0]eec;reg[9:0]egc;
initial begin f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
while(!$feof(f))begin @(negedge clk);
n=$fscanf(f,"%d %d %h %d %h %d %d %d %d %d %d %h %d %d %d %d %d %h %h\\n",
 rr,vv,co,ss,xd,uu,ll,ready,esr,ecr,ev,yd,eu,el,ed,ee,es,eec,egc);
if(n!=19)$fatal(1,"fixture row=%0d n=%0d",row,n);
rst_n=rr;cv=vv;cw=co;sv=ss;sd=xd;su=uu;sl=ll;mr=ready;#1;
if({sr,cr,mv,cd,ce,st}!=={esr[0],ecr[0],ev[0],ed[0],ee[0],es[0]})
 $fatal(1,"control row=%0d got=%b exp=%b",row,{sr,cr,mv,cd,ce,st},
 {esr[0],ecr[0],ev[0],ed[0],ee[0],es[0]});
if({ec,gc}!=={eec,egc})$fatal(1,"status row=%0d got=%h/%h exp=%h/%h",
 row,ec,gc,eec,egc);
if(mv && {md,mu,ml}!=={yd,eu[0],el[0]})
 $fatal(1,"data row=%0d got=%h/%b/%b exp=%h/%b/%b",row,md,mu,ml,yd,eu,el);
@(posedge clk);#1;row=row+1;end
$display("PASS rows=%0d",row);$finish;end endmodule
'''
(OUT / 'tb.sv').write_text(TB)


def run(cmd, name, reject=False):
    p = subprocess.run(cmd, cwd=OUT, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / name).write_text(p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(name + ':\n' + p.stdout)


run([str(tool / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
     '-o', 'test.vvp', str(RTL), 'tb.sv'], 'compile.log')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'run.log')

# mutation rejection: corrupt each expected field / ordering
negatives = []
# columns: 0 rst 1 cv 2 cfgw 3 sv 4 sd 5 su 6 sl 7 mr
#          8 sr 9 cr 10 mv 11 md 12 mu 13 ml 14 cd 15 ce 16 st 17 ec 18 gc
for field, label in [(8, 's_ready'), (9, 'cfg_ready'), (10, 'valid'),
                     (11, 'data'), (12, 'user'), (13, 'last'), (14, 'done'),
                     (15, 'error'), (16, 'clip_sticky'), (17, 'env_code'),
                     (18, 'gain_code')]:
    altered = rows.copy()
    idx = next(i for i, r in enumerate(rows)
               if i > 40 and r.split()[field] != '0')
    cells = altered[idx].split()
    if field in (11, 17, 18):
        cells[field] = '%x' % (int(cells[field], 16) ^ 1)
    else:
        cells[field] = str(int(cells[field]) ^ 1)
    altered[idx] = ' '.join(cells)
    (OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
    run([str(tool / 'bin/vvp.exe'), 'test.vvp'],
        'negative_%s.log' % label, reject=True)
    negatives.append(label)
(OUT / 'vectors.txt').write_text(fixture)

# output-order mutation: swap two distinct emitted data beats
altered = rows.copy()
idxs = [i for i, r in enumerate(rows)
        if r.split()[10] == '1' and r.split()[7] == '1']
j = next(j for j in range(len(idxs) - 1)
         if rows[idxs[j]].split()[11] != rows[idxs[j + 1]].split()[11])
a, b = idxs[j:j + 2]
ca, cb = altered[a].split(), altered[b].split()
ca[11], cb[11] = cb[11], ca[11]
altered[a], altered[b] = ' '.join(ca), ' '.join(cb)
(OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'negative_order.log',
    reject=True)
negatives.append('order')
(OUT / 'vectors.txt').write_text(fixture)

summary = {'status': 'PASS',
           'rtl_sha256': hashlib.sha256(RTL.read_bytes()).hexdigest(),
           'cycles': len(rows), 'stats': stats,
           'negative_tests': negatives, 'latency': 3, 'ii': 1,
           'scope': 'cycle-level RTL simulation only; no routed timing or '
                    'board acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
