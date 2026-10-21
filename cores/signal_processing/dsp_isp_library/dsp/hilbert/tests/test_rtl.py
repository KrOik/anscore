"""Cycle-level fixture regression for hilbert_core.

A Python oracle reproduces stream/config timing bit-exactly; a generated
testbench replays every cycle and compares control and payload fields.
Corrupted fixtures and illegal static parameters must be rejected.
"""
import os, sys, json, random, subprocess, hashlib, math
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
sys.path.insert(0, str(BASE / 'models'))
import reference as ref

OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
# oss-cad-suite: lib first avoids DLL shadowing; external PATH dirs carry
# incompatible mingw DLLs, so only System32 is appended.
env['PATH'] = str(TOOL / 'lib') + os.pathsep + str(TOOL / 'bin') + os.pathsep + \
    os.environ.get('SystemRoot', 'C:\\Windows') + r'\System32'
RTLS = [BASE / 'rtl/hilbert_analytic.sv', BASE / 'rtl/phase_freq.sv',
        BASE / 'rtl/hilbert_core.sv']
PAIRS, LANES = 16, 4
ROUNDS = (PAIRS + LANES - 1) // LANES        # 4
PFD = 21                                    # phase_freq stages

rng = random.Random(0xB112)
model = ref.HilbertModel()
pf_pipe = [None] * PFD
mac_round = 0
pending = None          # analytic result waiting for the output slot
postv_elem = None       # (i,q,clip) offered to phase_freq
prev_phase = 0
have_prev = False
cd = ce = 0
rows = []
accepted = emitted = aborted = configs = resets = 0


def commit(slot):
    """freq commit happens when a sample reaches the output slot."""
    global prev_phase, have_prev
    if slot is None:
        return None
    if slot['zero'] or not have_prev:
        fq = 0
    else:
        fq = ref.wrap16(slot['phase'] - prev_phase)
    prev_phase = slot['phase']
    have_prev = True
    return dict(slot, freq=fq)


def tick(rst=1, sv=0, x=0, mr=1, cfg=None):
    global pf_pipe, mac_round, pending, postv_elem, prev_phase, have_prev
    global cd, ce, model
    global accepted, emitted, aborted, configs, resets
    cv = int(cfg is not None)
    pr, co, cl = cfg or (0, 0, 0)
    mv = int(pf_pipe[-1] is not None)
    md = pf_pipe[-1] or {'i': 0, 'q': 0, 'env': 0, 'phase': 0, 'freq': 0,
                         'clip': 0, 'zero': 0}
    packed = (md['freq'] & 0xffff) << 64 | md['phase'] << 48 | \
        md['env'] << 32 | (md['q'] & 0xffff) << 16 | (md['i'] & 0xffff)
    mu = md['zero'] << 1 | md['clip']
    empty = mac_round == 0 and postv_elem is None and \
        all(p is None for p in pf_pipe)
    advance = not mv or mr
    cr = int(rst and empty)
    sr = int(rst and mac_round == 0 and not cv)
    chex = format(sum((c & 0x3ffff) << (18 * j) for j, c in enumerate(co)), 'x') \
        if cv else '0'
    rows.append(f'{rst} {sv} {x & 0xffff:x} {mr} {cv} {pr} {cl} {chex} '
                f'{sr} {cr} {mv} {packed:x} {mu} {cd} {ce}')
    cd = ce = 0
    if not rst:
        aborted += (mac_round != 0) + (postv_elem is not None) + \
            sum(p is not None for p in pf_pipe)
        model.clear()
        pf_pipe = [None] * PFD
        mac_round = 0
        pending = postv_elem = None
        prev_phase = 0
        have_prev = False
        resets += 1
        return sr, cr
    if mv and mr:
        emitted += 1
    if cv and cr:
        cd = 1
        configs += 1
        if model.config(pr, list(co), bool(cl)):
            if cl:
                prev_phase = 0
                have_prev = False
        else:
            ce = 1
    postv_pre = postv_elem
    if advance:
        pf_pipe = [postv_pre] + pf_pipe[:-1]
        if pf_pipe[-1] is not None:
            pf_pipe[-1] = commit(pf_pipe[-1])
        postv_elem = None
    if sr and sv:
        i16, q16, clip = model.analytic(x)
        pending = {'i': i16, 'q': q16, 'clip': int(clip)}
        mac_round = ROUNDS
        accepted += 1
    elif mac_round != 0:
        if mac_round == 1:
            if postv_pre is None:
                postv_elem = pending
                pending = None
                mac_round = 0
        else:
            mac_round -= 1
    return sr, cr


def configure(pr, co, cl=0):
    for _ in range(100000):
        _, c = tick(mr=int(rng.random() < .75), cfg=(pr, co, cl))
        if c:
            return
    raise AssertionError('config timeout')


def feed(xs, randomize=True):
    for x in xs:
        if randomize:
            for _ in range(rng.randrange(3)):
                tick(mr=int(rng.random() < .7))
        for _ in range(100000):
            s, _ = tick(sv=1, x=x, mr=int(not randomize or rng.random() < .7))
            if s:
                break
        else:
            raise AssertionError('input timeout')


# pf stage completion: attach env/phase when slot enters pf (computed from i,q)
# -- wrap: model supplies i,q,clip; env/phase/zero computed at commit time.
_orig_commit = commit

def commit(slot):
    i16, q16 = slot['i'], slot['q']
    envv = ref.envelope(i16, q16)
    zero = i16 == 0 and q16 == 0
    ph = 0 if zero else ref.phase(i16, q16)
    return _orig_commit(dict(slot, env=envv, zero=int(zero), phase=ph))

tick(rst=0)
DC = list(ref.DEFAULT_COEFFS)
# Full-rate and stalled tones across the qualified band.
for fi, f in enumerate((0.05, 0.1, 0.2, 0.25, 0.33, 0.45)):
    xs = [round(12000 * math.cos(2 * math.pi * f * k)) for k in range(700)]
    feed(xs, randomize=fi % 2 == 0)
# Edge/degraded frequencies and DC.
for f in (0.01, 0.03, 0.48):
    feed([round(10000 * math.cos(2 * math.pi * f * k)) for k in range(400)], True)
feed([10000] * 150, True)
feed([0] * 120, False)
# Extremes, saturation and random noise.
feed([-32768, 32767] * 200, True)
feed([rng.randrange(-32768, 32768) for _ in range(900)], True)
# Runtime coefficient/pair reconfiguration.
c8 = list(ref.design(8)[0]) + [0] * 8
configure(8, c8, 1)
feed([round(12000 * math.cos(2 * math.pi * 0.25 * k)) for k in range(500)], True)
configure(4, list(ref.design(4)[0]) + [0] * 12, 1)
feed([rng.randrange(-10000, 10001) for _ in range(300)], True)
configure(16, DC, 0)   # no clear: history retained intentionally
feed([7777] * 100, True)
# Illegal configs rejected; state preserved.
for bad in (0, 17, 32, 33):
    configure(bad, DC, 1)
    assert ce == 1
feed([1234] * 60, True)
# Back-to-back accept at II while the previous result is still draining.
feed([rng.randrange(-20000, 20001) for _ in range(400)], False)
# Reset mid-stream aborts in-flight samples.
for _ in range(10):
    feed([rng.randrange(-30000, 30001) for _ in range(rng.randrange(5, 40))], True)
    tick(mr=0)
    tick(rst=0, mr=0)
    configure(16, DC, 1)
    feed([rng.randrange(-30000, 30001) for _ in range(50)], True)
for _ in range(40):
    tick()
assert accepted == emitted + aborted, (accepted, emitted, aborted)
fixture = '\n'.join(rows) + '\n'
(OUT / 'vectors.txt').write_text(fixture)

TB = '''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,cv=0,cl=0;reg signed[15:0]sd=0;
reg[5:0]pr=0;reg[287:0]co=0;
wire sr,cr,mv,cd,ce;wire[79:0]md;wire[1:0]mu;
hilbert_core dut(clk,rst_n,sd,sv,sr,md,mv,mr,mu,cv,cr,pr,co,cl,cd,ce);
integer f,n,row,rr,vv,x,ready,cc,pp,ll,esr,ecr,ev,eu,ed,ee;reg[287:0]ccx;
reg[79:0]expected;
initial begin
f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
while(!$feof(f))begin @(negedge clk);
n=$fscanf(f,"%d %d %h %d %d %d %d %h %d %d %d %h %d %d %d\\n",
 rr,vv,x,ready,cc,pp,ll,ccx,esr,ecr,ev,expected,eu,ed,ee);
if(n!=15)$fatal(1,"fixture row=%0d n=%0d",row,n);
rst_n=rr;sv=vv;sd=x;mr=ready;cv=cc;pr=pp;cl=ll;co=ccx;#1;
if({sr,cr,mv,cd,ce}!=={esr[0],ecr[0],ev[0],ed[0],ee[0]})
 $fatal(1,"control row=%0d got=%b exp=%b",row,{sr,cr,mv,cd,ce},
 {esr[0],ecr[0],ev[0],ed[0],ee[0]});
if(mv && {md,mu}!=={expected,eu[1:0]})
 $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,expected,eu);
@(posedge clk);#1;row=row+1;end
$display("PASS rows=%0d",row);$finish;end endmodule
'''
(OUT / 'tb.sv').write_text(TB)


def run(cmd, name, reject=False):
    p = subprocess.run(cmd, cwd=OUT, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / name).write_text(p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(name + ': ' + p.stdout[:3000])


run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
     '-o', 'test.vvp'] + [str(r) for r in RTLS] + ['tb.sv'], 'compile.log')
run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], 'run.log')
negatives = []
for field, label in [(11, 'data'), (10, 'valid'), (8, 'ready'), (12, 'user'),
                     (13, 'cfg_done'), (14, 'cfg_error')]:
    altered = rows.copy()
    idx = next(i for i, r in enumerate(rows) if i > 40 and r.split()[10] == '1')
    cells = altered[idx].split()
    cells[field] = f'{int(cells[field], 16) ^ 1:x}' if field == 11 \
        else str(int(cells[field]) ^ 1)
    altered[idx] = ' '.join(cells)
    (OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
    run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], 'negative_' + label + '.log',
        reject=True)
    negatives.append(label)
(OUT / 'vectors.txt').write_text(fixture)
# output-order corruption
altered = rows.copy()
indices = [i for i, r in enumerate(rows)
           if r.split()[10] == '1' and r.split()[3] == '1']
j = next(j for j in range(len(indices) - 1)
         if rows[indices[j]].split()[11] != rows[indices[j + 1]].split()[11])
a, b = indices[j:j + 2]
ca, cb = altered[a].split(), altered[b].split()
ca[11], cb[11] = cb[11], ca[11]
altered[a] = ' '.join(ca)
altered[b] = ' '.join(cb)
(OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], 'negative_order.log', reject=True)
negatives.append('order')
(OUT / 'vectors.txt').write_text(fixture)
for parameter, value in [('PAIRS', 0), ('PAIRS', 33), ('LANES', 0), ('LANES', 5)]:
    (OUT / 'illegal.sv').write_text(
        'module illegal;hilbert_core #(.%s(%d))d(.clk(0),.rst_n(0),.s_tdata(0),'
        '.s_tvalid(0),.m_tready(0),.cfg_valid(0),.cfg_pairs(0),.cfg_coeffs(0),'
        '.cfg_clear(0));endmodule\n' % (parameter, value))
    run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-s', 'illegal', '-o',
         'illegal.vvp'] + [str(r) for r in RTLS] + ['illegal.sv'],
        f'static_{parameter}_{value}_compile.log')
    run([str(TOOL / 'bin/vvp.exe'), 'illegal.vvp'],
        f'static_{parameter}_{value}_run.log', reject=True)
    negatives.append(f'{parameter}_{value}')
summary = {'status': 'PASS', 'cycles': len(rows), 'accepted': accepted,
           'emitted': emitted, 'reset_aborted': aborted, 'configs': configs,
           'resets': resets, 'negative_tests': negatives,
           'ii_accept': ROUNDS + 1, 'mac_lanes': LANES,
           'rtl_sha256': {r.name: hashlib.sha256(r.read_bytes()).hexdigest()
                          for r in RTLS},
           'scope': 'cycle-level RTL simulation only; no routed timing or '
                    'board acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print('PASS cycles', len(rows), 'accepted', accepted, 'emitted', emitted)
