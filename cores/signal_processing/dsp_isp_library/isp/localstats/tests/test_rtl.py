"""ISP-10 RTL regression: snapshot sources, generate independent frames and
per-frame atomic configs, run real iverilog/vvp regressions with randomized
handshake, mutations, resets and illegal-parameter builds. Pure stdlib.
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
from reference import Config, pack_config, pack_expected, pack_input, stats, widths_full

HERE = pathlib.Path(__file__).resolve().parents[1]
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

QUAL_SIZES = [(1, 1), (2, 2), (7, 5), (32, 24)]
WINDOWS = [(1, 1), (3, 3), (5, 5), (15, 15), (15, 3), (7, 9), (2, 2)]
C_VALUES = [0, -1, 25, -64, 127, -128]
PATTERNS = ['uniform', 'zeros', 'max', 'gradient', 'checker', 'random']


def make_frame(w, h, kind, bits, r):
    mx = (1 << bits) - 1
    if kind == 'uniform':
        v = r.randrange(mx + 1)
        return [[v] * w for _ in range(h)]
    if kind == 'zeros':
        return [[0] * w for _ in range(h)]
    if kind == 'max':
        return [[mx] * w for _ in range(h)]
    if kind == 'gradient':
        return [[(x * 3 + y * 5) & mx for x in range(w)] for y in range(h)]
    if kind == 'checker':
        v = r.randrange(1, mx + 1)
        return [[(x + y) % 2 * v for x in range(w)] for y in range(h)]
    return [[r.randrange(mx + 1) for _ in range(w)] for _ in range(h)]


def build_case(bits, maxw, maxh, wwm, whm, seed):
    """Pick frames: every qualification size that fits, several windows/C."""
    r = random.Random(seed)
    sizes = [s for s in QUAL_SIZES if s[0] <= maxw and s[1] <= maxh]
    if maxw > 40 and maxh > 30:
        sizes += [(40, 30), (33, 17)]
    wins = [v for v in WINDOWS if v[0] <= wwm and v[1] <= whm]
    plans = []
    for w, h in sizes:
        # Deterministic spread of pattern/window/C combos per size.
        picks = []
        for i, kind in enumerate(PATTERNS):
            picks.append((kind, wins[(i + w + h) % len(wins)],
                          C_VALUES[(i + w * h) % len(C_VALUES)]))
        # Always include the extreme window and a couple of extras.
        picks.append(('random', (wwm, whm), 0))
        picks.append(('max', wins[-1], -128))
        picks.append(('zeros', wins[0], 127))
        for kind, (ww, wh), c in picks:
            plans.append((w, h, ww, wh, c, kind))
    inputs, expected, configs, sched = [], [], [], [0]
    for w, h, ww, wh, c, kind in plans:
        cfg = Config(w, h, ww, wh, c, max_w=maxw, max_h=maxh)
        configs.append(pack_config(cfg, widths_full(bits, maxw, maxh)['cwx'],
                                   widths_full(bits, maxw, maxh)['cwy']))
        f = make_frame(w, h, kind, bits, r)
        recs = stats(f, cfg, bits)
        assert len(recs) == w * h
        for rec in recs:
            rec['sof'] = int(rec['x'] == 0 and rec['y'] == 0)
            rec['eol'] = int(rec['x'] == w - 1)
            inputs.append(pack_input(rec['pixel'], rec['sof'], rec['eol'], bits))
            expected.append(rec)
        sched.append(len(inputs))
    wds = widths_full(bits, maxw, maxh, wwm, whm)
    expected = [pack_expected(rec, wds) for rec in expected]
    return inputs, expected, configs, sched


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path)
    a = p.parse_args()
    out = a.output or HERE / 'evidence' / ('sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = list((HERE / 'rtl').glob('*.sv')) + [HERE / 'tests' / 'tb_localstats.sv',
                                               HERE / 'models' / 'reference.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in files}, indent=2))
    src = src.resolve()
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = str(cad / 'bin') + os.pathsep + str(cad / 'lib') + os.pathsep + env['PATH']
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    results = []
    # (BITS, MAXW, MAXH, WIN_W_MAX, WIN_H_MAX)
    cases = [(8, 32, 24, 15, 15), (10, 32, 24, 15, 15),
             (10, 64, 64, 7, 5), (8, 4, 4, 3, 3)]
    for bits, maxw, maxh, wwm, whm in cases:
        case = out / f'b{bits}_w{maxw}_h{maxh}_ww{wwm}_wh{whm}'
        case.mkdir()
        inputs, expected, configs, sched = build_case(
            bits, maxw, maxh, wwm, whm, 910 + bits + maxw + wwm)
        nf, nt = len(configs), len(inputs)
        for name, data in [('input', inputs), ('expected', expected),
                           ('config', configs), ('sched', sched)]:
            (case / (name + '.mem')).write_text(''.join(f'{v:x}\n' for v in data))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_localstats', '-o', 'sim.vvp',
               f'-Ptb_localstats.BITS={bits}', f'-Ptb_localstats.MAXW={maxw}',
               f'-Ptb_localstats.MAXH={maxh}', f'-Ptb_localstats.WWM={wwm}',
               f'-Ptb_localstats.WHM={whm}', f'-Ptb_localstats.NF={nf}',
               f'-Ptb_localstats.NT={nt}',
               str(src / 'adaptive_threshold.sv'), str(src / 'integral_stats.sv'),
               str(src / 'tb_localstats.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env, capture_output=True,
                               text=True, timeout=600)
            (case / (label + '.log')).write_text(
                '$ ' + ' '.join(command) + '\n' + r.stdout + r.stderr)
            assert r.returncode == 0, (case, r.stdout, r.stderr)
        assert 'PASS localstats' in r.stdout, (case, r.stdout)
        for mutation in ('data', 'sideband', 'count', 'order'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case, env=env,
                               capture_output=True, text=True, timeout=600)
            (case / ('negative_' + mutation + '.log')).write_text(r.stdout + r.stderr)
            assert r.returncode != 0 and (
                'localstats mismatch' in r.stdout
                or mutation == 'count' and 'count timeout' in r.stdout), (
                case, mutation, r.stdout)
        results.append(dict(bits=bits, max_w=maxw, max_h=maxh,
                            win_w_max=wwm, win_h_max=whm,
                            frames=nf, outputs=nt, status='PASS',
                            checker_negatives=4))
        print('PASS', case.name, f'frames={nf} outputs={nt}', flush=True)
    for param, value in [('BITS', 9), ('MAX_W', 0), ('MAX_H', 0),
                         ('WIN_W_MAX', 16), ('WIN_H_MAX', 16),
                         ('MAX_W', 4096)]:
        case = out / f'invalid_{param}_{value}'
        case.mkdir()
        (case / 'tb.sv').write_text(
            f'module tb; integral_stats #(.{param}({value})) dut(); '
            'initial #1 $finish; endmodule\n')
        cp = subprocess.run(
            [iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
             str(src / 'adaptive_threshold.sv'), str(src / 'integral_stats.sv'),
             'tb.sv'], cwd=case, env=env, capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=case, env=env,
                            capture_output=True, text=True)
        (case / 'run.log').write_text(cp.stdout + cp.stderr + rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout
    (out / 'summary.json').write_text(json.dumps(dict(
        status='PASS', cases=results, illegal_static_parameters=6,
        scope='RTL simulation; no P&R/board claim'), indent=2))
    print(out)


if __name__ == '__main__':
    main()
