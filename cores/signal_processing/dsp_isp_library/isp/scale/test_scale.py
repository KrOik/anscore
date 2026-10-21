"""Simulation regression for scale_poly6_stream.

Generates stimulus frames, computes bit-exact expected output with
scale_model.py, runs iverilog + vvp for several scale configurations with
random input gaps and output stalls, and stores evidence.

Run from anywhere:
    python cores/signal_processing/dsp_isp_library/isp/scale/test_scale.py
    python cores/signal_processing/dsp_isp_library/isp/scale/test_scale.py --output <dir>
"""
import argparse, datetime, hashlib, json, os, pathlib, random, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
LIB = HERE.parents[1]          # cores/signal_processing/dsp_isp_library
ROOT = LIB.parents[1]          # repo root
sys.path.insert(0, str(HERE))
from scale_model import scale_frame, pack


def make_frame(rng, w, h, kind):
    if kind == 'random':
        return [[tuple(rng.randrange(256) for _ in range(3))
                 for _x in range(w)] for _y in range(h)]
    if kind == 'gradient':
        return [[((x * 255 // max(w - 1, 1)),
                  (y * 255 // max(h - 1, 1)),
                  ((x + y) * 255 // max(w + h - 2, 1)))
                 for x in range(w)] for y in range(h)]
    if kind == 'checker':
        return [[(255, 255, 255) if (x // 2 + y // 2) % 2 else (0, 0, 0)
                 for x in range(w)] for y in range(h)]
    if kind == 'edges':
        f = [[(20, 40, 60) for _ in range(w)] for _ in range(h)]
        for y in range(h):
            f[y][w // 2] = (250, 10, 10)
        for x in range(w):
            f[h // 2][x] = (10, 250, 10)
        return f
    raise ValueError(kind)


def beats_in(frame):
    w, h = len(frame[0]), len(frame)
    out = []
    for y in range(h):
        for x in range(w):
            sof = 1 if (x == 0 and y == 0) else 0
            eol = 1 if x == w - 1 else 0
            out.append((sof << 25) | (eol << 24) | pack(frame[y][x]))
    return out


def beats_out(frame):
    return beats_in(frame)


def run_case(out, cad, tag, frames_cfg, seed, corrupt=False):
    """frames_cfg: list of (in_w,in_h,out_w,out_h,kind) one per frame.
    corrupt=True flips one expected bit to verify the checker reports FAIL."""
    case = out / tag
    case.mkdir(parents=True)
    rng = random.Random(seed)
    inputs, expected, configs = [], [], []
    for (iw, ih, ow, oh, kind) in frames_cfg:
        fr = make_frame(rng, iw, ih, kind)
        exp = scale_frame(fr, iw, ih, ow, oh)
        inputs += beats_in(fr)
        expected += beats_out(exp)
        configs.append((iw << 36) | (ih << 24) | (ow << 12) | oh)
    if corrupt:
        expected[len(expected) // 2] ^= 1
    (case / 'config.mem').write_text(
        ''.join(f'{c:012x}\n' for c in configs))
    (case / 'input.mem').write_text(
        ''.join(f'{b:07x}\n' for b in inputs))
    (case / 'expected.mem').write_text(
        ''.join(f'{b:07x}\n' for b in expected))
    env = dict(os.environ)
    env['PATH'] = str(cad / 'bin') + os.pathsep + str(cad / 'lib') + \
        os.pathsep + env['PATH']
    ivl = shutil.which('iverilog', path=env['PATH'])
    vvp = shutil.which('vvp', path=env['PATH'])
    maxw = max(max(c[0], c[2]) for c in frames_cfg)
    maxw = max(8, 1 << (maxw - 1).bit_length())
    srcdir = HERE
    cmd = [ivl, '-g2012', '-o', 'sim.vvp', '-s', 'tb_scale_poly6',
           '-I', str(srcdir),
           f'-Ptb_scale_poly6.MAXW={maxw}',
           f'-Ptb_scale_poly6.NF={len(frames_cfg)}',
           f'-Ptb_scale_poly6.NIN={len(inputs)}',
           f'-Ptb_scale_poly6.NOUT={len(expected)}',
           str(srcdir / 'scale_poly6_stream.v'),
           str(srcdir / 'tb_scale_poly6.sv')]
    for stall, mstall in [(0, 0), (40, 30), (70, 60)]:
        c1 = subprocess.run(cmd, cwd=case, env=env, capture_output=True,
                            text=True)
        if c1.returncode != 0:
            (case / 'compile.log').write_text(c1.stdout + c1.stderr)
            return {'case': tag, 'result': 'COMPILE_FAIL',
                    'log': c1.stderr[-2000:]}
        c2 = subprocess.run(
            [vvp, 'sim.vvp',
             f'+stall={stall}', f'+mstall={mstall}', f'+seed={seed + stall}'],
            cwd=case, env=env, capture_output=True, text=True, timeout=600)
        log = c2.stdout + c2.stderr
        (case / f'run_s{stall}_m{mstall}.log').write_text(log)
        passed = 'PASS ' in log and 'FAIL' not in log
        if not passed:
            return {'case': tag, 'stall': stall, 'result': 'FAIL',
                    'log': log[-3000:]}
    return {'case': tag, 'result': 'PASS', 'frames': len(frames_cfg),
            'beats_out': len(expected)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', default=None)
    ap.add_argument('--self-test', action='store_true')
    a = ap.parse_args()
    if a.self_test:
        fr = make_frame(random.Random(1), 8, 8, 'gradient')
        exp = scale_frame(fr, 8, 8, 8, 8)
        assert exp == fr, "identity scale must reproduce the frame"
        print('model self-test OK')
        return 0
    out = pathlib.Path(a.output) if a.output else \
        HERE / 'evidence' / ('sim_' +
            datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=True)
    cad = ROOT / 'tools' / 'oss-cad-suite' / 'oss-cad-suite'
    # hash sources for traceability
    files = [HERE / 'scale_poly6_stream.v', HERE / 'scale_lanczos3.vh',
             HERE / 'tb_scale_poly6.sv', HERE / 'scale_model.py',
             HERE / 'scale_coeffs.json', HERE / 'gen_scale_coeffs.py',
             HERE / 'test_scale.py']
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))
    cases = [
        ('identity_16',  [(16, 16, 16, 16, 'random')]),
        ('up2_16',       [(16, 16, 32, 32, 'gradient')]),
        ('up15_16',      [(16, 16, 24, 24, 'random')]),
        ('down_24_16',   [(24, 18, 16, 12, 'random')]),
        ('up3_16_12',    [(16, 12, 48, 36, 'checker')]),
        ('down4_40_10',  [(40, 30, 10, 8, 'gradient')]),
        ('nonint_20_33', [(20, 16, 33, 17, 'random')]),
        ('wide_up',      [(8, 8, 40, 24, 'edges')]),
        ('narrow',       [(7, 5, 13, 11, 'random')]),
        ('reconfig',     [(16, 16, 24, 24, 'random'),
                         (24, 24, 12, 12, 'gradient'),
                         (12, 12, 12, 12, 'random'),
                         (32, 8, 16, 16, 'checker')]),
        ('min_frame',    [(6, 6, 9, 9, 'random'), (6, 6, 4, 4, 'random')]),
        ('tiny',         [(4, 4, 8, 8, 'random'), (2, 3, 5, 4, 'gradient'),
                          (1, 1, 6, 6, 'random')]),
        ('asym',         [(48, 6, 12, 12, 'random'),
                          (6, 48, 12, 12, 'gradient')]),
    ]
    results = []
    for i, (tag, cfg) in enumerate(cases):
        r = run_case(out, cad, tag, cfg, seed=101 + i * 17)
        results.append(r)
        print(f"{tag:16s} -> {r['result']}")
        if r['result'] != 'PASS':
            print(r.get('log', '')[-1500:])
    # checker-mutation proof: a deliberately wrong expected bit must FAIL
    mut = run_case(out, cad, 'mutant_expect_fail',
                   [(16, 16, 24, 24, 'random')], seed=999, corrupt=True)
    results.append(mut)
    ok_mut = mut['result'] == 'FAIL'
    print(f"{'mutant_expect_fail':16s} -> {'PASS' if ok_mut else 'FAIL'} "
          f"(checker {'did' if ok_mut else 'did NOT'} catch corruption)")
    summary = {'results': results,
               'checker_mutation_detected': ok_mut}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2))
    npass = sum(1 for r in results if r['result'] == 'PASS')
    print(f"{npass}/{len(results)-1} cases PASS, mutation detected={ok_mut} "
          f"-> {out}")
    return 0 if (npass == len(results) - 1 and ok_mut) else 1


if __name__ == '__main__':
    sys.exit(main())
