"""CCA regression driver.

Builds deterministic fixtures (input/expected/config mem files) from the
independent union-find model, runs the iverilog testbench tb_cca.sv under
three traffic epochs plus a reset tail, replays checker mutations, and checks
illegal config rejection.  Real RTL only; no DUT data feeds expectations.
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

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent                      # isp/cca
LIB = BASE.parents[1]                   # dsp_isp_library
ROOT = LIB.parents[1]                   # repo root
sys.path.insert(0, str(BASE / 'models'))
import model                            # noqa: E402

DONE, ERR = 1, 2   # cfg status expectation bits


def pack_cfg(w, h, conn8, xw, yw):
    return w | (h << (xw + 1)) | (conn8 << (xw + yw + 2))


def bad_cfg(xw, yw, **kw):
    """Config word that must be rejected; fields default sane."""
    base = dict(width=16, height=12, conn8=1)
    base.update(kw)
    return pack_cfg(base['width'], base['height'], base['conn8'], xw, yw)


def rand_frame(rng, w, h, density):
    return [[1 if rng.random() < density else 0 for _ in range(w)]
            for _ in range(h)]


def checkerboard(w, h):
    return [[(x + y) & 1 for x in range(w)] for y in range(h)]


def shapes_frame(w, h):
    """Two disjoint rectangles + one U merge + one diagonal-touch pair."""
    p = [[0] * w for _ in range(h)]
    for y in range(2, 6):
        for x in range(2, 6):
            p[y][x] = 1                       # rect A (4x4)
    for y in range(8, 12):
        for x in range(10, 15):
            p[y][x] = 1                       # rect B (4x5)
    # U shape: two bars joined by a bottom row (merge event)
    for y in range(2, 9):
        p[y][14] = 1
        p[y][17] = 1
    for x in range(14, 18):
        p[8][x] = 1
    # diagonal-only contact at (7,7)/(8,8): one region under 8-conn,
    # two under 4-conn
    p[7][7] = 1
    p[8][8] = 1
    return p


def diagonal(w, h):
    return [[1 if x == y else 0 for x in range(w)] for y in range(h)]


def build_case(cdir, name, frames, nl, eqt, invalid, seed, want_flags=None):
    """frames: list of (W,H,conn8,pix2d). One cfg commit per frame.

    want_flags: optional dict of summary flags that at least one frame must
    assert (e.g. {'ovf_lbl':1}) so regressions cannot silently miss the
    overflow paths.
    """
    rng = random.Random(seed)
    xw, yw, aw, sw, lblw = model.widths(256, 256, nl)
    rw = lblw + aw + 2 * sw + 2 * xw + 2 * yw
    inputs, expected, cfg_entries = [], [], []
    pos = 0
    got_flags = dict(ovf_lbl=0, ovf_eq=0)
    for f, (w, h, conn8, pix) in enumerate(frames):
        trig = 0 if f == 0 else max(0, pos - 6)
        cfg_entries.append([trig, pack_cfg(w, h, conn8, xw, yw), DONE])
        regions, summary = model.analyze(pix, conn8, nl=nl, eqt=eqt)
        got_flags['ovf_lbl'] |= summary['ovf_lbl']
        got_flags['ovf_eq'] |= summary['ovf_eq']
        for y in range(h):
            for x in range(w):
                fe = int(x == w - 1 and y == h - 1)
                inputs.append(pix[y][x] | ((x == w - 1) << 1)
                              | ((x == 0 and y == 0) << 2) | (fe << 3))
        for tu, tl, wd in model.pack_expected(regions, summary,
                                              xw, yw, aw, sw, lblw):
            expected.append(wd | (tl << rw) | (tu << (rw + 1)))
        pos += w * h
    for dt, bad in invalid:
        cfg_entries.append([dt, bad, ERR])
    cfg_entries.sort(key=lambda e: e[0])
    if want_flags:
        for k, v in want_flags.items():
            assert got_flags[k] == v, (name, k, got_flags)
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / 'input.mem').write_text(''.join(f'{v:x}\n' for v in inputs))
    (cdir / 'expected.mem').write_text(''.join(f'{v:x}\n' for v in expected))
    (cdir / 'config.mem').write_text(
        ''.join(f'{t:x}\n{w:x}\n{e:x}\n' for t, w, e in cfg_entries))
    return dict(name=name, frames=len(frames), NT=len(inputs),
                NE=len(expected), NC=len(cfg_entries), nl=nl, eqt=eqt,
                tw=frames[-1][0], th=frames[-1][1],
                regions=sum(len(model.analyze(p, c, nl=nl, eqt=eqt)[0])
                            for _w, _h, c, p in frames))


def main():
    # model self-checks: diagonal connectivity split, U merge, overflow
    regs, summ = model.analyze(diagonal(5, 5), conn8=1)
    assert len(regs) == 1 and regs[0][1] == 5        # 8-conn: one region
    regs, summ = model.analyze(diagonal(5, 5), conn8=0)
    assert len(regs) == 5 and summ['nalloc'] == 5    # 4-conn: five
    p = [[0] * 6 for _ in range(6)]
    for yy in range(1, 5):
        p[yy][1] = 1
        p[yy][4] = 1
    for xx in range(1, 5):
        p[4][xx] = 1
    regs, _ = model.analyze(p, conn8=1)              # U merge -> 1 region
    assert len(regs) == 1 and regs[0][1] == 10
    _, summ = model.analyze(checkerboard(9, 5), conn8=0, nl=8)
    assert summ['ovf_lbl'] == 1
    _, summ = model.analyze(checkerboard(10, 10), conn8=1, eqt=8)
    assert summ['ovf_eq'] == 1

    ap = argparse.ArgumentParser()
    ap.add_argument('--output', type=pathlib.Path, default=None)
    a = ap.parse_args()
    out = a.output or BASE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = [BASE / 'rtl/cca_stream.sv', BASE / 'models/model.py',
             HERE / 'tb_cca.sv', HERE / 'test_cca.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])

    rng = random.Random(20260929)
    cases = []
    # --- case A: random binary frames, conn8/conn4 mix ---------------------
    frA = [(16, 12, 1, rand_frame(rng, 16, 12, 0.35)),
           (16, 12, 0, rand_frame(rng, 16, 12, 0.30)),
           (24, 9, 1, rand_frame(rng, 24, 9, 0.60)),
           (16, 12, 0, rand_frame(rng, 16, 12, 0.50))]
    cases.append(dict(name='rand4_w16h12', frames=frA, nl=128, eqt=256,
                      seed=101, invalid=[
                          (300, bad_cfg(8, 8, width=0)),
                          (400, bad_cfg(8, 8, width=2)),
                          (500, bad_cfg(8, 8, width=257)),
                          (600, bad_cfg(8, 8, height=0)),
                          (700, bad_cfg(8, 8, height=300))]))
    # --- case B: known shapes incl 4v8 diagonal difference -----------------
    frB = [(20, 14, 1, shapes_frame(20, 14)),
           (20, 14, 0, shapes_frame(20, 14)),
           (10, 10, 1, diagonal(10, 10)),
           (10, 10, 0, diagonal(10, 10))]
    cases.append(dict(name='shapes_w20h14', frames=frB, nl=128, eqt=256,
                      seed=102, invalid=[(277, bad_cfg(8, 8, conn8=0,
                                                     width=1)),
                                         (557, bad_cfg(8, 8, height=0))]))
    # --- case C: label budget overflow (NL=8, isolated checkerboard) -------
    frC = [(9, 5, 0, checkerboard(9, 5)),
           (8, 4, 0, checkerboard(8, 4))]
    cases.append(dict(name='ovflbl_w9h5', frames=frC, nl=8, eqt=256,
                      seed=103, invalid=[(41, bad_cfg(8, 8, height=0))],
                      want_flags={'ovf_lbl': 1}))
    # --- case D: merge-event budget overflow (EQT=8, 8-conn checkerboard) --
    frD = [(10, 10, 1, checkerboard(10, 10)),
           (6, 6, 1, checkerboard(6, 6))]
    cases.append(dict(name='ovfeq_w10h10', frames=frD, nl=128, eqt=8,
                      seed=104, invalid=[(97, bad_cfg(8, 8, width=0))],
                      want_flags={'ovf_eq': 1}))
    # --- case E: tiny frame, minimum legal width ---------------------------
    frE = [(3, 4, 1, rand_frame(rng, 3, 4, 0.55)),
           (3, 4, 0, rand_frame(rng, 3, 4, 0.55)),
           (5, 3, 1, rand_frame(rng, 5, 3, 0.5))]
    cases.append(dict(name='tiny_w3h4', frames=frE, nl=128, eqt=256,
                      seed=105, invalid=[(9, bad_cfg(8, 8, width=2)),
                                         (20, bad_cfg(8, 8, conn8=1,
                                                      height=0))]))

    results = []
    for spec in cases:
        case = out / spec['name']
        stats = build_case(case, spec['name'], spec['frames'], spec['nl'],
                           spec['eqt'], spec['invalid'], spec['seed'],
                           spec.get('want_flags'))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_cca', '-o', 'sim.vvp',
               f'-Ptb_cca.NT={stats["NT"]}', f'-Ptb_cca.NE={stats["NE"]}',
               f'-Ptb_cca.NC={stats["NC"]}', f'-Ptb_cca.W_MAX=256',
               f'-Ptb_cca.H_MAX=256', f'-Ptb_cca.NL={stats["nl"]}',
               f'-Ptb_cca.EQT={stats["eqt"]}',
               f'-Ptb_cca.TW={stats["tw"]}', f'-Ptb_cca.TH={stats["th"]}',
               str(src / 'cca_stream.sv'), str(src / 'tb_cca.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env,
                               capture_output=True, text=True, timeout=600)
            (case / f'{label}.log').write_text(
                '$ ' + ' '.join(map(str, command)) + '\n'
                + r.stdout + r.stderr)
            assert r.returncode == 0, (case, label, r.stdout[-2000:],
                                       r.stderr[-2000:])
        assert 'PASS cca' in r.stdout, r.stdout[-2000:]
        negs = []
        for mutation in ('data', 'sideband', 'order', 'count'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=600)
            (case / f'negative_{mutation}.log').write_text(
                r.stdout + r.stderr)
            ok = (r.returncode != 0 and
                  ('cca mismatch' in r.stdout or
                   (mutation == 'count' and 'count timeout' in r.stdout)))
            assert ok, (case, mutation, r.stdout[-1000:])
            negs.append(mutation)
        stats.update(status='PASS', checker_negatives=negs)
        results.append(stats)
        print('PASS', spec['name'], stats, flush=True)

    # static illegal-parameter rejection
    for param, value in [('NL', 1), ('NL', 300), ('W_MAX', 2), ('EQT', 0)]:
        c = out / f'invalid_{param}_{value}'
        c.mkdir()
        (c / 'tb.sv').write_text(
            f'module tb; cca_stream #(.{param}({value})) dut();'
            ' initial #1 $finish; endmodule\n')
        cp = subprocess.run([iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
                             'tb.sv', str(src / 'cca_stream.sv')],
                            cwd=c, env=env, capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=c, env=env,
                            capture_output=True, text=True)
        (c / 'run.log').write_text(cp.stdout + cp.stderr
                                   + rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout, rp.stdout

    (out / 'summary.json').write_text(json.dumps(dict(
        cases=results, illegal_static_parameters=4,
        model_self_tests='PASS',
        scope='RTL simulation only; synthesis/P&R/board pending'),
        indent=2))
    print(out)


if __name__ == '__main__':
    main()
