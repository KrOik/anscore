import os, sys, json, random, math, subprocess, hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (BankModel, Config, bitexact_block, coefficient,
                       window_rectangular, window_hann, window_hamming, window_custom,
                       pack_coeffs, pack_window, pack_thresholds, U80_MAX)
BASE = Path(__file__).resolve().parents[1]; ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f')); OUT.mkdir(parents=True)
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'; env = os.environ.copy()
env['PATH'] = str(tool / 'bin') + os.pathsep + str(tool / 'lib') + os.pathsep + env['PATH']
RTL = BASE / 'rtl/goertzel_bank.sv'
rng = random.Random(0x60E721); o = BankModel()
rows = []; clock = 0; handshakes = []; emitted = []; rises = []
cfg_events = []; resets = 0; prev_mv = 0

def tick(rst=1, sv=0, x=0, mr=1, cfg=None):
    """Apply one cycle of inputs, record expected outputs, advance state."""
    global clock, resets, prev_mv
    cv = int(cfg is not None)
    n, b, co, w, t = cfg if cv else (0, 0, [0] * 4, [0] * 256, [0] * 4)
    outs = o.outputs(rst, cv)
    rows.append(f'{rst} {cv} {n} {b} {pack_coeffs(co):x} {pack_window(w):x} {pack_thresholds(t):x} '
                f'{sv} {x & 0xffff:x} {mr} {outs["s_tready"]} {outs["cfg_ready"]} {outs["cfg_done"]} '
                f'{outs["cfg_error"]} {outs["m_valid"]} {outs["m_power"]:x} {outs["m_bin"]} '
                f'{outs["m_last"]} {outs["m_detect"]} {outs["m_error"]}')
    if rst and outs['s_tready'] and sv:
        handshakes.append(clock)
    if outs['m_valid'] and not prev_mv:
        rises.append(clock)
    prev_mv = outs['m_valid']
    if rst and outs['m_valid'] and mr:
        emitted.append((clock, outs['m_power'], outs['m_bin'], outs['m_last'],
                        outs['m_detect'], outs['m_error']))
    o.edge(rst, x, sv, mr, cv, n, b, co, w, t)
    if not rst:
        resets += 1
    clock += 1
    return outs['s_tready'], outs['cfg_ready']

def rbit(p=.75):
    return int(rng.random() < p)

def make_cfg(n, coeffs, window, thresholds, pad_w=0, pad_c=0, pad_t=0):
    """Full-width request; pad_* fills unused slots (ignored by the core)."""
    return (n, len(coeffs), list(coeffs) + [pad_c] * (4 - len(coeffs)),
            list(window) + [pad_w] * (256 - len(window)),
            list(thresholds) + [pad_t] * (4 - len(thresholds)))

def configure(cfg, fuzz=False):
    """Hold cfg_valid until accepted at a clean boundary; return error flag."""
    for _ in range(400000):
        _, cr = tick(mr=rbit() if fuzz else 1, cfg=cfg)
        if cr:
            return o.cfg_error  # pulse value right after the accepting edge
    raise AssertionError('config timeout')

def feed(xs, fuzz=False):
    for x in xs:
        if fuzz:
            for _ in range(rng.randrange(4)):
                tick(mr=rbit())
        for _ in range(400000):
            sr, _ = tick(sv=1, x=x, mr=rbit() if fuzz else 1)
            if sr:
                break
        else:
            raise AssertionError('input timeout')

def drain(nbins, fuzz=False, stall_first=0):
    t0 = len(emitted)
    for _ in range(stall_first):
        tick(mr=0)
    for _ in range(400000):
        tick(mr=rbit() if fuzz else 1)
        if len(emitted) - t0 >= nbins:
            break
    else:
        raise AssertionError('drain timeout')

blocks = []
def run_block(xs, cfg_tuple=None, fuzz=False, stall_first=0, tag=''):
    """Configure unless None (keep current), feed one block, drain, compare
    emitted results with the independent bit-exact functional model."""
    if cfg_tuple is not None:
        n, b, co, w, t = cfg_tuple
        err = configure(cfg_tuple, fuzz)
        assert not err, ('unexpected cfg reject', cfg_tuple[:2])
        cfg_events.append((n, b, 0))
    else:
        n, b, co, w, t = o.n, o.nbins, o.coeff, o.window, o.threshold
    mcfg = Config(n, tuple(co[:b]), tuple(w[:n]), tuple(t[:b]))
    assert len(xs) == n
    r0 = len(rises)
    feed(xs, fuzz)
    drain(b, fuzz, stall_first)
    got = emitted[-b:]
    want = bitexact_block(xs, mcfg)
    assert [g[1] for g in got] == [r['power'] for r in want], (tag, got, want)
    assert [g[2] for g in got] == [r['bin'] for r in want]
    assert [g[3] for g in got] == [r['last'] for r in want]
    assert [g[4] for g in got] == [r['detect'] for r in want]
    assert [g[5] for g in got] == [r['error'] for r in want]
    blocks.append({'tag': tag, 'n': n, 'bins': b, 'timed': not fuzz and not stall_first,
                   'last_input_cycle': handshakes[-1], 'rise_cycles': rises[r0:]})

tick(rst=0); tick(rst=0)
# Default post-reset config: n=1, one DC bin (c=2), unity window, threshold 0.
for x in (0, 1, -1, 1000, -32768, 32767):
    run_block([x], tag='reset_default')

# Sweep block length, bin count, window kind and frequencies.
sweep = [
    (1, [0.0], 'rect'), (2, [0.5, 0.0], 'rect'), (4, [0.25], 'hann'),
    (7, [2 / 7, 0.5], 'hamming'), (16, [0.0, 0.125, 0.5], 'rect'),
    (32, [3 / 32, 7.5 / 32, 0.3], 'hann'), (64, [0.0625, 0.25, 0.3735, 0.5], 'hamming'),
    (256, [0.375, 0.3735], 'rect')]
for n, freqs, wname in sweep:
    win = {'rect': window_rectangular, 'hann': window_hann,
           'hamming': window_hamming}[wname](n)
    coeffs = [coefficient(f) for f in freqs]
    cfg = make_cfg(n, coeffs, win, [0] * len(coeffs))
    stimuli = [
        [round(9000 * math.sin(2 * math.pi * freqs[0] * k)) for k in range(n)],
        [round(9000 * math.sin(2 * math.pi * ((freqs[0] + 0.5 / n) % 0.5) * k)) for k in range(n)],
        [0] * n,
        [32767 if k % 3 else -32768 for k in range(n)],
        [rng.randrange(-32768, 32768) for _ in range(n)],
        [32767 if k % 2 == 0 else -32768 for k in range(n)]]
    for j, xs in enumerate(stimuli):
        run_block(xs, cfg if j == 0 else None, fuzz=(j % 2 == 1),
                  stall_first=(13 if j == 2 else 0), tag=f'n{n}_{wname}_s{j}')

# Distinct per-bin thresholds: detection on the strong bin only.
n = 48; coeffs = [coefficient(f) for f in (0.0625, 0.25, 0.5)]
win = window_custom([32768 - k * 512 for k in range(n)])
xs = [round(9000 * math.sin(2 * math.pi * 0.25 * k) + 2500 * math.sin(2 * math.pi * 0.0625 * k)) for k in range(n)]
pre = bitexact_block(xs, Config(n, tuple(coeffs), win, (0, 0, 0)))
thr = [pre[0]['power'] + 1, pre[1]['power'] - 1, pre[2]['power'] + 1]
run_block(xs, make_cfg(n, coeffs, win, thr), tag='thresholds')
assert tuple(g[4] for g in emitted[-3:]) == (0, 1, 0)

# Unused config slots may carry arbitrary values without causing rejection.
cfg = make_cfg(8, [coefficient(0.25), coefficient(0.0)], window_rectangular(8), [5, 7],
               pad_w=65535, pad_c=-131073, pad_t=U80_MAX)
run_block([rng.randrange(-32768, 32768) for _ in range(8)], cfg, tag='unused_slots')

# Illegal requests reject the whole update atomically; the retained config is
# then proven by a fresh block.
assert not configure(make_cfg(4, [coefficient(0.25)], window_rectangular(4), [0]))
illegal = [
    make_cfg(0, [coefficient(0.25)], [0], [0]),
    make_cfg(257, [coefficient(0.25)], window_rectangular(256), [0]),
    (4, 0, [coefficient(0.25)] * 4, list(window_rectangular(4)) + [0] * 252, [0] * 4),
    (4, 5, [coefficient(0.25)] * 4, list(window_rectangular(4)) + [0] * 252, [0] * 4),
    make_cfg(4, [131073], window_rectangular(4), [0]),
    make_cfg(4, [-131073], window_rectangular(4), [0]),
    make_cfg(4, [coefficient(0.25)], [32769] + [32768] * 3, [0])]
for bad in illegal:
    err = configure(bad)
    assert err, ('illegal not rejected', bad[:2])
    cfg_events.append((bad[0], bad[1], 1))
    assert o.n == 4 and o.nbins == 1
run_block([100, -200, 300, -400], tag='retained_after_illegal')

# Config held mid-block: never accepted before the boundary and does not stall
# input mid-block; the running block still uses the old (n=4) configuration.
old_cfg = Config(4, (coefficient(0.25),), window_rectangular(4), (0,))
cfg_new = make_cfg(16, [coefficient(3 / 16)], window_hann(16), [0])
xs = [rng.randrange(-20000, 20001) for _ in range(4)]
feed(xs[:2])
t0e = len(emitted); r0 = len(rises)
for x in xs[2:]:
    for _ in range(400000):
        sr, cr = tick(sv=1, x=x, mr=1, cfg=cfg_new)
        assert not cr, 'mid-block config accepted'
        if sr:
            break
    else:
        raise AssertionError('feed timeout')
# Hold a pending input through the drain: at the boundary cycle cfg_ready and
# cfg_valid block s_tready, so the sample is never consumed by the old block.
for _ in range(400000):
    sr, cr = tick(sv=1, x=xs[0], mr=1, cfg=cfg_new)
    if cr:
        assert not sr  # cfg_valid at a clean boundary blocks s_tready
    if len(emitted) - t0e >= 1 and o.n == 16:
        break
else:
    raise AssertionError('boundary config timeout')
got = emitted[t0e:]
want = bitexact_block(xs, old_cfg)
assert [g[1] for g in got] == [r['power'] for r in want], (got, want)
assert o.n == 16 and o.nbins == 1
blocks.append({'tag': 'midblock_cfg_old', 'n': 4, 'bins': 1, 'timed': True,
               'last_input_cycle': handshakes[-1], 'rise_cycles': rises[r0:]})
run_block([rng.randrange(-5000, 5001) for _ in range(16)], tag='after_midblock_cfg')

# Mid-block reset aborts; recovery is clean. Reset restores the default
# n=1/DC configuration, so a legal config is re-applied before reuse.
run_block([rng.randrange(-1000, 1001) for _ in range(8)],
          make_cfg(8, [coefficient(0.125)], window_rectangular(8), [0]), tag='pre_reset')
for x in [5, 6]:
    for _ in range(400000):
        sr, _ = tick(sv=1, x=x)
        if sr:
            break
tick(rst=0); tick(rst=0, sv=1, x=9)
run_block([rng.randrange(-32768, 32768) for _ in range(8)],
          make_cfg(8, [coefficient(0.125)], window_rectangular(8), [0]), tag='post_reset')
# Reset while an output is stalled pending: the pending result is discarded.
run_block([rng.randrange(-32768, 32768) for _ in range(8)],
          make_cfg(8, [coefficient(0.25)], window_rectangular(8), [0]), tag='pre_stall_reset')
for x in [7] * 8:
    for _ in range(400000):
        sr, _ = tick(sv=1, x=x)
        if sr:
            break
for _ in range(400000):
    tick(mr=0)
    if o.m_valid:
        break
for _ in range(20):
    tick(mr=0)
tick(rst=0, mr=0); tick(rst=0)
run_block([rng.randrange(-32768, 32768) for _ in range(8)],
          make_cfg(8, [coefficient(0.25)], window_rectangular(8), [0]), tag='post_stall_reset')

# Long stall on a pending output: fields must stay constant (row comparison).
xs = [rng.randrange(-32768, 32768) for _ in range(16)]
run_block(xs, make_cfg(16, [coefficient(0.25), coefficient(0.375)], window_hamming(16), [0, 0]),
          stall_first=64, fuzz=True, tag='long_stall')

# Randomized soak across legal configurations.
for i in range(14):
    n = rng.choice([1, 2, 3, 5, 9, 16, 31, 48, 64])
    nb = rng.randrange(1, 5)
    freqs = [rng.randrange(0, 32769) / 65536 for _ in range(nb)]
    coeffs = [coefficient(f) for f in freqs]
    win = window_custom([rng.randrange(0, 32769) for _ in range(n)])
    thr = [rng.randrange(0, 1 << 40) for _ in range(nb)]
    xs = [rng.randrange(-32768, 32768) for _ in range(n)]
    run_block(xs, make_cfg(n, coeffs, win, thr), fuzz=(i % 3 == 0), tag=f'soak{i}')

for _ in range(10):
    tick()
# Block-end compute time: first m_valid rises last_input + 251 + 50*bins;
# subsequent bin outputs rise every 201 cycles when m_ready stays high
# (4 shared-multiplier passes + 1 output cycle); stalls only delay them.
for b in blocks:
    assert len(b['rise_cycles']) == b['bins'], b
    assert b['rise_cycles'][0] - b['last_input_cycle'] == 251 + 50 * b['bins'], b
    gaps = [c2 - c1 for c1, c2 in zip(b['rise_cycles'], b['rise_cycles'][1:])]
    assert all(g >= 201 for g in gaps), b
    if b['timed']:
        assert gaps == [201] * (b['bins'] - 1), b
fixture = '\n'.join(rows) + '\n'
(OUT / 'vectors.txt').write_text(fixture)
TB = '''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0;reg[8:0]cn=0;reg[2:0]cb=0;reg[75:0]cc=0;reg[4095:0]cw=0;reg[319:0]ct=0;reg signed[15:0]sd=0;
wire sr,cr,cd,ce,mv,ml,mdet,merr;wire[79:0]mp;wire[1:0]mb;
goertzel_bank dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),.s_tready(sr),
 .m_power(mp),.m_bin(mb),.m_last(ml),.m_detect(mdet),.m_error(merr),.m_valid(mv),.m_ready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_n(cn),.cfg_bins(cb),.cfg_coeffs(cc),.cfg_window(cw),
 .cfg_thresholds(ct),.cfg_done(cd),.cfg_error(ce));
integer f,nn,row,rr,vv,cn_,cb_,ss,rdy,esr,ecr,ecd,ece,ev,eb,el,edet,eerr;reg[75:0]cc_;reg[4095:0]cw_;reg[319:0]ct_;reg[15:0]dd;reg[79:0]ep;
initial begin f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin @(negedge clk);
  nn=$fscanf(f,"%d %d %d %d %h %h %h %d %h %d %d %d %d %d %d %h %d %d %d %d\\n",
   rr,vv,cn_,cb_,cc_,cw_,ct_,ss,dd,rdy,esr,ecr,ecd,ece,ev,ep,eb,el,edet,eerr);
  if(nn!=20)$fatal(1,"fixture row=%0d n=%0d",row,nn);
  rst_n=rr;cv=vv;cn=cn_;cb=cb_;cc=cc_;cw=cw_;ct=ct_;sv=ss;sd=dd;mr=rdy;#1;
  if({sr,cr,cd,ce,mv,ml,mdet,merr}!=={esr[0],ecr[0],ecd[0],ece[0],ev[0],el[0],edet[0],eerr[0]})
   $fatal(1,"control row=%0d got=%b expected=%b",row,{sr,cr,cd,ce,mv,ml,mdet,merr},{esr[0],ecr[0],ecd[0],ece[0],ev[0],el[0],edet[0],eerr[0]});
  if(mp!==ep||mb!==eb[1:0])$fatal(1,"data row=%0d got=%h/%0d expected=%h/%0d",row,mp,mb,ep,eb);
  @(posedge clk);#1;row=row+1;end
 $display("PASS rows=%0d",row);$finish;end
endmodule
'''
(OUT / 'tb.sv').write_text(TB)
def run(cmd, name, reject=False):
    p = subprocess.run(cmd, cwd=OUT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / name).write_text(p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(name + ': ' + p.stdout)
run([str(tool / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb', '-o', 'test.vvp', str(RTL), 'tb.sv'], 'compile.log')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'run.log')
negatives = []
# Expected-side field mutations must be caught by the checker.
for field, label, ishex in [(15, 'power', True), (14, 'valid', False), (10, 's_ready', False),
                            (11, 'cfg_ready', False), (18, 'detect', False), (16, 'bin', False),
                            (17, 'last', False), (19, 'error', False), (12, 'cfg_done', False),
                            (13, 'cfg_error', False)]:
    altered = rows.copy()
    if label in ('power', 'detect', 'bin', 'last', 'error', 'valid'):
        idx = next(i for i, r in enumerate(altered) if i > 20 and r.split()[14] == '1')
    elif label == 'cfg_done':
        idx = next(i for i, r in enumerate(altered) if r.split()[12] == '1')
    elif label == 'cfg_error':
        idx = next(i for i, r in enumerate(altered) if r.split()[13] == '1')
    else:
        idx = 40
    cells = altered[idx].split()
    cells[field] = f'{int(cells[field], 16) ^ 1:x}' if ishex else str(int(cells[field]) ^ 1)
    altered[idx] = ' '.join(cells)
    (OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
    run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'negative_' + label + '.log', reject=True)
    negatives.append(label)
(OUT / 'vectors.txt').write_text(fixture)
# Output-order mutation: swap two different bins' expected powers.
altered = rows.copy()
indices = [i for i, r in enumerate(rows) if r.split()[14] == '1' and r.split()[9] == '1']
j = next(j for j in range(len(indices) - 1)
         if rows[indices[j]].split()[15] != rows[indices[j + 1]].split()[15])
a, bb = indices[j:j + 2]; ca, cb2 = altered[a].split(), altered[bb].split()
ca[15], cb2[15] = cb2[15], ca[15]
altered[a] = ' '.join(ca); altered[bb] = ' '.join(cb2)
(OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'negative_output_order.log', reject=True)
negatives.append('output_order')
(OUT / 'vectors.txt').write_text(fixture)
# Stimulus mutation: a corrupted accepted sample must change the results.
altered = rows.copy()
idx = next(i for i, r in enumerate(rows) if i > 5 and r.split()[7] == '1' and r.split()[10] == '1')
cells = altered[idx].split(); cells[8] = f'{int(cells[8], 16) ^ 1:x}'
altered[idx] = ' '.join(cells)
(OUT / 'vectors.txt').write_text('\n'.join(altered) + '\n')
run([str(tool / 'bin/vvp.exe'), 'test.vvp'], 'negative_stimulus.log', reject=True)
negatives.append('stimulus')
(OUT / 'vectors.txt').write_text(fixture)
first_delta = sorted(set(b['rise_cycles'][0] - b['last_input_cycle'] for b in blocks))
summary = {'status': 'PASS', 'cycles': len(rows), 'blocks': len(blocks),
           'inputs_accepted': len(handshakes), 'outputs_emitted': len(emitted),
           'config_events': cfg_events, 'resets': resets, 'negative_tests': negatives,
           'block_end_cycles': {'first_output_minus_last_input': '251 + 50*bins',
                                'subsequent_bin_rise_interval': 201,
                                'measured_first_deltas': first_delta},
           'rtl_sha256': hashlib.sha256(RTL.read_bytes()).hexdigest(),
           'scope': 'cycle-level RTL simulation only; no routed timing or board acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT); print('PASS cycles', len(rows), 'blocks', len(blocks), 'emitted', len(emitted))
