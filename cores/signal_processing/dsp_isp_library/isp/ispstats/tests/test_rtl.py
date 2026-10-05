"""ISP-12 RTL regression: snapshot sources, generate independent frames and
per-frame atomic configs, run real iverilog/vvp regressions with randomized
valid fuzz, readout pacing, mutations, resets and illegal-parameter builds.
Pure stdlib.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import random
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'models'))
from reference import (Config, pack_config, pack_input, pack_record, stats,
                       widths)

HERE = pathlib.Path(__file__).resolve().parents[1]
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

QUAL_SIZES = [(1, 1), (2, 2), (7, 5), (32, 24)]
GRIDS = [(1, 1), (2, 2), (3, 2), (4, 4), (8, 8), (8, 1), (1, 8),
         (5, 7), (2, 3), (7, 8)]
PATTERNS = ['uniform', 'zeros', 'max', 'gradient', 'checker', 'vedge',
            'highlight', 'random']
TH_SEL = [0, 1, 'q', 'h', 'm']   # thresh: 0, 1, ~25%, ~50%, max


def make_frame(w, h, kind, bits, ch, r):
    mx = (1 << bits) - 1

    def px3():
        return (r.randrange(mx + 1), r.randrange(mx + 1), r.randrange(mx + 1))
    if kind == 'zeros':
        return [[(0, 0, 0) if ch == 3 else 0] * w for _ in range(h)]
    if kind == 'max':
        return [[(mx, mx, mx) if ch == 3 else mx] * w for _ in range(h)]
    if kind == 'uniform':
        v = px3() if ch == 3 else r.randrange(mx + 1)
        return [[v] * w for _ in range(h)]
    if kind == 'gradient':
        if ch == 3:
            return [[((x * 3 + y * 2) & mx, (x + y * 5) & mx, (x * 7 + y) & mx)
                     for x in range(w)] for y in range(h)]
        return [[(x * 3 + y * 5) & mx for x in range(w)] for y in range(h)]
    if kind == 'vedge':
        hi = (mx, mx // 2, mx // 3) if ch == 3 else mx
        lo = (0, 0, 0) if ch == 3 else 0
        return [[lo if x < w // 2 else hi for x in range(w)] for y in range(h)]
    if kind == 'highlight':
        lo = (mx // 4, mx // 4, mx // 4) if ch == 3 else mx // 4
        hi = (mx, mx, mx) if ch == 3 else mx
        f = [[lo] * w for _ in range(h)]
        for yy in range(h // 4, (3 * h) // 4):
            for xx in range(w // 4, (3 * w) // 4):
                f[yy][xx] = hi
        return f
    if kind == 'checker':
        if ch == 3:
            v = px3()
            return [[v if (x + y) % 2 else (0, 0, 0) for x in range(w)]
                    for y in range(h)]
        v = r.randrange(1, mx + 1)
        return [[(x + y) % 2 * v for x in range(w)] for y in range(h)]
    if ch == 3:
        return [[px3() for _ in range(w)] for _ in range(h)]
    return [[r.randrange(mx + 1) for _ in range(w)] for _ in range(h)]


def thresh_of(sel, bits, r):
    mx = (1 << bits) - 1
    return {'q': mx // 4, 'h': mx // 2, 'm': mx}.get(sel, sel)


def build_case(bits, ch, maxw, maxh, seed):
    """Frames: every qualification size that fits, spread of grids/patterns/
    thresholds plus directed extremes."""
    r = random.Random(seed)
    mx = (1 << bits) - 1
    sizes = [s for s in QUAL_SIZES if s[0] <= maxw and s[1] <= maxh]
    if maxw > 40 and maxh > 30:
        sizes += [(40, 30), (33, 17)]
    grids = [g for g in GRIDS if g[0] <= 8 and g[1] <= 8]
    plans = []
    for w, h in sizes:
        legal = [g for g in grids if g[0] <= w and g[1] <= h]
        picks = []
        for i, kind in enumerate(PATTERNS):
            picks.append((kind, legal[(i + w + h) % len(legal)],
                          TH_SEL[(i + w * h) % len(TH_SEL)]))
        # Directed extras: densest legal grid, full-clip, edge metric.
        picks.append(('random', legal[-1], 'h'))
        picks.append(('max', legal[0], 0))          # every pixel overexposed
        picks.append(('vedge', legal[-1], 'm'))
        picks.append(('uniform', legal[-1], 1))
        for kind, (zxn, zyn), th in picks:
            plans.append((w, h, zxn, zyn, thresh_of(th, bits, r), kind))
    inputs, expected, configs, sched, rsched = [], [], [], [0], [0]
    wds = widths(bits, ch, maxw, maxh)
    for w, h, zxn, zyn, th, kind in plans:
        cfg = Config(w, h, zxn, zyn, th, bits=bits, ch=ch,
                     max_w=maxw, max_h=maxh)
        configs.append(pack_config(cfg, wds['cwx'], wds['cwy']))
        f = make_frame(w, h, kind, bits, ch, r)
        recs = stats(f, cfg)
        assert len(recs) == zxn * zyn
        for y in range(h):
            for x in range(w):
                inputs.append(pack_input(f[y][x], int(x == 0 and y == 0),
                                         int(x == w - 1), bits, ch))
        sched.append(len(inputs))
        for rec in recs:
            expected.append(pack_record(rec, wds))
        rsched.append(len(expected))
    return inputs, expected, configs, sched, rsched


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path)
    a = p.parse_args()
    out = a.output or HERE / 'evidence' / ('sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = list((HERE / 'rtl').glob('*.sv')) + [HERE / 'tests' / 'tb_ispstats.sv',
                                               HERE / 'models' / 'reference.py',
                                               HERE / 'models' / 'ae_analysis.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in files}, indent=2))
    src = src.resolve()
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = str(cad / 'lib') + os.pathsep + str(cad / 'bin') + os.pathsep + env['PATH']
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    assert iv and vv, 'iverilog/vvp not found under oss-cad-suite'
    results = []
    # (BITS, CH, MAXW, MAXH)
    cases = [(8, 3, 32, 24), (8, 1, 32, 24), (10, 3, 64, 64),
             (10, 1, 8, 8), (8, 3, 4, 4)]
    for bits, ch, maxw, maxh in cases:
        case = out / f'b{bits}_c{ch}_w{maxw}_h{maxh}'
        case.mkdir()
        inputs, expected, configs, sched, rsched = build_case(
            bits, ch, maxw, maxh, 910 + bits + ch + maxw)
        nf, nt, nr = len(configs), len(inputs), len(expected)
        for name, data in [('input', inputs), ('expected', expected),
                           ('config', configs), ('sched', sched),
                           ('rsched', rsched)]:
            (case / (name + '.mem')).write_text(''.join(f'{v:x}\n' for v in data))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_ispstats', '-o', 'sim.vvp',
               f'-Ptb_ispstats.BITS={bits}', f'-Ptb_ispstats.CH={ch}',
               f'-Ptb_ispstats.MAXW={maxw}', f'-Ptb_ispstats.MAXH={maxh}',
               f'-Ptb_ispstats.NF={nf}', f'-Ptb_ispstats.NT={nt}',
               f'-Ptb_ispstats.NR={nr}',
               str(src / 'ispstats_stream.sv'), str(src / 'tb_ispstats.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env, capture_output=True,
                               text=True, timeout=600)
            (case / (label + '.log')).write_text(
                '$ ' + ' '.join(command) + '\n' + r.stdout + r.stderr)
            assert r.returncode == 0, (case, r.stdout, r.stderr)
        assert 'PASS ispstats' in r.stdout, (case, r.stdout)
        for mutation in ('data', 'sideband', 'count', 'order'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case, env=env,
                               capture_output=True, text=True, timeout=600)
            (case / ('negative_' + mutation + '.log')).write_text(r.stdout + r.stderr)
            assert r.returncode != 0 and 'mismatch' in r.stdout, (
                case, mutation, r.stdout)
        results.append(dict(bits=bits, ch=ch, max_w=maxw, max_h=maxh,
                            frames=nf, inputs=nt, records=nr, status='PASS',
                            checker_negatives=4))
        print('PASS', case.name, f'frames={nf} inputs={nt} records={nr}', flush=True)
    invalid = [('BITS', '9'), ('CH', '2'), ('MAX_W', '0'), ('MAX_H', '0'),
               ('MAX_W', '2048'), ('MAX_W', '300')]
    for param, value in invalid:
        case = out / f'invalid_{param}_{value}'
        case.mkdir()
        if param == 'MAX_W' and value == '300':
            sets = '.MAX_W(300),.MAX_H(300)'     # frame bound 90000 > 65536
        else:
            sets = f'.{param}({value})'
        (case / 'tb.sv').write_text(
            f'module tb; ispstats_stream #({sets}) dut(); '
            'initial #1 $finish; endmodule\n')
        cp = subprocess.run(
            [iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
             str(src / 'ispstats_stream.sv'), 'tb.sv'], cwd=case, env=env,
            capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=case, env=env,
                            capture_output=True, text=True)
        (case / 'run.log').write_text(cp.stdout + cp.stderr + rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout, rp.stdout
    (out / 'summary.json').write_text(json.dumps(dict(
        status='PASS', cases=results, illegal_static_parameters=6,
        scope='RTL simulation; no P&R/board claim'), indent=2))
    print(out)


if __name__ == '__main__':
    main()
