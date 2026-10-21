"""ISP-08 RTL regression: snapshot sources (core RTL + infra window), generate
independent frames and per-frame atomic configs, run real iverilog/vvp
regressions with randomized handshake, mutations, resets and
illegal-parameter builds.  Pure stdlib.
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
from reference import (Config, GAIN_W, apply_blc, awb_sums, pack_awb,
                       pack_config, pack_expected, pack_input, packpix,
                       pipeline, widths)

HERE = pathlib.Path(__file__).resolve().parents[1]
LIB = HERE.parents[1]
ROOT = LIB.parents[1]
INFRA = LIB / 'infra' / 'window'

PATTERNS = ['uniform', 'zeros', 'max', 'gradient', 'checker', 'random',
            'defects', 'cluster']


def make_frame(w, h, kind, bits, ch, r):
    """Return a frame of packed pixel words."""
    mx = (1 << bits) - 1

    def px(vals=None):
        if vals is None:
            return packpix([r.randrange(mx + 1) for _ in range(ch)], bits)
        return packpix((list(vals) + [0] * ch)[:ch], bits)

    if kind == 'uniform':
        v = px()
        return [[v] * w for _ in range(h)]
    if kind == 'zeros':
        return [[0] * w for _ in range(h)]
    if kind == 'max':
        return [[packpix([mx] * ch, bits)] * w for _ in range(h)]
    if kind == 'gradient':
        return [[packpix([(x * 3 + y * 5 + c * 40) & mx for c in range(ch)],
                         bits) for x in range(w)] for y in range(h)]
    if kind == 'checker':
        v = r.randrange(1, mx + 1)
        return [[packpix([(((x + y) % 2) * v + c * 7) & mx for c in range(ch)],
                         bits) for x in range(w)] for y in range(h)]
    if kind == 'defects':
        # Smooth field + isolated hot/dead pixels (single-channel defects too).
        base = [[packpix([min(mx, 60 + x + y * 2 + c * 20) for c in range(ch)],
                         bits) for x in range(w)] for y in range(h)]
        n = max(1, (w * h) // 16)
        for _ in range(n):
            x = r.randrange(w)
            y = r.randrange(h)
            cur = [((base[y][x] >> (c * bits)) & mx) for c in range(ch)]
            c = r.randrange(ch)               # defect one channel only
            cur[c] = mx if r.randrange(2) else 0
            base[y][x] = packpix(cur, bits)
        return base
    if kind == 'cluster':
        # Adjacent defective pixels: exercises the documented cluster limit
        # (the model is the contract either way).
        base = [[packpix([min(mx, 100 + c * 30) for c in range(ch)], bits)
                 for x in range(w)] for y in range(h)]
        if w >= 2 and h >= 2:
            for c in range(ch):
                cur = [0] * ch
                cur[c] = mx
                base[1][1] = packpix(cur, bits)
                base[1][2 % w] = packpix(cur, bits)
                base[2 % h][1] = packpix(cur, bits)
        return base
    return [[px() for _ in range(w)] for _ in range(h)]


def make_configs(bits, ch, w, h, r):
    """Deterministic + randomized per-frame configs exercising every stage."""
    mx = (1 << bits) - 1

    def cfg(blc, wb, thr, gs):
        return Config(w, h, tuple(blc), tuple(wb), thr, gs,
                      width=w, height=h, bits=bits, ch=ch)

    out = [
        cfg([0] * 3, [256] * 3, mx, 0),                    # full bypass
        cfg([mx // 4] * 3, [256] * 3, 0, 0),               # BLC only
        cfg([0] * 3, [384, 256, 180], mx, 0),              # WB only
        cfg([8] * 3, [256] * 3, mx // 8, 0),               # DPC mid thr
        cfg([0] * 3, [256] * 3, mx // 8, 1),               # gamma encode
        cfg([0] * 3, [256] * 3, mx // 8, 2),               # gamma decode
        cfg([mx // 8, mx // 4, mx // 16], [300, 256, 512], 4, 1),  # all on
        cfg([mx] * 3, [4095] * 3, 0, 2),                   # extremes
    ]
    for _ in range(4):                                     # randomized extra
        out.append(cfg([r.randrange(mx + 1) for _ in range(3)],
                       [r.randrange(1 << GAIN_W) for _ in range(3)],
                       r.randrange(mx + 1), r.randrange(3)))
    return out


def build_case(bits, ch, w, h, seed):
    r = random.Random(seed)
    cfgs = make_configs(bits, ch, w, h, r)
    inputs, expected, configs, awbs, sched = [], [], [], [], [0]
    sumw = widths(bits, ch, w, h)['sumw']
    for i, cfg in enumerate(cfgs):
        kind = PATTERNS[i % len(PATTERNS)]
        f = make_frame(w, h, kind, bits, ch, r)
        out, sums = pipeline(f, cfg)
        assert len(out) == h and len(out[0]) == w
        assert sums == awb_sums(apply_blc(f, cfg), ch, bits)
        configs.append(pack_config(cfg))
        awbs.append(pack_awb(sums, sumw))
        for y in range(h):
            for x in range(w):
                sof = int(x == 0 and y == 0)
                eol = int(x == w - 1)
                inputs.append(pack_input(f[y][x], sof, eol, bits, ch))
                expected.append(pack_expected(out[y][x], sof, eol, bits, ch))
        sched.append(len(inputs))
    return inputs, expected, configs, awbs, sched


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path)
    a = p.parse_args()
    out = a.output or HERE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = sorted((HERE / 'rtl').glob('*.sv')) + \
        [HERE / 'rtl' / 'gamma_table.vh',
         INFRA / 'stream_window.v', INFRA / 'stream_window_padded.v',
         HERE / 'tests' / 'tb_basic_isp.sv', HERE / 'models' / 'reference.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        indent=2))
    src = src.resolve()
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = str(cad / 'bin') + os.pathsep + str(cad / 'lib') + \
        os.pathsep + env['PATH']
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    results = []
    # (BITS, CH, WIDTH, HEIGHT)
    cases = [(8, 3, 32, 24), (10, 3, 32, 24), (10, 1, 64, 64),
             (8, 3, 4, 4), (8, 1, 1, 1), (10, 3, 7, 5)]
    for bits, ch, w, h in cases:
        case = out / f'b{bits}_c{ch}_w{w}_h{h}'
        case.mkdir()
        inputs, expected, configs, awbs, sched = build_case(
            bits, ch, w, h, 910 + bits + w + ch)
        nf, nt = len(configs), len(inputs)
        for name, data in [('input', inputs), ('expected', expected),
                           ('config', configs), ('awb', awbs),
                           ('sched', sched)]:
            (case / (name + '.mem')).write_text(
                ''.join(f'{v:x}\n' for v in data))
        rtl = [str(src / f.name) for f in sorted((HERE / 'rtl').glob('*.sv'))] + \
            [str(src / 'stream_window.v'), str(src / 'stream_window_padded.v')]
        cmd = [iv, '-g2012', '-Wall', '-I', str(src), '-s', 'tb_basic_isp',
               '-o', 'sim.vvp',
               f'-Ptb_basic_isp.BITS={bits}', f'-Ptb_basic_isp.CH={ch}',
               f'-Ptb_basic_isp.W={w}', f'-Ptb_basic_isp.H={h}',
               f'-Ptb_basic_isp.NF={nf}', f'-Ptb_basic_isp.NT={nt}'] + \
            rtl + [str(src / 'tb_basic_isp.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env, capture_output=True,
                               text=True, timeout=900)
            (case / (label + '.log')).write_text(
                '$ ' + ' '.join(command) + '\n' + r.stdout + r.stderr)
            assert r.returncode == 0, (case, r.stdout, r.stderr)
        assert 'PASS basic_isp' in r.stdout, (case, r.stdout)
        for mutation in ('data', 'sideband', 'count', 'order'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=900)
            (case / ('negative_' + mutation + '.log')).write_text(
                r.stdout + r.stderr)
            assert r.returncode != 0 and (
                'basic_isp mismatch' in r.stdout
                or mutation == 'count' and 'count timeout' in r.stdout), (
                case, mutation, r.stdout)
        results.append(dict(bits=bits, ch=ch, width=w, height=h,
                            frames=nf, outputs=nt, status='PASS',
                            checker_negatives=4))
        print('PASS', case.name, f'frames={nf} outputs={nt}', flush=True)
    for param, value in [('BITS', 9), ('CH', 2), ('WIDTH', 0), ('HEIGHT', 0)]:
        case = out / f'invalid_{param}_{value}'
        case.mkdir()
        (case / 'tb.sv').write_text(
            f'module tb; basic_isp_top #(.{param}({value})) dut(); '
            'initial #1 $finish; endmodule\n')
        cp = subprocess.run(
            [iv, '-g2012', '-I', str(src), '-s', 'tb', '-o', 'bad.vvp'] +
            [str(src / f.name) for f in sorted((HERE / 'rtl').glob('*.sv'))] +
            [str(src / 'stream_window.v'),
             str(src / 'stream_window_padded.v'), 'tb.sv'],
            cwd=case, env=env, capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=case, env=env,
                            capture_output=True, text=True)
        (case / 'run.log').write_text(cp.stdout + cp.stderr +
                                     rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout, rp.stdout
    (out / 'summary.json').write_text(json.dumps(dict(
        status='PASS', cases=results, illegal_static_parameters=4,
        scope='RTL simulation; no P&R/board claim'), indent=2))
    print(out)


if __name__ == '__main__':
    main()
