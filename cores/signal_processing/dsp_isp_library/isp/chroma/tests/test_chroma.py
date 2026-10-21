"""ISP-15 chroma resampling & pixel packing: deterministic RTL regression.

Generates per-case input/config/expected memories from the independent
models (models/model.py), compiles the SystemVerilog testbenches with
iverilog -g2012 -Wall and runs them with randomized valid/ready plus
checker-mutation negative runs (+data/+order/+count/+sideband).
"""
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
from model import (chroma422_beats, chroma420_beats, chroma420_from444,
                   chroma422_float_chroma, chroma420_float_chroma,
                   pack_words, unpack_samples)

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent                      # isp/chroma
ROOT = BASE.parents[3]                  # repository root
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'


def write_mem(path, values):
    path.write_text(''.join(f'{v:x}\n' for v in values))


def run(cmd, cwd, env, logname, timeout=240, reject=False):
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True,
                       text=True, timeout=timeout)
    (cwd / logname).write_text('$ ' + ' '.join(str(c) for c in cmd)
                              + '\n' + r.stdout + r.stderr)
    ok = (r.returncode != 0) if reject else (r.returncode == 0)
    if not ok:
        raise RuntimeError(f'{cwd.name}/{logname}: {r.stdout[-1500:]}')
    return r


def make_frames(rng, w, h, bits, nf):
    """NF deterministic frames with varied content (random, gradient,
    extremes, checkerboard) to exercise the filters and rounding."""
    m = (1 << bits) - 1
    frames = []
    for f in range(nf):
        kind = f % 4
        frame = []
        for y in range(h):
            row = []
            for x in range(w):
                if kind == 0:
                    p = tuple(rng.randrange(m + 1) for _ in range(3))
                elif kind == 1:
                    p = ((x + 3 * y) & m, (2 * x + y) & m, (x ^ y) & m)
                elif kind == 2:
                    p = (m if (x + y) % 2 else 0,
                         m if x % 2 else 0,
                         (x * m // max(w - 1, 1)) & m)
                else:
                    p = (m if (x ^ y) & 1 else 0,  # luma checkerboard
                         m if x & 1 else 0,        # worst-case chroma alias
                         0 if y & 1 else m)
                row.append(p)
            frame.append(row)
        frames.append(frame)
    return frames


def hex422_input(frames, bits):
    """{user,last,pixel[3B]} per beat."""
    w = len(frames[0][0]); h = len(frames[0])
    mem = []
    for fr in frames:
        for y in range(h):
            for x in range(w):
                pix = (fr[y][x][0] << (2 * bits)) | (fr[y][x][1] << bits) \
                    | fr[y][x][2]
                mem.append(pix | ((x == w - 1) << (3 * bits))
                           | ((x == 0 and y == 0) << (3 * bits + 1)))
    return mem


def hex422_beats_mem(beats, bits):
    return [w | (l << (4 * bits)) | (u << (4 * bits + 1))
            for w, u, l in beats]


def hex420_beats_mem(beats, bits):
    return [w | (l << (2 * bits + 1)) | (u << (2 * bits + 2))
            for w, u, l in beats]


def main():
    out = BASE / 'evidence' / ('sim_' + datetime.datetime.now()
                               .strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True)
    srcdir = out / 'sources'
    srcdir.mkdir()
    files = ([BASE / 'rtl' / n for n in
              ('chroma_422.sv', 'chroma_420.sv', 'pix_pack.sv')]
             + list(HERE.glob('*.sv'))
             + [BASE / 'models' / 'model.py', HERE / 'test_chroma.py'])
    for f in files:
        shutil.copy2(f, srcdir / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))
    srcdir = srcdir.resolve()
    env = dict(os.environ)
    env['PATH'] = str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') \
        + os.pathsep + env['PATH']
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    summary = {'cases': [], 'illegal_static': [], 'status': 'PASS'}

    # ---------------------------------------------------------- chroma_422
    rng = random.Random(0xC422)
    nf = 4
    cases422 = [(4, 4, 8), (5, 3, 8), (7, 6, 8), (3, 4, 8), (2, 2, 8),
                (1, 1, 8), (8, 5, 8), (6, 1, 8), (9, 7, 8),
                (6, 4, 10), (5, 5, 10), (1, 3, 10)]
    for ci, (w, h, d) in enumerate(cases422):
        case = out / f'c422_w{w}_h{h}_d{d}'
        case.mkdir()
        sitings = [(f + ci) & 1 for f in range(nf)]
        frames = make_frames(rng, w, h, d, nf)
        inputs = hex422_input(frames, d)
        expected = []
        for f, fr in enumerate(frames):
            expected += hex422_beats_mem(chroma422_beats(fr, d, sitings[f]), d)
        write_mem(case / 'input.mem', inputs)
        write_mem(case / 'expected.mem', expected)
        write_mem(case / 'config.mem', sitings)
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_chroma422', '-o', 'sim.vvp',
               f'-Ptb_chroma422.W={w}', f'-Ptb_chroma422.H={h}',
               f'-Ptb_chroma422.D={d}', f'-Ptb_chroma422.NF={nf}',
               str(srcdir / 'chroma_422.sv'),
               str(srcdir / 'tb_chroma422.sv')]
        run(cmd, case, env, 'compile.log')
        run([vv, 'sim.vvp'], case, env, 'run.log')
        for mut in ('data', 'order', 'count', 'sideband'):
            run([vv, 'sim.vvp', '+' + mut], case, env,
                f'negative_{mut}.log', reject=True)
        # float-vs-integer residual for the record
        err = 0.0
        for f, fr in enumerate(frames):
            fcb, fcr = chroma422_float_chroma(fr, sitings[f])
            icb = [w_ >> (2 * d) & ((1 << d) - 1)
                   for w_, u_, l_ in chroma422_beats(fr, d, sitings[f])]
            ow = (w + 1) // 2
            err = max(err, max(abs(float(fcb[y][i]) - icb[y * ow + i])
                               for y in range(h) for i in range(ow)))
        summary['cases'].append(dict(tb='chroma422', w=w, h=h, bits=d,
                                     frames=nf, outputs=len(expected),
                                     float_max_abs_error=str(err),
                                     status='PASS'))
        print('PASS', case.name, flush=True)

    # ---------------------------------------------------------- chroma_420
    rng = random.Random(0xC420)
    cases420 = [(4, 4, 8, 0), (5, 3, 8, 0), (7, 6, 8, 0), (2, 2, 8, 0),
                (1, 1, 8, 0), (6, 5, 8, 0), (3, 4, 8, 0), (8, 4, 8, 0),
                (4, 3, 10, 0), (6, 4, 10, 0),
                (6, 4, 8, 1), (5, 3, 8, 1), (4, 4, 10, 1)]
    for ci, (w, h, d, src) in enumerate(cases420):
        case = out / f'c420_w{w}_h{h}_d{d}_s{src}'
        case.mkdir()
        sitings = [(f + ci) & 1 for f in range(nf)]
        frames = make_frames(rng, w, h, d, nf)
        ow = (w + 1) // 2
        inputs = []
        expected = []
        for f, fr in enumerate(frames):
            beats422 = chroma422_beats(fr, d, sitings[f])
            if src == 0:
                inputs += hex422_input([fr], d)
            else:
                inputs += [wv | (l << (4 * d)) | (u << (4 * d + 1))
                           for wv, u, l in beats422]
            expected += hex420_beats_mem(
                chroma420_beats(beats422, ow, h, d), d)
        write_mem(case / 'input.mem', inputs)
        write_mem(case / 'expected.mem', expected)
        write_mem(case / 'config.mem', sitings)
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_chroma420', '-o', 'sim.vvp',
               f'-Ptb_chroma420.W={w}', f'-Ptb_chroma420.H={h}',
               f'-Ptb_chroma420.D={d}', f'-Ptb_chroma420.NF={nf}',
               f'-Ptb_chroma420.SRC={src}',
               str(srcdir / 'chroma_422.sv'), str(srcdir / 'chroma_420.sv'),
               str(srcdir / 'tb_chroma420.sv')]
        run(cmd, case, env, 'compile.log')
        run([vv, 'sim.vvp'], case, env, 'run.log')
        for mut in ('data', 'order', 'count', 'sideband'):
            run([vv, 'sim.vvp', '+' + mut], case, env,
                f'negative_{mut}.log', reject=True)
        err = 0.0
        for f, fr in enumerate(frames):
            vcb, vcr = chroma420_float_chroma(fr, sitings[f])
            beats = chroma420_from444(fr, d, sitings[f])
            icb = [(wv >> d) & ((1 << d) - 1)
                   for wv, u_, l_ in beats if wv >> (2 * d)]
            rows = (h + 1) // 2
            err = max(err, max(abs(float(vcb[j][i]) - icb[j * ow + i])
                               for j in range(rows) for i in range(ow)))
        summary['cases'].append(dict(tb='chroma420', w=w, h=h, bits=d,
                                     src422=src, frames=nf,
                                     outputs=len(expected),
                                     float_max_abs_error=str(err),
                                     status='PASS'))
        print('PASS', case.name, flush=True)

    # ---------------------------------------------------------- pix_pack
    rng = random.Random(0xCE11)
    cases_pack = [(8, 4, 0), (8, 2, 0), (8, 1, 0), (8, 4, 8), (8, 6, 16),
                  (10, 4, 0), (10, 2, 16), (10, 4, 16), (10, 3, 16)]
    for d, ns, slot in cases_pack:
        case = out / f'pack_d{d}_ns{ns}_s{slot}'
        case.mkdir()
        m = (1 << d) - 1
        samples = []
        # two "frames": lengths deliberately not multiples of NS
        for ln in (ns * 2 + 1, ns + 2):
            base = len(samples)
            for i in range(ln):
                v = rng.randrange(m + 1) if (i + base) % 3 else (m if i & 1 else 0)
                samples.append((v, int(i == 0), int(i == ln - 1)))
        words = pack_words(samples, ns, d, slot)
        uns = unpack_samples(words, ns, d, slot)
        write_mem(case / 'input.mem',
                  [v | (l << d) | (u << (d + 1)) for v, u, l in samples])
        slt = slot if slot else d
        write_mem(case / 'expected_pack.mem',
                  [wv | (l << (ns * slt)) | (u << (ns * slt + 1))
                   for wv, u, l in words])
        write_mem(case / 'expected_unpack.mem',
                  [v | (l << d) | (u << (d + 1)) for v, u, l in uns])
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_pix_pack', '-o', 'sim.vvp',
               f'-Ptb_pix_pack.D={d}', f'-Ptb_pix_pack.NS={ns}',
               f'-Ptb_pix_pack.SLOT={slot}',
               f'-Ptb_pix_pack.NIN={len(samples)}',
               f'-Ptb_pix_pack.NWOUT={len(words)}',
               f'-Ptb_pix_pack.NUN={len(uns)}',
               str(srcdir / 'pix_pack.sv'), str(srcdir / 'tb_pix_pack.sv')]
        run(cmd, case, env, 'compile.log')
        run([vv, 'sim.vvp'], case, env, 'run.log')
        for mut in ('data', 'order', 'count', 'sideband'):
            run([vv, 'sim.vvp', '+' + mut], case, env,
                f'negative_{mut}.log', reject=True)
        summary['cases'].append(dict(tb='pix_pack', bits=d, ns=ns, slot=slot,
                                     samples=len(samples), words=len(words),
                                     unpacked=len(uns), status='PASS'))
        print('PASS', case.name, flush=True)

    # ------------------------------------------------- illegal parameters
    bad = [('chroma_422', 'BITS', 9), ('chroma_422', 'WIDTH', 0),
           ('chroma_422', 'HEIGHT', 0),
           ('chroma_420', 'BITS', 9), ('chroma_420', 'SRC422', 2),
           ('chroma_420', 'HEIGHT', 0),
           ('pix_pack', 'BITS', 9), ('pix_pack', 'NS', 0),
           ('pix_pack', 'NS', 9), ('pix_pack', 'SLOT', 12),
           ('pix_pack', 'SLOT', 8),   # legal for D=8 only; force BITS=10 below
           ('pix_unpack', 'NS', 0)]
    for mod, par, val in bad:
        extra = '.BITS(10),' if (mod, par) == ('pix_pack', 'SLOT') else ''
        case = out / f'illegal_{mod}_{par}_{val}'
        case.mkdir()
        (case / 'tb.sv').write_text(
            f'module tb; {mod} #({extra}.{par}({val})) dut();'
            ' initial #1 $finish; endmodule\n')
        sources = [srcdir / 'chroma_422.sv', srcdir / 'chroma_420.sv',
                   srcdir / 'pix_pack.sv']
        cmd = [iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp', 'tb.sv'] \
            + [str(s) for s in sources]
        cp = subprocess.run(cmd, cwd=case, env=env, capture_output=True,
                            text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=case, env=env,
                            capture_output=True, text=True)
        (case / 'run.log').write_text(cp.stdout + cp.stderr + rp.stdout
                                      + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout, rp.stdout
        summary['illegal_static'].append(f'{mod}.{par}={val}')

    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(out)
    print('ALL PASS:', len(summary['cases']), 'cases,',
          len(summary['illegal_static']), 'illegal-parameter rejections')


if __name__ == '__main__':
    main()
