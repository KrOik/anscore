"""Deterministic dual-clock verification for async_stream_fifo /
stream_cdc_handshake using Icarus Verilog (-g2012 -Wall).

Method: stimulus is generated on an integer time grid while a bit-exact
register-level model reproduces every expected output cycle-for-cycle
(models/model.py). The generated testbench drives each domain on its own
clock and records per-edge traces; a transaction-order oracle independently
checks data integrity, ordering and capacity. Mutation fixtures prove the
checker rejects data, order, count, ready/level and stall corruption.

All clock half-periods are odd integers: a stimulus/reset change on domain
X negedges (even multiples of half_X) can never coincide with a posedge of
domain Y (odd multiple of half_Y), so synchronizer sampling is unambiguous.

Run:  python tests/test_asyncfifo.py [--out DIR]
"""
import argparse, copy, datetime, hashlib, json, os, pathlib, random, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[3]
CAD = REPO / 'tools/oss-cad-suite/oss-cad-suite'
sys.path.insert(0, str(ROOT / 'models'))
from model import AsyncFifoModel, HandshakeModel, QueueOracle  # noqa: E402


def tools(name):
    local = CAD / 'bin' / f'{name}.exe'
    return str(local) if local.exists() else shutil.which(name) or name


def env():
    e = os.environ.copy()
    e['PATH'] = str(CAD / 'bin') + os.pathsep + str(CAD / 'lib') + os.pathsep + e['PATH']
    return e


# ---------------------------------------------------------------- stimulus

class ResetPlan:
    """Reset windows in ns, per domain, from (t0, mode) events."""

    def __init__(self, events, s_per, m_per):
        self.events = events
        self.w = []   # windows where s_rst_n = 0: (t0, t1)
        self.m = []
        for t0, mode in events:
            if mode in ('coord', 's'):
                self.w.append((t0, t0 + 3 * s_per))
            if mode in ('coord', 'm'):
                self.m.append((t0, t0 + 3 * m_per))
        ends = [b for _, b in self.w] + [b for _, b in self.m]
        self.last_reset_end = max(ends) if ends else 0
        self.span = max(s_per, m_per)
        # quarantine: peer-detect sync + clamp + resync margin
        self.TQ = 6 * max(s_per, m_per)

    def rst(self, domain, t):
        wins = self.w if domain == 's' else self.m
        return 0 if any(t0 <= t <= t1 for t0, t1 in wins) else 1


class GenS:
    """Write-domain stimulus: held-beat source (stable while !tready)."""

    def __init__(self, rng, width, plan, s_per, t_fill, t_tail, t_pre=None):
        self.rng, self.width, self.plan = rng, width, plan
        self.s_per, self.t_fill, self.t_tail = s_per, t_fill, t_tail
        self.t_pre = t_pre
        self.held = None

    def blanked(self, t):
        # Negedge times: cover the whole reset window plus quarantine horizon.
        # The reset window lasts 3 * asserting-domain period, so use the max
        # period; last reset posedge <= t0+3*span+max(halves), q_until adds TQ.
        for t0, _ in self.plan.events:
            if t0 - 2 * self.s_per <= t <= t0 + 5 * self.plan.span + \
                    self.plan.TQ:
                return True
        return False

    def next(self, t):
        rst = self.plan.rst('s', t)
        v, d = 0, 0
        if rst and not self.blanked(t):
            if self.held is None:
                if t > self.t_tail:
                    p = 0.0
                elif (t < self.t_fill or
                      (self.t_pre is not None and self.t_pre <= t)):
                    p = 1.0
                else:
                    p = 0.62
                if self.rng.random() < p:
                    self.held = self.rng.getrandbits(self.width)
            if self.held is not None:
                v, d = 1, self.held
        return rst, v, d

    def after_edge(self, push):
        if push:
            self.held = None


class GenM:
    """Read-domain stimulus: free-running ready with early stall and drain."""

    def __init__(self, rng, plan, t_stall, t_drain, t_pre=None):
        self.rng, self.plan = rng, plan
        self.t_stall, self.t_drain, self.t_pre = t_stall, t_drain, t_pre

    def next(self, t):
        rst = self.plan.rst('m', t)
        ready = 1
        if (t < self.t_stall or self.rng.random() < 0.35 or
                (self.t_pre is not None and self.t_pre <= t < self.t_drain)):
            ready = 0
        if t > self.t_drain:
            ready = 1
        return rst, ready


# ------------------------------------------------------- unified simulation

def run_sim(make_model, n_s, n_m, s_h, m_h, src_s, src_m, hook=None):
    """One pass over the merged event grid. src_*(t)->stim is called at each
    domain negedge; model edges evaluate at each posedge and commit once per
    timestamp (NBA semantics). Returns (wstim, rstim, s_rows, m_rows, model).
    The first s_clk/m_clk posedge is the testbench's priming reset edge."""
    model = make_model()
    model.s_edge(0, 0, 0)
    model.m_edge(0, 0)
    model.commit()
    wstim, rstim = [None] * n_s, [None] * n_m
    s_rows, m_rows = [None] * n_s, [None] * n_m
    cur = dict(s_rst=0, s_v=0, s_d=0, m_rst=0, m_r=0)
    evs = []
    for i in range(n_s):
        evs.append(((2 * i + 2) * s_h, 0, 'ws', i))
        evs.append(((2 * i + 3) * s_h, 1, 'wp', i))
    for i in range(n_m):
        evs.append(((2 * i + 2) * m_h, 0, 'ms', i))
        evs.append(((2 * i + 3) * m_h, 1, 'mp', i))
    evs.sort()
    k = 0
    while k < len(evs):
        j = k
        while j < len(evs) and evs[j][0] == evs[k][0]:
            j += 1
        for t, _, kind, i in evs[k:j]:
            if kind == 'ws':
                cur['s_rst'], cur['s_v'], cur['s_d'] = wstim[i] = src_s(t)
            elif kind == 'ms':
                cur['m_rst'], cur['m_r'] = rstim[i] = src_m(t)
        for t, _, kind, i in evs[k:j]:
            if kind == 'wp':
                s_rows[i] = model.s_edge(cur['s_rst'], cur['s_v'], cur['s_d'])
                if hook:
                    hook('s', s_rows[i])
            elif kind == 'mp':
                m_rows[i] = model.m_edge(cur['m_rst'], cur['m_r'])
                if hook:
                    hook('m', m_rows[i])
        model.commit()
        k = j
    return wstim, rstim, s_rows, m_rows, model


# ------------------------------------------------------------------ checker

def xint(tok):
    return None if set(tok.lower()) & set('xz') else int(tok, 16)


def parse_rows(path):
    rows = []
    for line in path.read_text().splitlines():
        f = line.split()
        assert len(f) == 6, (path, line)
        rows.append(dict(t=int(f[0]), rst=int(f[1]), v=int(f[2]), r=int(f[3]),
                         data=xint(f[4]), level=int(f[5])))
    return rows


def verify(tag, model_factory, capacity, s_h, m_h, wstim, rstim, wrows, mrows,
           TQ):
    """Replay the model from stimulus; check both traces bit-exactly and run
    the independent queue oracle including reset quarantine semantics."""
    ws_iter, ms_iter = iter(wstim), iter(rstim)
    _, _, s_exp, m_exp, _ = run_sim(model_factory, len(wstim), len(rstim),
                                  s_h, m_h, lambda t: next(ws_iter),
                                  lambda t: next(ms_iter))
    pops, pushes = [], []
    fifo = len(s_exp[0]) == 3
    for i, (row, exp) in enumerate(zip(wrows, s_exp)):
        if fifo:
            sr, push, level = exp
            assert row['level'] == level, (tag, i, 's_level', row, exp)
        else:
            sr, push = exp
        assert row['t'] == (2 * i + 3) * s_h, (tag, i, 'wtime')
        assert row['r'] == sr, (tag, i, 's_tready', row, exp)
        assert (row['v'] & row['r'] & row['rst']) == push, (tag, i, 'push')
        if push:
            pushes.append((row['t'], 0, row['data']))
    for i, (row, exp) in enumerate(zip(mrows, m_exp)):
        if fifo:
            mv, md, pop, level = exp
            assert row['level'] == level, (tag, i, 'm_level', row, exp)
        else:
            mv, md, pop = exp
        assert row['t'] == (2 * i + 3) * m_h, (tag, i, 'mtime')
        assert row['v'] == mv, (tag, i, 'm_tvalid', row, exp)
        if mv:
            assert row['data'] == md, (tag, i, 'm_tdata', row, exp)
        assert (row['v'] & row['r'] & row['rst']) == pop, (tag, i, 'pop')
        if pop:
            pops.append((row['t'], 1, row['data']))

    # Oracle over emitted transactions; pops sort before pushes at equal time.
    # Pushes accepted inside a quarantine window (peer-detect window) are
    # clamped before they can be delivered: relaxed-capacity, always discarded.
    oracle = QueueOracle(capacity)
    resets = sorted([r['t'] for r in wrows if not r['rst']] +
                    [r['t'] for r in mrows if not r['rst']])
    assert resets, tag + ': no reset observed'
    q_until = -1
    cleared = True
    ri = 0
    for t, is_pop, data in sorted(pops + pushes, key=lambda e: (e[0], -e[1])):
        while ri < len(resets) and resets[ri] <= t:
            q_until = max(q_until, resets[ri] + TQ)
            cleared = False
            ri += 1
        if not cleared and t > q_until:
            oracle.reset_discard()
            cleared = True
        if is_pop:
            oracle.pop(data)
        else:
            oracle.push(data, relaxed=not cleared)
    for rt in resets[ri:]:
        q_until = max(q_until, rt + TQ)
    oracle.reset_discard()
    oracle.finish()

    # Stalled-output stability (skip pairs inside a reset quarantine: the
    # peer-reset clamp may legitimately drop m_tvalid there).
    for a, b in zip(mrows, mrows[1:]):
        if a['v'] and not a['r'] and b['rst'] and a['rst']:
            if any(rt <= b['t'] and a['t'] <= rt + TQ for rt in resets):
                continue
            assert b['v'] and b['data'] == a['data'], \
                (tag, 'stalled output changed', a, b)

    stats = dict(accepted=oracle.accepted, emitted=oracle.emitted,
                 discarded=oracle.discarded,
                 resets=len(resets),
                 full_seen=(fifo and any(e[2] == capacity - 1 for e in s_exp)),
                 push_runs=_max_run([e[1] for e in s_exp]),
                 pop_runs=_max_run([e[2] for e in m_exp]))
    return stats


def _max_run(bits):
    best = cur = 0
    for b in bits:
        cur = cur + 1 if b else 0
        best = max(best, cur)
    return best


# --------------------------------------------------------------- testbench

TB = '''`timescale 1ns/1ps
module tb;
localparam W={width}, D={depth};
localparam integer S_HALF={s_h}, M_HALF={m_h};
reg s_clk=0, m_clk=0;
always #S_HALF s_clk=~s_clk;
always #M_HALF m_clk=~m_clk;
reg s_rst_n=0, s_tvalid=0, m_rst_n=0, m_tready=0;
reg [W-1:0] s_tdata=0;
wire s_tready, m_tvalid;
wire [W-1:0] m_tdata;
{level_decl}
{dut}
integer wfi, wfo, wrc, wrst, wv, wi;
integer mfi, mfo, mrc, mrst, mr, mi;
reg [W-1:0] wdata;
initial begin
  wfi=$fopen("wstim.txt","r"); wfo=$fopen("wtrace.txt","w");
  @(posedge s_clk); #1;
  for(wi=0;wi<{n_s};wi=wi+1) begin
    @(negedge s_clk);
    wrc=$fscanf(wfi,"%d %d %h\\n",wrst,wv,wdata);
    if(wrc!=3) $fatal(1,"bad wstim");
    s_rst_n=wrst[0]; s_tvalid=wv[0]; s_tdata=wdata;
    @(posedge s_clk);
    $fwrite(wfo,"%0d %d %d %d %h %0d\\n",
            $time,s_rst_n,s_tvalid,s_tready,s_tdata,s_level);
  end
  $fclose(wfo);
end
initial begin
  mfi=$fopen("rstim.txt","r"); mfo=$fopen("rtrace.txt","w");
  @(posedge m_clk); #1;
  for(mi=0;mi<{n_m};mi=mi+1) begin
    @(negedge m_clk);
    mrc=$fscanf(mfi,"%d %d\\n",mrst,mr);
    if(mrc!=2) $fatal(1,"bad rstim");
    m_rst_n=mrst[0]; m_tready=mr[0];
    @(posedge m_clk);
    $fwrite(mfo,"%0d %d %d %d %h %0d\\n",
            $time,m_rst_n,m_tvalid,m_tready,m_tdata,m_level);
  end
  $fclose(mfo);
  $display("TRACE COMPLETE");
  $finish;
end
endmodule
'''


def make_tb(width, depth, s_h, m_h, n_s, n_m, module):
    if module == 'async_stream_fifo':
        decl = ('wire [$clog2(D)+1:0] s_level;\n'
                'wire [$clog2(D)+1:0] m_level;')
        dut = ('async_stream_fifo #(.WIDTH(W),.DEPTH(D)) dut(\n'
               '  .s_clk(s_clk),.s_rst_n(s_rst_n),.s_tdata(s_tdata),\n'
               '  .s_tvalid(s_tvalid),.s_tready(s_tready),\n'
               '  .m_clk(m_clk),.m_rst_n(m_rst_n),.m_tdata(m_tdata),\n'
               '  .m_tvalid(m_tvalid),.m_tready(m_tready),\n'
               '  .s_level(s_level),.m_level(m_level));')
    else:
        decl = ('wire [0:0] s_level; assign s_level=1\'b0;\n'
                'wire [0:0] m_level; assign m_level=1\'b0;')
        dut = ('stream_cdc_handshake #(.WIDTH(W)) dut(\n'
               '  .s_clk(s_clk),.s_rst_n(s_rst_n),.s_tdata(s_tdata),\n'
               '  .s_tvalid(s_tvalid),.s_tready(s_tready),\n'
               '  .m_clk(m_clk),.m_rst_n(m_rst_n),.m_tdata(m_tdata),\n'
               '  .m_tvalid(m_tvalid),.m_tready(m_tready));')
    return TB.format(width=width, depth=max(depth, 2), s_h=s_h, m_h=m_h,
                     n_s=n_s, n_m=n_m, level_decl=decl, dut=dut)


def run_case(out, module, depth, width, s_h, m_h, seed, n=900):
    tag = f'{module}_d{depth}_w{width}_sh{s_h}_mh{m_h}_s{seed}'
    work = out / tag
    work.mkdir()
    s_per, m_per = 2 * s_h, 2 * m_h
    T = n * max(s_per, m_per)
    rng = random.Random(seed)
    span = max(s_per, m_per)
    t_fill = (depth + 6) * s_per
    t_stall = t_fill + 4 * m_per
    # reset events: the first lands while the FIFO provably holds beats (reader
    # still stalled after the fill burst); the rest are mid-stream
    # asymmetric/coordinated resets.
    events = [(t_fill + span, 's'), (int(T * 0.48), 'm'),
              (int(T * 0.66), 'coord'), (int(T * 0.82), 'coord')]
    plan = ResetPlan(events, s_per, m_per)
    t_tail = T - (depth + 8) * m_per - 4 * span
    t_pre = int(T * 0.88)   # pre-drain stall+fill: guaranteed deep queue
    t_drain = t_tail
    n_s = int(T // s_per) - 3
    n_m = int(T // m_per) - 3
    gen_s = GenS(rng, width, plan, s_per, t_fill, t_tail, t_pre)
    gen_m = GenM(rng, plan, t_stall, t_drain, t_pre)

    def hook(dom, row):
        if dom == 's':
            gen_s.after_edge(row[1])

    factory = (lambda: AsyncFifoModel(depth)) if module == 'async_stream_fifo' \
        else HandshakeModel
    wstim, rstim, s_exp, m_exp, _ = run_sim(
        factory, n_s, n_m, s_h, m_h, gen_s.next, gen_m.next, hook)

    (work / 'wstim.txt').write_text(
        ''.join(f'{r} {v} {d:x}\n' for r, v, d in wstim))
    (work / 'rstim.txt').write_text(''.join(f'{r} {m}\n' for r, m in rstim))
    (work / 'tb.sv').write_text(make_tb(width, depth, s_h, m_h, n_s, n_m,
                                       module))
    src = ROOT / 'rtl' / f'{module}.sv'
    logs = []
    for cmd in ([tools('iverilog'), '-g2012', '-Wall', '-s', 'tb', '-o',
                 'sim.vvp', str(src), 'tb.sv'],
                [tools('vvp'), 'sim.vvp']):
        proc = subprocess.run(cmd, cwd=work, env=env(), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        logs.append('$ ' + ' '.join(cmd) + '\n' + proc.stdout)
        (work / 'run.log').write_text('\n'.join(logs))
        assert proc.returncode == 0, logs[-1]
    assert 'TRACE COMPLETE' in logs[-1], logs[-1]

    wrows, mrows = parse_rows(work / 'wtrace.txt'), parse_rows(work / 'rtrace.txt')
    # fifo: DEPTH RAM + 1 output slot; handshake: 1 slot + 1 in-flight beat.
    capacity = depth + 1 if module == 'async_stream_fifo' else 2
    stats = verify(tag, factory, capacity, s_h, m_h,
                   list(wstim), list(rstim), wrows, mrows, plan.TQ)

    # Feature assertions: full/empty boundary, II=1, reset-during-transfer.
    # For the FIFO the first reset lands on a provably deep queue, so discards
    # are mandatory; the handshake may legitimately emit its in-flight beat
    # before the peer clamp lands (delivery wins the detect-window race), so
    # only recovery is asserted there.
    assert stats['emitted'] > 0
    if module == 'async_stream_fifo':
        assert stats['discarded'] > 0, (tag, 'reset never discarded beats')
        assert stats['full_seen'], (tag, 'full boundary never reached')
        assert stats['push_runs'] >= min(depth, 8), (tag, 'write II=1 violated')
        assert stats['pop_runs'] >= min(depth, 8), (tag, 'read II=1 violated')
    else:
        assert stats['resets'] >= 4, (tag, 'no reset activity')

    # Mutation fixtures: the checker must reject every corruption.
    negative = []
    emit_idx = [i for i, r in enumerate(mrows)
                if (r['v'] & r['r'] & r['rst'])]
    stall_idx = next(i for i, r in enumerate(mrows[:-1])
                     if r['v'] and not r['r'] and mrows[i + 1]['v'])
    # 'order': swap two emitted beats with distinct values so the swap is a
    # real corruption even at WIDTH=1.
    swap_i = None
    for a in range(len(emit_idx)):
        j = next((b for b in range(a + 1, len(emit_idx))
                  if mrows[emit_idx[b]]['data'] != mrows[emit_idx[a]]['data']),
                 None)
        if j is not None:
            swap_i = (emit_idx[a], emit_idx[j])
            break
    muts = {
        'data': ('m', emit_idx[len(emit_idx) // 2], 'data_xor'),
        'order': ('m', swap_i, 'swap_pair'),
        'count': ('m', emit_idx[len(emit_idx) // 3], 'clear_valid'),
        'ready': ('s', next(i for i, r in enumerate(wrows)
                            if r['r'] and r['rst']), 'flip_ready'),
        'stability': ('m', stall_idx, 'stall_data'),
    }
    for name, (dom, idx, how) in muts.items():
        if idx is None:
            raise AssertionError(f'{tag}: no fixture for {name}')
        wm, mm = copy.deepcopy(wrows), copy.deepcopy(mrows)
        if how == 'swap_pair':
            i0, i1 = idx
            mm[i0]['data'], mm[i1]['data'] = mm[i1]['data'], mm[i0]['data']
            tgt = mm[i0]
        else:
            tgt = (mm if dom == 'm' else wm)[idx]
        if how == 'data_xor':
            tgt['data'] ^= 1
        elif how == 'clear_valid':
            tgt['v'] = 0
        elif how == 'flip_ready':
            tgt['r'] ^= 1
        elif how == 'stall_data':
            tgt['data'] = (tgt['data'] or 0) ^ 1
        try:
            verify(tag, factory, capacity, s_h, m_h, list(wstim), list(rstim),
                   wm, mm, plan.TQ)
        except (AssertionError, Exception):
            negative.append(name)
        else:
            raise AssertionError(f'{tag}: checker accepted {name} corruption')
    stats.update(case=tag, negative_checks=sorted(negative), status='PASS')
    return stats


def invalid_param_cases(out):
    results = []
    for module, param, val in [('async_stream_fifo', 'WIDTH', 0),
                               ('async_stream_fifo', 'DEPTH', 1),
                               ('async_stream_fifo', 'DEPTH', 3),
                               ('async_stream_fifo', 'DEPTH', 6),
                               ('stream_cdc_handshake', 'WIDTH', 0)]:
        tag = f'invalid_{module}_{param}{val}'
        work = out / tag
        work.mkdir()
        (work / 'tb.sv').write_text(
            f'module tb; {module} #(.{param}({val})) dut(); '
            'initial #1 $finish; endmodule\n')
        src = ROOT / 'rtl' / f'{module}.sv'
        cp = subprocess.run([tools('iverilog'), '-g2012', '-Wall', '-s', 'tb',
                             '-o', 'sim.vvp', str(src), 'tb.sv'],
                            cwd=work, env=env(), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert cp.returncode == 0, cp.stdout
        rp = subprocess.run([tools('vvp'), 'sim.vvp'], cwd=work, env=env(),
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
        (work / 'run.log').write_text(cp.stdout + rp.stdout)
        assert rp.returncode != 0 and 'invalid' in rp.stdout.lower(), \
            f'illegal parameter was not rejected: {tag}'
        results.append(f'{module}.{param}={val} rejected')
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', type=pathlib.Path)
    ap.add_argument('--quick', action='store_true')
    a = ap.parse_args()
    out = a.out or ROOT / 'evidence' / datetime.datetime.now().strftime(
        '%Y%m%d_%H%M%S_%f')
    out.mkdir(parents=True, exist_ok=False)
    results = []
    fifo_cases = [
        # (depth, width, s_half, m_half, seed): fast/slow writer+reader, equal
        (16, 16, 5, 7, 0xA51), (16, 16, 7, 5, 0xA52),
        (16, 8, 5, 11, 0xA53), (16, 32, 11, 5, 0xA54),
        (8, 16, 5, 5, 0xA55), (8, 16, 9, 5, 0xA56),
        (4, 1, 7, 9, 0xA57), (4, 8, 9, 7, 0xA58),
        (2, 16, 5, 7, 0xA59), (32, 16, 13, 5, 0xA5A),
    ]
    hs_cases = [(2, 16, 5, 7, 0xB51), (2, 8, 7, 5, 0xB52),
                (2, 1, 5, 5, 0xB53)]
    for depth, width, s_h, m_h, seed in fifo_cases:
        r = run_case(out, 'async_stream_fifo', depth, width, s_h, m_h, seed,
                     n=400 if a.quick else 900)
        results.append(r)
        print(r['case'], 'PASS', r)
    for depth, width, s_h, m_h, seed in hs_cases:
        r = run_case(out, 'stream_cdc_handshake', depth, width, s_h, m_h, seed,
                     n=300 if a.quick else 500)
        results.append(r)
        print(r['case'], 'PASS', r)
    illegal = invalid_param_cases(out)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
              for d in ('rtl', 'models', 'tests')
              for p in (ROOT / d).iterdir() if p.suffix in ('.sv', '.py')}
    summary = dict(status='PASS', cases=results, illegal_parameters=illegal,
                   source_sha256=hashes,
                   scope='RTL simulation only; CDC structure reviewed, '
                         'metastability/P&R/board NOT verified',
                   synthesis='NOT RUN', board='NOT RUN')
    (out / 'summary.json').write_text(json.dumps(summary, indent=2))
    print('PASS', len(results), 'cases;', out)


if __name__ == '__main__':
    main()
