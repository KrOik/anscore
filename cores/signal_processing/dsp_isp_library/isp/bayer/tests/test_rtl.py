"""ISP-07 RTL regression: snapshot sources, generate independent Bayer frames
and per-frame atomic configs, run real iverilog/vvp regressions with
randomized handshake, mutations, resets and illegal-parameter builds.
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
from reference import Config, demosaic, pack_config, pack_expected, pack_input

HERE = pathlib.Path(__file__).resolve().parents[1]
LIB = HERE.parents[1]
ROOT = LIB.parents[1]
INFRA = [LIB / 'infra/window/stream_window.v',
         LIB / 'infra/window/stream_window_padded.v']

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
    if kind == 'luma':  # smooth shared ramp: channels correlate, R=G=B=x+y
        return [[min(mx, (x + 2 * y) * mx // max(1, w + 2 * h - 3))
                 for x in range(w)] for y in range(h)]
    return [[r.randrange(mx + 1) for _ in range(w)] for _ in range(h)]


def build_case(w, h, bits, seed):
    """All 16 (cfa, ox, oy) phase combos plus pattern sweeps per frame."""
    r = random.Random(seed)
    plans = []
    for i, (cfa, ox, oy) in enumerate(
            [(c, ox, oy) for c in range(4) for ox in (0, 1) for oy in (0, 1)]):
        plans.append((cfa, ox, oy, PATTERNS[(i + w + h) % len(PATTERNS)]))
    # Extra frames: every pattern under random legal phase configs.
    for i, kind in enumerate(PATTERNS + ['random', 'checker']):
        plans.append((r.randrange(4), r.randrange(2), r.randrange(2), kind))
    inputs, expected, configs = [], [], []
    for cfa, ox, oy, kind in plans:
        cfg = Config(cfa=cfa, ox=ox, oy=oy)
        configs.append(pack_config(cfg))
        f = make_frame(w, h, kind, bits, r)
        recs = demosaic(f, cfg, bits)
        assert len(recs) == w * h
        for rec in recs:
            inputs.append(pack_input(rec['pixel'], rec['sof'], rec['eol'], bits))
            expected.append(pack_expected(rec, bits))
    return inputs, expected, configs


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path)
    a = p.parse_args()
    out = a.output or HERE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = list((HERE / 'rtl').glob('*.sv')) + INFRA + [
        HERE / 'tests' / 'tb_bayer.sv', HERE / 'models' / 'reference.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        indent=2))
    src = src.resolve()
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    results = []
    # (BITS, WIDTH, HEIGHT): min 3x3 edge cases plus sub-window degenerates.
    cases = [(8, 32, 24), (10, 32, 24), (10, 16, 16), (8, 7, 5),
             (8, 3, 3), (10, 4, 3), (8, 2, 2), (8, 1, 1)]
    for bits, w, h in cases:
        case = out / f'b{bits}_w{w}_h{h}'
        case.mkdir()
        inputs, expected, configs = build_case(w, h, bits, 707 + bits + w * 3 + h)
        nf, nt = len(configs), len(inputs)
        for name, data in [('input', inputs), ('expected', expected),
                           ('config', configs)]:
            (case / (name + '.mem')).write_text(
                ''.join(f'{v:x}\n' for v in data))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_bayer', '-o', 'sim.vvp',
               f'-Ptb_bayer.W={w}', f'-Ptb_bayer.H={h}',
               f'-Ptb_bayer.D={bits}', f'-Ptb_bayer.NF={nf}',
               str(src / 'stream_window.v'),
               str(src / 'stream_window_padded.v'),
               str(src / 'bayer_demosaic.sv'),
               str(src / 'tb_bayer.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env, capture_output=True,
                               text=True, timeout=600)
            (case / (label + '.log')).write_text(
                '$ ' + ' '.join(command) + '\n' + r.stdout + r.stderr)
            assert r.returncode == 0, (case, r.stdout, r.stderr)
        assert 'PASS bayer' in r.stdout, (case, r.stdout)
        for mutation in ('data', 'sideband', 'count', 'order'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=600)
            (case / ('negative_' + mutation + '.log')).write_text(
                r.stdout + r.stderr)
            assert r.returncode != 0 and (
                'bayer mismatch' in r.stdout
                or mutation == 'count' and 'count timeout' in r.stdout), (
                case, mutation, r.stdout)
        results.append(dict(bits=bits, width=w, height=h,
                            frames=nf, outputs=nt, status='PASS',
                            checker_negatives=4))
        print('PASS', case.name, f'frames={nf} outputs={nt}', flush=True)
    for param, value in [('BITS', 9), ('BITS', 12), ('WIDTH', 0),
                         ('HEIGHT', 0)]:
        case = out / f'invalid_{param}_{value}'
        case.mkdir()
        (case / 'tb.sv').write_text(
            f'module tb; bayer_demosaic #(.{param}({value})) dut(); '
            'initial #1 $finish; endmodule\n')
        cp = subprocess.run(
            [iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
             str(src / 'stream_window.v'),
             str(src / 'stream_window_padded.v'),
             str(src / 'bayer_demosaic.sv'), 'tb.sv'],
            cwd=case, env=env, capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=case, env=env,
                            capture_output=True, text=True)
        (case / 'run.log').write_text(
            cp.stdout + cp.stderr + rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout
    (out / 'summary.json').write_text(json.dumps(dict(
        status='PASS', cases=results, illegal_static_parameters=4,
        scope='RTL simulation; no P&R/board claim'), indent=2))
    print(out)


if __name__ == '__main__':
    main()
