"""ISP-16 Canny chain: bit-exact model vs RTL, mutations, illegal params."""
import datetime, hashlib, json, os, pathlib, random, shutil, subprocess, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / 'models'))
from model import canny
HERE = pathlib.Path(__file__).resolve().parent      # tests/
MOD  = HERE.parent                                   # isp/canny
LIB  = MOD.parents[1]                                # dsp_isp_library
ROOT = LIB.parents[1]                                # repo root


def frame_pattern(kind, w, h, maxpix, rng):
    """Synthetic coverage: random/flat/steps/checker/impulse/ramp/diagonal/
    ring/corner/fading-line/noise patterns."""
    f = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            if kind == 0:
                v = rng.randrange(maxpix + 1)
            elif kind == 1:
                v = maxpix
            elif kind == 2:
                v = 0
            elif kind == 3:
                v = maxpix if x >= w // 2 else 0          # vertical step
            elif kind == 4:
                v = maxpix if y >= h // 2 else 0          # horizontal step
            elif kind == 5:
                v = maxpix if (x + y) % 2 == 0 else 0     # checkerboard
            elif kind == 6:
                v = maxpix if (x == w // 2 and y == h // 2) else 0
            elif kind == 7:
                d = max(1, w + h - 2)
                v = (x + y) * maxpix // d                 # diagonal ramp
            elif kind == 8:
                v = maxpix if abs(x - y) <= 0 else 0      # diagonal line
            elif kind == 9:                               # ring
                cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
                r = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
                v = maxpix if abs(r - min(w, h) / 3.0) < 0.75 else 0
            elif kind == 10:                              # corner (L)
                v = maxpix if (x == w // 3 or y == h // 3) and \
                    (x >= w // 3 and y >= h // 3) else 0
            elif kind == 11:                              # strong line + weak tail
                if y == h // 2:
                    v = maxpix if x < w // 2 else maxpix // 8
                else:
                    v = 0
            elif kind == 12:                              # noisy vertical edge
                v = (maxpix if x >= w // 2 else 0)
                v = max(0, min(maxpix, v + rng.randrange(-maxpix // 8,
                                                         maxpix // 8 + 1)))
            else:                                         # soft ramp edge
                v = min(maxpix, max(0, (x - w // 3) * maxpix // max(1, w // 3)))
            f[y][x] = v
    return f


def main():
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    out = HERE.parent / 'evidence' / ('sim_' + stamp)
    out.mkdir(parents=True)
    src = out / 'sources'; src.mkdir()
    files = ([MOD / 'rtl/canny_stream.sv', MOD / 'models/model.py',
              MOD / 'tests/tb_canny.sv', MOD / 'tests/test_canny.py',
              LIB / 'infra/window/stream_window.v',
              LIB / 'infra/window/stream_window_padded.v'])
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        indent=2))
    src = src.resolve()
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = str(cad / 'bin') + os.pathsep + str(cad / 'lib') + os.pathsep + env['PATH']
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    results = []
    cases = [(1, 1, 8, 0, 4), (3, 3, 8, 1, 4), (8, 8, 8, 0, 4),
             (9, 8, 8, 1, 2), (16, 16, 8, 0, 4), (32, 24, 8, 1, 4)]
    nf = 8
    total_promoted = total_diff = total_weak = nmut = 0
    for w, h, d, pad, p in cases:
        case = out / f'w{w}_h{h}_d{d}_pad{pad}_p{p}'; case.mkdir()
        rng = random.Random(977 + w + h + d + pad + p)
        maxpix = (1 << d) - 1
        mb = d + 3
        inputs, expected, cfg = [], [], []
        promoted = diff_exact = weak_n = strong_n = 0
        # Frame kinds chosen so every geometry exercises hysteresis
        # promotion (weak pixels adjacent to strong anchors), plus lines,
        # corners, rings, noise and flat extremes.
        kinds = [11, 8, 3, 4, 6, 10, 12, 9]
        tlos = [32, 16, 4, 32, 64, 32, 8, maxpix]
        this = [256, 128, 64, 1020, 2040, 512, 128, 8 * maxpix]
        for fr in range(nf):
            t_lo = tlos[fr % len(tlos)]
            t_hi = this[fr % len(this)]
            smooth = fr & 1
            kind = kinds[fr % len(kinds)]
            img = frame_pattern(kind, w, h, maxpix, rng)
            ans = canny(img, t_lo, t_hi, bool(smooth), pad, p)
            promoted += ans['promoted']; diff_exact += ans['diff_vs_exact']
            weak_n += ans['weak']; strong_n += ans['strong']
            cfg.append((smooth << (2 * mb)) | (t_hi << mb) | t_lo)
            for y in range(h):
                for x in range(w):
                    inputs.append(img[y][x] | ((x == w - 1) << d)
                                  | ((x == 0 and y == 0) << (d + 1)))
                    expected.append((maxpix if ans['mask'][y][x] else 0)
                                    | ((x == w - 1) << d)
                                    | ((x == 0 and y == 0) << (d + 1)))
        total_promoted += promoted; total_diff += diff_exact
        total_weak += weak_n
        for name, data in [('input', inputs), ('expected', expected),
                           ('config', cfg)]:
            (case / (name + '.mem')).write_text(
                ''.join(f'{v:x}\n' for v in data))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_canny', '-o', 'sim.vvp',
               f'-Ptb_canny.W={w}', f'-Ptb_canny.H={h}', f'-Ptb_canny.D={d}',
               f'-Ptb_canny.PAD={pad}', f'-Ptb_canny.P={p}',
               f'-Ptb_canny.NF={nf}'] + [str(src / n) for n in
              ('stream_window.v', 'stream_window_padded.v',
               'canny_stream.sv', 'tb_canny.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env,
                               capture_output=True, text=True, timeout=600)
            (case / (label + '.log')).write_text(r.stdout + r.stderr)
            assert r.returncode == 0, (case, r.stdout[-3000:], r.stderr[-3000:])
        muts = ['data', 'sideband', 'count']
        # 'order' swaps in another expected word; degenerate 1x1 frames have
        # identical expected words so reordering is unobservable there.
        if w * h > 1:
            muts.append('order')
        for mutation in muts:
            nmut += 1
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=600)
            (case / ('negative_' + mutation + '.log')).write_text(
                r.stdout + r.stderr)
            assert r.returncode != 0 and ('canny mismatch' in r.stdout
                or (mutation == 'count' and 'count timeout' in r.stdout)), \
                (case, mutation, r.stdout[-2000:])
        row = dict(w=w, h=h, bits=d, padding=pad, passes=p, frames=nf,
                   promoted=promoted, weak=weak_n, strong=strong_n,
                   diff_vs_exact_hysteresis=diff_exact, status='PASS')
        results.append(row); print('PASS', case.name, row, flush=True)
    # illegal static parameters must be rejected at elaboration
    bad = 0
    for param, value in [('BITS', 9), ('WIDTH', 0), ('WIDTH', 129),
                         ('HEIGHT', 0), ('HEIGHT', 129), ('PAD_MODE', 2),
                         ('PASSES', 0), ('PASSES', 17)]:
        bad += 1
        case = out / ('invalid_%s_%s' % (param, value)); case.mkdir()
        (case / 'tb.sv').write_text(
            f'module tb; canny_stream #(.{param}({value})) dut();'
            ' initial #1 $finish; endmodule\n')
        cmd = [iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp', 'tb.sv',
               str(src / 'stream_window.v'),
               str(src / 'stream_window_padded.v'),
               str(src / 'canny_stream.sv')]
        cp = subprocess.run(cmd, cwd=case, env=env, capture_output=True,
                            text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=case, env=env,
                            capture_output=True, text=True)
        (case / 'run.log').write_text(cp.stdout + cp.stderr + rp.stdout
                                      + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout, \
            (case, rp.stdout)
    (out / 'summary.json').write_text(json.dumps(dict(
        cases=results, illegal_static_parameters=bad, negative_runs=nmut,
        total_promoted_weak_pixels=total_promoted,
        total_diff_vs_exact_hysteresis=total_diff), indent=2))
    assert total_promoted > 0, "hysteresis linking never exercised"
    print(out)


if __name__ == '__main__':
    main()
