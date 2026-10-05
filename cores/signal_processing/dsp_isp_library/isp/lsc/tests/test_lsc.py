"""LSC regression driver.

Builds deterministic fixtures (input/expected/config/gains mem files), runs
the iverilog testbench tb_lsc.sv under three traffic epochs plus a reset
tail, runs mutation replays to prove checker sensitivity, checks illegal
config rejection, and measures corner-region error of the fixed-point path
against the float model. Real RTL only; no DUT data feeds expectations.
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
BASE = HERE.parent                      # isp/lsc
LIB = BASE.parents[1]                   # dsp_isp_library
ROOT = LIB.parents[1]                   # repo root
sys.path.insert(0, str(BASE / 'models'))
import model                            # noqa: E402
from gen_grid import make_table, flat_table, radial_gain, table_entries  # noqa: E402

DONE, ERR = 1, 2   # cfg status expectation bits


def marker(x, y, w, bits):
    return ((x == w - 1) << bits) | ((x == 0 and y == 0) << (bits + 1))


def build_case(cdir, name, W, H, bits, bayer, orders, gw, gh, gmax,
               table_specs, pixfn, invalid_cfgs, seed, flat_target=None):
    """Write the four fixture mems. Returns stats for summary.json.

    table_specs: list over frames; None -> unwritten buffer (unity), else
    (gains_int[4][gh][gw], gains_float[4][gh][gw]).  Frame f is driven by
    cfg f (commits at its SOF) and table f (written to the shadow buffer
    during frame f-1, swapped in at SOF f).
    """
    rng = random.Random(seed)
    NP = W * H
    NF = len(table_specs)
    kx = model.kexp((W + 1) >> 1 if bayer else W, gw)
    ky = model.kexp((H + 1) >> 1 if bayer else H, gh)
    cfgs = [model.Config(width=W, height=H, gw=gw, gh=gh, kx=kx, ky=ky,
                         bayer=bayer, order=orders[f % len(orders)],
                         gswap=1 if f else 0, gmax=gmax, bits=bits)
            for f in range(NF)]
    cfg_entries = []
    g_entries = []
    for f in range(NF):
        start = f * NP
        # cfg_0 before first pixel. cfg_1 early in frame 0. cfg_f (f>=2) is
        # offered late in frame f-2 so it must wait for the pending bundle of
        # cfg_{f-1} to commit at SOF(f-1) (cfg_ready backpressure coverage);
        # it then stays pending during f-1 and commits at SOF(f).
        trig = 0 if f == 0 else (4 if f == 1 else max(4, start - NP - 64))
        cfg_entries.append([trig, cfgs[f].pack(), DONE])
        if f >= 1 and table_specs[f] is not None:
            tab = table_specs[f][0]
            for e in table_entries(cfgs[f], tab):
                g_entries.append([start - NP + 2, e])
    # invalid config transactions, mid-frame, must be rejected (exp=ERR)
    for dt, bad in invalid_cfgs:
        cfg_entries.append([dt, bad, ERR])
    # one out-of-range gain write per case (row == gh) must raise g_error
    g_entries.append([NP // 2 + 3,
                      (1 << 27) | (0 << 25) | (gh << 21) | (0 << 16) | 0x1000])
    cfg_entries.sort(key=lambda e: e[0])
    g_entries.sort(key=lambda e: e[0])
    inputs, expected = [], []
    corner_err = flat_err = resid = 0
    for f in range(NF):
        cfg, spec = cfgs[f], table_specs[f]
        gains = gains_f = gfield = None
        if spec is not None:
            gains, gains_f = spec
            gfield = model.float_frame([[1.0] * W for _ in range(H)],
                                       cfg, gains_f)
        pix2d = [[pixfn(rng, x, y, f, gfield) for x in range(W)]
                 for y in range(H)]
        fx2d = model.fixed_frame(pix2d, cfg, gains)
        ff2d = model.float_frame(pix2d, cfg, gains_f)
        maxp = (1 << bits) - 1
        for y in range(H):
            for x in range(W):
                inputs.append(pix2d[y][x] | marker(x, y, W, bits))
                expected.append(fx2d[y][x] | marker(x, y, W, bits))
                # compare against the *saturated* float reference
                d = abs(fx2d[y][x] - min(maxp, round(ff2d[y][x])))
                corner = (x < 4 or y < 4 or x >= W - 4 or y >= H - 4)
                if corner:
                    corner_err = max(corner_err, d)
                flat_err = max(flat_err, d)
                assert d <= 2, (name, f, x, y, fx2d[y][x], ff2d[y][x])
                if flat_target is not None:
                    resid = max(resid, abs(fx2d[y][x] - flat_target))
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / 'input.mem').write_text(''.join(f'{v:x}\n' for v in inputs))
    (cdir / 'expected.mem').write_text(''.join(f'{v:x}\n' for v in expected))
    (cdir / 'config.mem').write_text(
        ''.join(f'{t:x}\n{w:x}\n{e:x}\n' for t, w, e in cfg_entries))
    (cdir / 'gains.mem').write_text(
        ''.join(f'{t:x}\n{e:x}\n' for t, e in g_entries))
    row = dict(name=name, frames=NF, NT=len(inputs), NC=len(cfg_entries),
               NG=len(g_entries), NP=NP, bits=bits,
               corner_err_lsb=corner_err, max_err_vs_satfloat=flat_err,
               kx=kx, ky=ky)
    if flat_target is not None:
        # flat-field correction: corrected output must return to uniform
        row['flat_residual_lsb'] = resid
        assert resid <= 4, (name, resid)
    return row


def bad_cfg(**kw):
    """Pack a config word that must be rejected; fields default sane."""
    base = dict(width=32, height=24, gw=9, gh=7, kx=2, ky=2, bayer=0,
                order=0, gswap=0, gmax=0xffff, bits=8)
    base.update(kw)
    w = (base['width'] | (base['height'] << 13) | (base['gw'] << 26)
         | (base['gh'] << 31) | (base['kx'] << 35) | (base['ky'] << 39)
         | (base['bayer'] << 43) | (base['order'] << 44)
         | (base['gswap'] << 46) | (base['gmax'] << 47))
    return w & ((1 << 63) - 1)


def vignette_input(target):
    """pixfn: feed the shading-corrupted flat field P/g(x,y); correcting it
    must return the uniform level target."""
    def f(rng, x, y, fi, gfield):
        if gfield is None:
            return target
        return max(0, min(255, int(round(target / gfield[y][x]))))
    return f


def textured_input(seed_base):
    def f(rng, x, y, fi, gfield):
        return (seed_base + x * 7 + y * 13 + fi * 31) & 0xff
    return f


def main():
    # model self-checks
    assert model.kexp(32, 9) == 2 and model.kexp(16, 9) == 1
    assert model.phase_of(0, 0, 0) == 0 and model.phase_of(1, 0, 0) == 3
    try:
        model.Config(width=32, height=24, gw=9, gh=7, kx=0, ky=0)
    except ValueError:
        pass
    else:
        raise AssertionError('model accepted non-covering grid')
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path, default=None)
    a = p.parse_args()
    out = a.output or BASE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = [BASE / 'rtl/lsc_stream.sv', BASE / 'models/model.py',
             BASE / 'models/gen_grid.py', HERE / 'tb_lsc.sv',
             HERE / 'test_lsc.py']
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

    cases = []
    # --- case A: flat-field correction, flat mode, alternating tables ------
    W, H, gw, gh = 32, 24, 9, 7
    cfgA = model.Config(width=W, height=H, gw=gw, gh=gh, kx=2, ky=2)
    tiltA = (1.0, 1.0, 1.0, 1.0)
    tabA_f = make_table(cfgA, lambda u, v, p: radial_gain(
        u, v, p, 1.0, 2.0, tiltA))
    # keep float copy for input synthesis / error stats
    tabA_ff = [[list(map(lambda g: g / model.UNITY, r)) for r in ph]
               for ph in tabA_f]
    tabB = flat_table(cfgA, 1.25)
    tabB_f = [[list(map(lambda g: g / model.UNITY, r)) for r in ph]
              for ph in tabB]
    specsA = [None, (tabA_f, tabA_ff), (tabB, tabB_f), (tabA_f, tabA_ff)]
    cases.append(dict(name='flat_w32h24', W=W, H=H, bits=8, bayer=0,
                      orders=[0], gw=gw, gh=gh, gmax=0xffff,
                      table_specs=specsA, pixfn=vignette_input(180),
                      flat_target=180, seed=1301,
                      invalid=[(300, bad_cfg(width=0)),
                               (400, bad_cfg(gw=1)),
                               (500, bad_cfg(gw=18)),
                               (600, bad_cfg(gh=14)),
                               (700, bad_cfg(kx=0))]))
    # --- case B: Bayer mode, all four orders, distinct phase tables --------
    cfgB = model.Config(width=W, height=H, gw=gw, gh=gh, kx=1, ky=1,
                        bayer=1)
    tiltB = (1.0, 1.06, 0.94, 1.12)
    specsB = [None]
    for f in range(1, 5):
        tab = make_table(cfgB, lambda u, v, p, k=f: radial_gain(
            u, v, p, 1.0, 1.6 + 0.2 * k, tiltB))
        tab_f = [[list(map(lambda g: g / model.UNITY, r)) for r in ph]
                 for ph in tab]
        specsB.append((tab, tab_f))
    cases.append(dict(name='bayer_w32h24', W=W, H=H, bits=8, bayer=1,
                      orders=[0, 1, 2, 3, 0], gw=gw, gh=gh, gmax=0xffff,
                      table_specs=specsB, pixfn=textured_input(37),
                      seed=1302,
                      invalid=[(250, bad_cfg(bayer=1, kx=0, ky=0)),
                               (900, bad_cfg(height=1))]))
    # --- case C: max grid 17x13, gain clamp, extreme gains -----------------
    W3, H3, gw3, gh3 = 33, 25, 17, 13
    cfgC = model.Config(width=W3, height=H3, gw=gw3, gh=gh3, kx=1, ky=1)
    tabC = make_table(cfgC, lambda u, v, p: radial_gain(u, v, p, 0.5, 8.0))
    tabC_f = [[list(map(lambda g: g / model.UNITY, r)) for r in ph]
              for ph in tabC]
    specsC = [None, (tabC, tabC_f), (tabC, tabC_f)]
    cases.append(dict(name='maxgrid_w33h25', W=W3, H=H3, bits=8, bayer=0,
                      orders=[0], gw=gw3, gh=gh3, gmax=0x2800,
                      table_specs=specsC, pixfn=textured_input(11),
                      seed=1303,
                      invalid=[(100, bad_cfg(width=W3, height=H3, gw=gw3,
                                             gh=gh3, kx=0, ky=1))]))
    # --- case D: tiny frame, 2x2 grid, Bayer ------------------------------
    W4, H4 = 8, 6
    cfgD = model.Config(width=W4, height=H4, gw=2, gh=2, kx=2, ky=1,
                        bayer=1)
    tabD = make_table(cfgD, lambda u, v, p: 1.0 + 0.5 * u + 0.25 * v
                      + 0.1 * p)
    tabD_f = [[list(map(lambda g: g / model.UNITY, r)) for r in ph]
              for ph in tabD]
    tabD2 = flat_table(cfgD, 2.0)
    tabD2_f = [[list(map(lambda g: g / model.UNITY, r)) for r in ph]
               for ph in tabD2]
    specsD = [None, (tabD, tabD_f), (tabD2, tabD2_f)]
    cases.append(dict(name='tiny_w8h6', W=W4, H=H4, bits=8, bayer=1,
                      orders=[0, 0, 2], gw=2, gh=2, gmax=0xffff,
                      table_specs=specsD, pixfn=textured_input(5),
                      seed=1304, invalid=[]))

    results = []
    for spec in cases:
        case = out / spec['name']
        stats = build_case(case, spec['name'], spec['W'], spec['H'],
                           spec['bits'], spec['bayer'], spec['orders'],
                           spec['gw'], spec['gh'], spec['gmax'],
                           spec['table_specs'], spec['pixfn'],
                           spec['invalid'], spec['seed'],
                           spec.get('flat_target'))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_lsc', '-o', 'sim.vvp',
               f'-Ptb_lsc.BITS={stats["bits"]}', f'-Ptb_lsc.NT={stats["NT"]}',
               f'-Ptb_lsc.NC={stats["NC"]}', f'-Ptb_lsc.NG={stats["NG"]}',
               f'-Ptb_lsc.NP={stats["NP"]}',
               str(src / 'lsc_stream.sv'), str(src / 'tb_lsc.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env,
                               capture_output=True, text=True, timeout=300)
            (case / f'{label}.log').write_text(
                '$ ' + ' '.join(map(str, command)) + '\n'
                + r.stdout + r.stderr)
            assert r.returncode == 0, (case, label, r.stdout[-2000:])
        assert 'PASS lsc' in r.stdout, r.stdout[-2000:]
        negs = []
        for mutation in ('data', 'sideband', 'order', 'count'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=300)
            (case / f'negative_{mutation}.log').write_text(r.stdout + r.stderr)
            ok = (r.returncode != 0 and
                  ('lsc mismatch' in r.stdout or
                   (mutation == 'count' and 'count timeout' in r.stdout)))
            assert ok, (case, mutation, r.stdout[-1000:])
            negs.append(mutation)
        stats.update(status='PASS', checker_negatives=negs)
        results.append(stats)
        print('PASS', spec['name'], stats, flush=True)

    # static illegal-parameter rejection
    for param, value in [('BITS', 9), ('GW_MAX', 1), ('GH_MAX', 20)]:
        c = out / f'invalid_{param}'
        c.mkdir()
        (c / 'tb.sv').write_text(
            f'module tb; lsc_stream #(.{param}({value})) dut();'
            ' initial #1 $finish; endmodule\n')
        cp = subprocess.run([iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
                             'tb.sv', str(src / 'lsc_stream.sv')],
                            cwd=c, env=env, capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=c, env=env,
                            capture_output=True, text=True)
        (c / 'run.log').write_text(cp.stdout + cp.stderr
                                   + rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout, rp.stdout

    (out / 'summary.json').write_text(json.dumps(dict(
        cases=results, illegal_static_parameters=3,
        model_self_tests='PASS',
        scope='RTL simulation only; synthesis/P&R/board pending'),
        indent=2))
    print(out)


if __name__ == '__main__':
    main()
