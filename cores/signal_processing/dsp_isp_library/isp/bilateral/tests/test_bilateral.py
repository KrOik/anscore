"""ISP-18 3x3 bilateral (edge-preserving denoise) regression driver.

Builds deterministic fixtures (input/expected/config/luts mem files), runs
the iverilog testbench tb_bilateral.sv under three traffic epochs plus a
reset tail, runs mutation replays to prove checker sensitivity, checks
illegal cfg / LUT-write rejection, and measures edge preservation, noise
suppression and fixed-vs-float LUT error.  Real RTL only; no DUT output
feeds expectations.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import random
import shutil
import statistics
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent                      # isp/bilateral
LIB = BASE.parents[1]                   # dsp_isp_library
ROOT = LIB.parents[1]                   # repo root
INFRA_WIN = LIB / 'infra' / 'window'
INFRA_DIV = LIB / 'infra' / 'fixedpoint' / 'rtl'
sys.path.insert(0, str(BASE / 'models'))
import model                            # noqa: E402

DONE, ERR = 1, 2   # cfg status expectation bits
RLN = model.RLN


def tables(bits):
    """Named table sets: (slut, rlut).  'ref' == RTL reset defaults."""
    return {
        'ref': (model.DEFAULT_SLUT, model.DEFAULT_RLUT),
        'sig8': (model.DEFAULT_SLUT, model.range_table(8.0, bits=8)),
        'zero_r': (model.DEFAULT_SLUT, [0] * RLN),
        'zero_s': ([0] * model.SLN, model.DEFAULT_RLUT),
        'garb': (model.DEFAULT_SLUT, [0x55] * RLN),
        'ref10': (model.spatial_table(1.0), model.range_table(100.0, bits=10)),
    }


def build_case(cdir, name, W, H, bits, frames, extra_cfg, extra_lt,
               wait_cfg=0, wait_lt=0, seed=1, edge_frame=None,
               flat_frame=None, float_cmp=True):
    """Emit the four fixture mems; return a stats row for summary.json.

    frames: list of dicts {pix: pix2d, table: key|'same', bypass: 0/1}.
    A table change emits a full shadow rewrite (trig early in the previous
    frame, or trig=0.. for frame 0 with wait_lt covering it) plus a cfg
    bundle with lswap=1 committed at that frame's SOF.  bypass is committed
    the same way.  extra_cfg/extra_lt are raw {trig, word/entry, exp} lists
    for illegal-transaction and shadow-only coverage.
    """
    TAB = tables(bits)
    NP = W * H
    NF = len(frames)
    cfg_entries = []
    lt_entries = []

    active = 'ref'
    cur_bypass = 0
    for f, fr in enumerate(frames):
        want = fr['table']
        lswap = want is not None and want != 'same' and want != active
        base = (f - 1) * NP if f else 0
        if lswap:
            slut, rlut = TAB[want]
            writes = ([model.lt_entry(a, d) for a, d in enumerate(rlut)]
                      + [model.lt_entry(RLN + k, d)
                         for k, d in enumerate(slut)])
            for j, e in enumerate(writes):
                # frame-0 preloads all use trig 0 (pixels are gated on
                # wait_lt; any trig>0 would deadlock the first pixel)
                lt_entries.append([0 if f == 0 else base + 2 + j, e])
            active = want
        bypass = fr['bypass']
        if lswap or bypass != cur_bypass:
            word = model.cfg_word(bypass=bypass, lswap=1 if lswap else 0)
            trig = 0 if f == 0 else base + NP - 16
            cfg_entries.append([trig, word, DONE])
            cur_bypass = bypass
        fr['use_table'] = active
    cfg_entries += extra_cfg
    lt_entries += extra_lt
    cfg_entries.sort(key=lambda e: e[0])
    lt_entries.sort(key=lambda e: e[0])

    inputs, expected = [], []
    maxerr = 0
    for f, fr in enumerate(frames):
        pix = fr['pix']
        slut, rlut = TAB[fr['use_table']]
        fx = model.fixed_frame(pix, slut, rlut, bits=bits,
                               bypass=fr['bypass'])
        if float_cmp and fr['use_table'] == 'ref' and not fr['bypass']:
            ff = model.float_frame(pix, pad=1,
                                   sigma_r=model.SIGMA_R_REF if bits == 8
                                   else 100.0)
            maxp = (1 << bits) - 1
            for y in range(H):
                for x in range(W):
                    d = abs(fx[y][x] - min(maxp, round(ff[y][x])))
                    maxerr = max(maxerr, d)
        for y in range(H):
            for x in range(W):
                inputs.append(pix[y][x] | model.marker(x, y, W, bits))
                expected.append(fx[y][x] | model.marker(x, y, W, bits))
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / 'input.mem').write_text(''.join(f'{v:x}\n' for v in inputs))
    (cdir / 'expected.mem').write_text(''.join(f'{v:x}\n' for v in expected))
    (cdir / 'config.mem').write_text(
        ''.join(f'{t:x}\n{w:x}\n{e:x}\n' for t, w, e in cfg_entries))
    (cdir / 'luts.mem').write_text(
        ''.join(f'{t:x}\n{e:x}\n' for t, e in lt_entries))

    row = dict(name=name, frames=NF, NT=len(inputs), NC=len(cfg_entries),
               NL=len(lt_entries), NP=NP, bits=bits,
               wait_cfg=wait_cfg, wait_lt=wait_lt,
               max_err_vs_satfloat=maxerr)
    # algorithm-quality metrics, computed on the bit-exact model (= DUT out)
    if edge_frame is not None:
        f = edge_frame
        fx = model.fixed_frame(frames[f]['pix'],
                               *TAB[frames[f]['use_table']], bits=bits)
        edge_x = W // 2
        dev = max(max(abs(fx[y][edge_x - 1] - frames[f]['pix'][y][edge_x - 1]),
                      abs(fx[y][edge_x] - frames[f]['pix'][y][edge_x]))
                  for y in range(2, H - 2))
        row['edge_deviation_lsb'] = dev
        assert dev <= 8, (name, dev)
    if flat_frame is not None:
        f = flat_frame
        fx = model.fixed_frame(frames[f]['pix'],
                               *TAB[frames[f]['use_table']], bits=bits)
        rin = [frames[f]['pix'][y][x]
               for y in range(2, H - 2) for x in range(2, W // 2 - 2)]
        rout = [fx[y][x]
                for y in range(2, H - 2) for x in range(2, W // 2 - 2)]
        vi, vo = statistics.pvariance(rin), statistics.pvariance(rout)
        row['flat_var_in'], row['flat_var_out'] = round(vi, 3), round(vo, 3)
        row['flat_var_ratio'] = round(vo / vi, 4)
        assert vo < 0.5 * vi, (name, vi, vo)
    return row


# ------------------------------------------------------------ pixel gens
def rng_pixels(rng, W, H, bits):
    return [[rng.randrange(1 << bits) for _ in range(W)] for _ in range(H)]


def step_pixels(rng, W, H, lo, hi, noise):
    return [[(lo if x < W // 2 else hi) + rng.randint(-noise, noise)
             for x in range(W)] for y in range(H)]


def flat_pixels(rng, W, H, level, noise):
    return [[level + rng.randint(-noise, noise) for x in range(W)]
            for y in range(H)]


def main():
    # model self-checks
    assert model.spatial_table(1.0) == [6, 9, 6, 9, 15, 9, 6, 9, 6]
    assert model.range_table(25.0)[0] == 255
    assert model.rne_div(5, 3) == 2 and model.rne_div(3, 2) == 2
    assert model.rne_div(7, 2) == 4      # 3.5 ties -> even
    assert model.rne_div(5, 2) == 2      # 2.5 ties -> even
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path, default=None)
    a = p.parse_args()
    out = a.output or BASE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = [BASE / 'rtl/bilateral_stream.sv',
             INFRA_WIN / 'stream_window.v',
             INFRA_WIN / 'stream_window_padded.v',
             INFRA_DIV / 'recip_div.sv',
             BASE / 'models/model.py', BASE / 'models/gen_luts.py',
             HERE / 'tb_bilateral.sv', HERE / 'test_bilateral.py']
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
    W, H = 32, 24
    NP = W * H
    rng = random.Random(1801)
    # --- case A: step edge preservation + flat noise suppression + bypass --
    fr = [
        dict(pix=step_pixels(rng, W, H, 80, 200, 4), table='ref', bypass=0),
        dict(pix=step_pixels(rng, W, H, 80, 200, 0), table='ref', bypass=0),
        dict(pix=step_pixels(rng, W, H, 80, 200, 4), table='ref', bypass=1),
        dict(pix=flat_pixels(rng, W, H, 128, 6), table='ref', bypass=0),
    ]
    cases.append(dict(name='step_w32h24', W=W, H=H, bits=8, frames=fr,
                      edge_frame=1, flat_frame=3, seed=1801,
                      # ERR cfg queued behind the pending bypass cfg proves
                      # cfg_ready backpressure (cfgwait>0) without consuming
                      # a commit slot (errors never pend).
                      extra_cfg=[(2 * NP - 8, model.cfg_word(rsvd=3), ERR)],
                      extra_lt=[(NP + 6, model.lt_entry(90, 0x12, 1)),
                                (NP + 10, model.lt_entry(RLN + 4, 0x30, 1))]))
    # --- case B: random frames + shadow isolation + committed garbage ------
    rng = random.Random(1802)
    fr = [dict(pix=rng_pixels(rng, W, H, 8), table='ref', bypass=0),
          dict(pix=rng_pixels(rng, W, H, 8), table='ref', bypass=0),
          dict(pix=rng_pixels(rng, W, H, 8), table='garb', bypass=0)]
    cases.append(dict(name='rand_w32h24', W=W, H=H, bits=8, frames=fr,
                      seed=1802, extra_cfg=[], extra_lt=[]))
    # --- case C: runtime sigma_r=8 reload ---------------------------------
    rng = random.Random(1803)
    fr = [dict(pix=rng_pixels(rng, W, H, 8), table='ref', bypass=0),
          dict(pix=step_pixels(rng, W, H, 60, 210, 5), table='sig8',
               bypass=0),
          dict(pix=rng_pixels(rng, W, H, 8), table='sig8', bypass=0)]
    cases.append(dict(name='reload_w32h24', W=W, H=H, bits=8, frames=fr,
                      edge_frame=1, seed=1803, extra_cfg=[], extra_lt=[]))
    # --- case D: zero-denominator passthrough, then restore ---------------
    rng = random.Random(1804)
    fr = [dict(pix=rng_pixels(rng, W, H, 8), table='ref', bypass=0),
          dict(pix=rng_pixels(rng, W, H, 8), table='zero_r', bypass=0),
          dict(pix=rng_pixels(rng, W, H, 8), table='ref', bypass=0)]
    cases.append(dict(name='zeroden_w32h24', W=W, H=H, bits=8, frames=fr,
                      seed=1804, extra_cfg=[], extra_lt=[]))
    # --- case E: tiny frame ------------------------------------------------
    rng = random.Random(1805)
    W5, H5 = 8, 6
    fr = [dict(pix=rng_pixels(rng, W5, H5, 8), table='ref', bypass=0),
          dict(pix=step_pixels(rng, W5, H5, 40, 220, 3), table='ref',
               bypass=0)]
    cases.append(dict(name='tiny_w8h6', W=W5, H=H5, bits=8, frames=fr,
                      seed=1805, extra_cfg=[], extra_lt=[]))
    # --- case F: 10-bit pixels, pre-frame table load ----------------------
    rng = random.Random(1806)
    W6, H6 = 16, 12
    fr = [dict(pix=rng_pixels(rng, W6, H6, 10), table='ref10', bypass=0),
          dict(pix=step_pixels(rng, W6, H6, 300, 800, 8), table='ref10',
               bypass=0)]
    cases.append(dict(name='bits10_w16h12', W=W6, H=H6, bits=10, frames=fr,
                      seed=1806, wait_cfg=1, wait_lt=73,
                      extra_cfg=[], extra_lt=[], float_cmp=True))

    results = []
    for spec in cases:
        case = out / spec['name']
        stats = build_case(case, spec['name'], spec['W'], spec['H'],
                           spec['bits'], spec['frames'],
                           spec.get('extra_cfg', []), spec.get('extra_lt', []),
                           wait_cfg=spec.get('wait_cfg', 0),
                           wait_lt=spec.get('wait_lt', 0),
                           seed=spec['seed'],
                           edge_frame=spec.get('edge_frame'),
                           flat_frame=spec.get('flat_frame'),
                           float_cmp=spec.get('float_cmp', True))
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_bilateral', '-o', 'sim.vvp',
               f'-Ptb_bilateral.BITS={stats["bits"]}',
               f'-Ptb_bilateral.NT={stats["NT"]}',
               f'-Ptb_bilateral.NC={stats["NC"]}',
               f'-Ptb_bilateral.NL={stats["NL"]}',
               f'-Ptb_bilateral.NP={stats["NP"]}',
               f'-Ptb_bilateral.WIDTH={spec["W"]}',
               f'-Ptb_bilateral.HEIGHT={spec["H"]}',
               f'-Ptb_bilateral.WCFG={stats["wait_cfg"]}',
               f'-Ptb_bilateral.WLT={stats["wait_lt"]}',
               str(src / 'stream_window.v'),
               str(src / 'stream_window_padded.v'),
               str(src / 'recip_div.sv'),
               str(src / 'bilateral_stream.sv'),
               str(src / 'tb_bilateral.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env,
                               capture_output=True, text=True, timeout=600)
            (case / f'{label}.log').write_text(
                '$ ' + ' '.join(map(str, command)) + '\n'
                + r.stdout + r.stderr)
            assert r.returncode == 0, (case, label, r.stdout[-2000:])
        assert 'PASS bilateral' in r.stdout, r.stdout[-2000:]
        negs = []
        for mutation in ('data', 'sideband', 'order', 'count'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=600)
            (case / f'negative_{mutation}.log').write_text(
                r.stdout + r.stderr)
            ok = (r.returncode != 0 and
                  ('bilateral mismatch' in r.stdout or
                   (mutation == 'count' and 'count timeout' in r.stdout)))
            assert ok, (case, mutation, r.stdout[-1000:])
            negs.append(mutation)
        stats.update(status='PASS', checker_negatives=negs)
        results.append(stats)
        print('PASS', spec['name'], stats, flush=True)

    # static illegal-parameter rejection
    for param, value in [('BITS', 9), ('PAD_MODE', 2), ('WR_AW', 9)]:
        c = out / f'invalid_{param}'
        c.mkdir()
        (c / 'tb.sv').write_text(
            f'module tb; bilateral_stream #(.{param}({value})) dut();'
            ' initial #1 $finish; endmodule\n')
        cp = subprocess.run([iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
                             'tb.sv', str(src / 'stream_window.v'),
                             str(src / 'stream_window_padded.v'),
                             str(src / 'recip_div.sv'),
                             str(src / 'bilateral_stream.sv')],
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
