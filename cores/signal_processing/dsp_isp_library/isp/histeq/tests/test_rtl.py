"""ISP-11 RTL regression: snapshot sources, generate independent frames and
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
from reference import (Config, pack_config, pack_expected, pack_input,
                       run_frames, widths)

HERE = pathlib.Path(__file__).resolve().parents[1]
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

QUAL_SIZES = [(1, 1), (2, 2), (7, 5), (32, 24)]
PATTERNS = ['uniform', 'zeros', 'max', 'gradient', 'dualpeak', 'checker',
            'random']


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
    if kind == 'dualpeak':
        lo, hi = mx // 4, (3 * mx) // 4
        return [[lo if (x + 2 * y) % 3 else hi for x in range(w)]
                for y in range(h)]
    if kind == 'checker':
        v = r.randrange(1, mx + 1)
        return [[(x + y) % 2 * v for x in range(w)] for y in range(h)]
    return [[r.randrange(mx + 1) for _ in range(w)] for _ in range(h)]


def legal_grids(w, h):
    """All (txl,tyl) legal for mode 2 on this image size."""
    out = []
    for txl in range(5):
        for tyl in range(5):
            if txl + tyl <= 4 and w % (1 << txl) == 0 and h % (1 << tyl) == 0:
                out.append((txl, tyl))
    return out


def build_case(bits, maxw, maxh, seed):
    """Frame plan: first frame mode-0 (streamable), then coverage of all
    modes, tile grids, clip limits and patterns per qualification size."""
    r = random.Random(seed)
    sizes = [s for s in QUAL_SIZES if s[0] <= maxw and s[1] <= maxh]
    if maxw > 40 and maxh > 30:
        sizes += [(40, 30), (maxw, maxh)]
    plans = []
    for w, h in sizes:
        grids = legal_grids(w, h)
        # first frame of the whole case must be mode 0 (held-output test)
        plans.append((w, h, 0, 0, 0, 0, 'random'))
        plans.append((w, h, 0, 0, 0, 0, 'gradient'))   # prev-LUT in action
        plans.append((w, h, 1, 0, 0, 0, 'dualpeak'))
        plans.append((w, h, 1, 0, 0, 0, 'uniform'))
        picks = []
        for i, kind in enumerate(PATTERNS):
            g = grids[(i + w + h) % len(grids)]
            clip = [1, 3, 64, 65535, 7][(i + w * h) % 5]
            picks.append((kind, g, clip))
        # extremes: max grid, tiny clip, no-op clip
        picks.append(('random', grids[-1], 1))
        picks.append(('checker', grids[0], 65535))
        for kind, (txl, tyl), clip in picks:
            plans.append((w, h, 2, txl, tyl, clip, kind))
    frames, cfgs = [], []
    for w, h, mode, txl, tyl, clip, kind in plans:
        frames.append(make_frame(w, h, kind, bits, r))
        cfgs.append(Config(w, h, mode, txl, tyl, clip,
                           max_w=maxw, max_h=maxh))
    outs = run_frames(frames, cfgs, bits)
    inputs, expected, configs, sched = [], [], [], [0]
    for f, cfg, o in zip(frames, cfgs, outs):
        configs.append(pack_config(cfg, widths(bits, maxw, maxh)['cwx'],
                                   widths(bits, maxw, maxh)['cwy']))
        for y, row in enumerate(f):
            for x, p in enumerate(row):
                sof = int(x == 0 and y == 0)
                eol = int(x == cfg.img_w - 1)
                inputs.append(pack_input(p, sof, eol, bits))
                expected.append(pack_expected(sof, eol, o[y][x], bits))
        sched.append(len(inputs))
    return inputs, expected, configs, sched


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path)
    a = p.parse_args()
    out = a.output or HERE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = list((HERE / 'rtl').glob('*.sv')) + [
        HERE / 'tests' / 'tb_histeq.sv', HERE / 'models' / 'reference.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))
    src = src.resolve()
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = (str(cad / 'lib') + os.pathsep + str(cad / 'bin')
                   + os.pathsep + env['PATH'])
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    results = []
    cases = [(8, 32, 24), (10, 32, 24), (10, 64, 64), (8, 4, 4)]
    for bits, maxw, maxh in cases:
        case = out / f'b{bits}_w{maxw}_h{maxh}'
        case.mkdir()
        inputs, expected, configs, sched = build_case(
            bits, maxw, maxh, 1107 + bits + maxw)
        nf, nt = len(configs), len(inputs)
        for name, data in [('input', inputs), ('expected', expected),
                           ('config', configs), ('sched', sched)]:
            (case / (name + '.mem')).write_text(
                ''.join(f'{v:x}\n' for v in data))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_histeq', '-o', 'sim.vvp',
               f'-Ptb_histeq.BITS={bits}', f'-Ptb_histeq.MAXW={maxw}',
               f'-Ptb_histeq.MAXH={maxh}', f'-Ptb_histeq.NF={nf}',
               f'-Ptb_histeq.NT={nt}',
               str(src / 'histeq_stream.sv'), str(src / 'tb_histeq.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env, capture_output=True,
                               text=True, timeout=1200)
            (case / (label + '.log')).write_text(
                '$ ' + ' '.join(command) + '\n' + r.stdout + r.stderr)
            assert r.returncode == 0, (case, r.stdout, r.stderr)
        assert 'PASS histeq' in r.stdout, (case, r.stdout)
        for mutation in ('data', 'sideband', 'count', 'order'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=1200)
            (case / ('negative_' + mutation + '.log')).write_text(
                r.stdout + r.stderr)
            assert r.returncode != 0 and (
                'histeq mismatch' in r.stdout
                or mutation == 'count' and 'count timeout' in r.stdout), (
                case, mutation, r.stdout)
        results.append(dict(bits=bits, max_w=maxw, max_h=maxh,
                            frames=nf, outputs=nt, status='PASS',
                            checker_negatives=4))
        print('PASS', case.name, f'frames={nf} outputs={nt}', flush=True)
    for param, value in [('BITS', 9), ('MAX_W', 0), ('MAX_H', 0),
                         ('MAX_W', 4096), ('CLAHE_EN', 7)]:
        case = out / f'invalid_{param}_{value}'
        case.mkdir()
        (case / 'tb.sv').write_text(
            f'module tb; histeq_stream #(.{param}({value})) dut(); '
            'initial #1 $finish; endmodule\n')
        cp = subprocess.run(
            [iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
             str(src / 'histeq_stream.sv'), 'tb.sv'], cwd=case, env=env,
            capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=case, env=env,
                            capture_output=True, text=True)
        (case / 'run.log').write_text(
            cp.stdout + cp.stderr + rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout
    (out / 'summary.json').write_text(json.dumps(dict(
        status='PASS', cases=results, illegal_static_parameters=5,
        scope='RTL simulation; no P&R/board claim'), indent=2))
    print(out)


if __name__ == '__main__':
    main()
