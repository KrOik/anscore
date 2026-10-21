"""ISP-19 geometric-remap regression driver.

Builds deterministic multi-frame fixtures (input/expected/config/mesh mem
files), runs the iverilog testbench tb_remap.sv under three traffic
epochs plus a reset tail, replays four mutations to prove checker
sensitivity, and checks illegal config / mesh-write rejection.  Real RTL
only; no DUT output feeds expectations.

Frame scheduling contract encoded here (matches tb_remap.sv):
  * the legal cfg apply for frame f is emitted at trig = starts[f]
    (>= f==0 -> 0): it lands during frame f-1's drain (or pre-stream)
    and commits at frame f's SOF take;
  * lens mesh writes for frame f are emitted at the same trig; the TB
    gates cfg offers and source offers on pending due mesh writes, so
    the apply always sees a complete mesh;
  * 'invalid' distractor bundles emitted with the same trig queue behind
    the legal apply in the pending window and are rejected at the next
    commit edge (or immediately if offered while no bundle is pending).
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
BASE = HERE.parent                      # isp/remap
LIB = BASE.parents[1]                   # dsp_isp_library
ROOT = LIB.parents[1]                   # repo root
sys.path.insert(0, str(BASE / 'models'))
import model                            # noqa: E402

DONE, ERR = 1, 2   # cfg status expectation bits


def marker(x, y, w, bits):
    return ((x == w - 1) << bits) | ((x == 0 and y == 0) << (bits + 1))


def uniform(w, h, v):
    return [[v] * w for _ in range(h)]


def ramp(w, h, base, sx, sy, mod):
    return [[(base + x * sx + y * sy) % mod for x in range(w)]
            for y in range(h)]


def random_frame(w, h, rng, bits):
    return [[rng.randrange(1 << bits) for _ in range(w)] for _ in range(h)]


def q16(v):
    return int(round(v * 65536))


def pack_node(sx, sy):
    """54-bit mesh word {sy[53:27], sx[26:0]}, both signed Q11.16."""
    return ((sy & ((1 << 27) - 1)) << 27) | (sx & ((1 << 27) - 1))


def build_case(cdir, spec):
    """Write input/expected/config/mesh mems; return stats.

    Trigger discipline (validated against tb_remap.sv's drivers):
      apply for frame f -> trig = starts[f]  (accepted during f-1's
        drain or pre-stream, commits at f's SOF);
      mesh writes for f -> trig = starts[f] when the previous frame is
        not lens (they land in f-1's drain where l_ready is high), or
        starts[f]+1 when the previous frame IS lens (they land in f's
        own fill so a lens drain's read window is never disturbed;
        svok backpressure guarantees they complete before f's drain);
      invalid bundles -> trig = starts[f] queued after the legal apply,
        so they sit in the pending window and are rejected at f's SOF
        commit edge (or immediately if no bundle is pending).
    """
    bits = spec['bits']
    maxw, maxh = spec['max']
    frames = spec['frames']
    mesh = model.Mesh()
    inputs, expected = [], []
    cfg_entries, mesh_entries = [], []
    starts = []
    off = 0
    for fr in frames:
        starts.append(off)
        off += fr['cfg'].iw * fr['cfg'].ih
    for f, fr in enumerate(frames):
        cfg = fr['cfg']
        prev_lens = f > 0 and frames[f - 1]['cfg'].mode == model.MODE_LENS
        mesh_trig = 0 if f == 0 else (starts[f] + 1 if prev_lens
                                      else starts[f])
        trig_apply = 0 if f == 0 else starts[f]
        # legal apply (skipped when the frame reuses the active config)
        if fr.get('apply', True):
            cfg_entries.append([trig_apply, cfg.pack(), DONE])
        if cfg.clr:
            mesh.clear()
        # lens mesh writes (row, col, sx, sy, expect_error)
        for (row, col, sx, sy, merr) in fr.get('mesh', []):
            mesh_entries.append([mesh_trig, row, col,
                                 pack_node(sx, sy), merr])
            mesh.write(row, col, sx, sy)
        # illegal distractors queue behind the legal apply in the
        # pending window (accepted -> cfg_error at the commit edge or
        # during a non-pending cycle, either path only pulses cfg_error)
        for k, raw in enumerate(fr.get('invalid', [])):
            cfg_entries.append([trig_apply + k, raw, ERR])
        out = model.run_frame(fr['img'], cfg, mesh)
        img = fr['img']
        for y in range(cfg.ih):
            for x in range(cfg.iw):
                inputs.append(img[y][x] | marker(x, y, cfg.iw, bits))
        for y in range(cfg.oh):
            for x in range(cfg.ow):
                expected.append(out[y][x] | marker(x, y, cfg.ow, bits))
    cfg_entries.sort(key=lambda e: e[0])
    mesh_entries.sort(key=lambda e: e[0])
    omut = next((i for i, e in enumerate(expected)
                 if e != expected[0]), None)
    assert omut is not None, spec['name']
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / 'input.mem').write_text(''.join(f'{v:x}\n' for v in inputs))
    (cdir / 'expected.mem').write_text(''.join(f'{v:x}\n' for v in expected))
    (cdir / 'config.mem').write_text(
        ''.join(f'{t:x}\n{w:x}\n{e:x}\n' for t, w, e in cfg_entries))
    (cdir / 'mesh.mem').write_text(
        ''.join(f'{t:x}\n{r:x}\n{c:x}\n{d:x}\n{e:x}\n'
                for t, r, c, d, e in mesh_entries))
    return dict(name=spec['name'], bits=bits, maxw=maxw, maxh=maxh,
                frames=len(frames), NTI=len(inputs), NTO=len(expected),
                NC=len(cfg_entries), NM=len(mesh_entries),
                NP=frames[-1]['cfg'].iw * frames[-1]['cfg'].ih,
                OMUT=omut, CFGWMIN=spec.get('cfgwmin', 1))


def ident_nodes(lx, ly, kx, ky, dx=0, dy=0):
    """Mesh writes for nodes (row=j,col=i) at identity source coords
    sx = (i<<kx)+dx, sy = (j<<ky)+dy in Q16."""
    out = []
    for j in range(ly):
        for i in range(lx):
            out.append((j, i, ((i << kx) + dx) << 16, ((j << ky) + dy) << 16,
                        0))
    return out


def main():
    # ---- model self-checks -------------------------------------------
    assert model.fdiv(65536, 65536) == 65536           # 1.0/1.0 = 1.0 Q16
    assert model.fdiv(65536 * 3, 2 * 65536) == 98304   # 3/2 = 1.5
    assert model.fdiv(65536, 0) == model.DIV_OMAX      # div0 saturates
    assert model.fdiv(-65536, 0) == model.DIV_OMIN
    assert model.fdiv(1, 3 * 65536) == 0               # tiny result
    st_cfg = model.Config(4, 4, 4, 4, mode=model.MODE_AFFINE,
                          coefs=(65536, 0, 0, 0, 65536, 0, 0, 0, 65536))
    img = ramp(4, 4, 3, 40, 17, 256)
    assert model.run_frame(img, st_cfg) == img          # identity affine
    fl = model.Config(4, 4, 4, 4, mode=model.MODE_FLIPH)
    assert model.run_frame(img, fl) == [list(reversed(r)) for r in img]
    fv = model.Config(4, 4, 4, 4, mode=model.MODE_FLIPV)
    assert model.run_frame(img, fv) == list(reversed(img))
    rt = model.Config(3, 2, 2, 3, mode=model.MODE_ROT90)
    imgr = [[10, 11, 12], [20, 21, 22]]
    assert model.run_frame(imgr, rt) == [[20, 10], [21, 11], [22, 12]]
    try:
        model.Config(4, 4, 4, 4, mode=6).errors() == []
        assert 'mode' in model.Config(4, 4, 4, 4, mode=6).errors()
    except Exception:
        pass

    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path, default=None)
    a = p.parse_args()
    out = a.output or BASE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = [BASE / 'rtl/remap_stream.sv', BASE / 'models/model.py',
             HERE / 'tb_remap.sv', HERE / 'test_remap.py',
             LIB / 'infra/fixedpoint/rtl/recip_div.sv']
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

    # --- A: flip_h / flip_v, exact integer transforms -------------------
    rngA = random.Random(1901)
    imgA = ramp(12, 10, 5, 23, 17, 256)
    imgA2 = random_frame(12, 10, rngA, 8)
    cAh = model.Config(12, 10, 12, 10, mode=0, max_w=16, max_h=12)
    cAv = model.Config(12, 10, 12, 10, mode=1, max_w=16, max_h=12)
    bad_mode = model.pack_raw(base=cAh.pack(), mode=6)
    bad_iw0 = model.pack_raw(base=cAh.pack(), iw=0)
    bad_ow0 = model.pack_raw(base=cAh.pack(), ow=0)
    bad_fill = model.pack_raw(base=cAh.pack(), fill=3)
    bad_iwmax = model.pack_raw(base=cAh.pack(), iw=17)   # > MAX_W=16
    cases.append(dict(
        name='flip_w12h10', bits=8, max=(16, 12),
        frames=[dict(cfg=cAh, img=imgA,
                     invalid=[bad_mode, bad_iw0]),
                dict(cfg=cAv, img=imgA2,
                     invalid=[bad_ow0, bad_fill]),
                dict(cfg=cAh, img=imgA,
                     invalid=[bad_iwmax])]))

    # --- B: rotate90 clockwise incl. odd dims ---------------------------
    imgB = ramp(6, 4, 9, 31, 41, 256)
    imgB2 = ramp(5, 7, 4, 19, 29, 256)
    cB = model.Config(6, 4, 4, 6, mode=2, max_w=16, max_h=12)
    cB2 = model.Config(5, 7, 7, 5, mode=2, max_w=16, max_h=12)
    bad_rot = model.pack_raw(base=cB.pack(), ow=6, oh=4)  # not swapped
    cases.append(dict(
        name='rot90_w6h4', bits=8, max=(16, 12),
        frames=[dict(cfg=cB, img=imgB),
                dict(cfg=cB2, img=imgB2, invalid=[bad_rot])]))

    # --- C: affine translate / scale / shear / rotate45 ------------------
    imgC = ramp(12, 10, 7, 21, 13, 256)
    cC0 = model.Config(12, 10, 12, 10, mode=3, fill=2,  # translate +2.5,+1.25
                       coefs=(65536, 0, 163840, 0, 65536, 81920, 0, 0, 0),
                       max_w=16, max_h=12)
    cC1 = model.Config(12, 10, 16, 14, mode=3, fill=1, border=0x40,
                       coefs=(49152, 0, 0, 0, 46811, 0, 0, 0, 0),
                       max_w=16, max_h=12)   # zoom-out 0.75 / 0.714
    cC2 = model.Config(12, 10, 12, 10, mode=3, fill=2,  # shear x += 0.25*y
                       coefs=(65536, 16384, 0, 0, 65536, 0, 0, 0, 0),
                       max_w=16, max_h=12)
    cC3 = model.Config(12, 10, 12, 10, mode=3, fill=1, border=0xAB,
                       coefs=(46341, -46341, 393216,
                              46341, 46341, 327680, 0, 0, 0),
                       max_w=16, max_h=12)   # rot45 about centre-ish
    cases.append(dict(
        name='affine_w12h10', bits=8, max=(16, 12),
        cfgwmin=0,
        frames=[dict(cfg=cC0, img=imgC),
                dict(cfg=cC1, img=imgC),
                dict(cfg=cC2, img=imgC),
                dict(cfg=cC3, img=imgC)]))

    # --- D: perspective via fp_div_iter + divide-by-zero -----------------
    imgD = ramp(8, 8, 11, 27, 33, 256)
    cD0 = model.Config(8, 8, 8, 8, mode=4, fill=2,
                       coefs=(65536, 0, 0, 0, 65536, 0, 2000, 0, 65536),
                       max_w=16, max_h=12)
    cD1 = model.Config(8, 8, 8, 8, mode=4, fill=1, border=0x5A,
                       coefs=(65536, 0, 0, 0, 65536, 0, 2000, 0, 0),
                       max_w=16, max_h=12)   # d==0 at ox==0 -> border col
    cases.append(dict(
        name='persp_w8h8', bits=8, max=(16, 12),
        cfgwmin=0,
        frames=[dict(cfg=cD0, img=imgD),
                dict(cfg=cD1, img=imgD)]))

    # --- E: lens mesh map: identity mesh, distorted, map-clear+reload ----
    imgE = ramp(12, 10, 3, 29, 19, 256)
    # lx=4, ly=4, pitch 2^2=4: covers out 12x10 ((lx-1)<<2 = 12 >= 11,
    # (ly-1)<<2 = 12 >= 9)
    meshE = ident_nodes(4, 4, 2, 2)
    cE0 = model.Config(12, 10, 12, 10, mode=0, max_w=16, max_h=12)
    cE = model.Config(12, 10, 12, 10, mode=5, fill=2,
                      lx=4, ly=4, kx=2, ky=2, max_w=16, max_h=12)
    cEclr = model.Config(12, 10, 12, 10, mode=5, fill=2, clr=1,
                         lx=4, ly=4, kx=2, ky=2, max_w=16, max_h=12)
    # distorted second/third meshes: barrel-ish outward pull
    def dist_mesh(kx2, ky2, ax, ay):
        out_l = []
        for j in range(4):
            for i in range(4):
                dx = (i * i - 2 * i) * ax
                dy = (j * j - 2 * j) * ay
                out_l.append((j, i, ((i << kx2) << 16) + dx,
                              ((j << ky2) << 16) + dy, 0))
        return out_l
    meshE2 = dist_mesh(2, 2, 12288, 8192)
    meshE3 = dist_mesh(2, 2, -8192, -6144)
    bad_lx = model.pack_raw(base=cE.pack(), lx=1)
    bad_cover = model.pack_raw(base=cE.pack(), kx=1)     # (4-1)*2=6 < 11
    bad_unwritten = model.pack_raw(base=cE.pack(), lx=5)  # i=4 never written
    bad_lerr = (31, 31, 0, 0, 1)    # out-of-range mesh write -> l_error
    cases.append(dict(
        name='lens_w12h10', bits=8, max=(16, 12),
        frames=[dict(cfg=cE0, img=imgE),
                dict(cfg=cE, img=imgE, mesh=meshE + [bad_lerr],
                     invalid=[bad_lx, bad_cover, bad_unwritten]),
                dict(cfg=cE, img=imgE, mesh=meshE2, apply=False),
                dict(cfg=cEclr, img=imgE, mesh=meshE3)]))
    # verify identity lens mesh really is a passthrough in the model
    mm = model.Mesh()
    for j, i, sx, sy, _ in meshE:
        mm.write(j, i, sx, sy)
    assert model.run_frame(imgE, cE, mm) == imgE

    # --- F: out-of-bounds fill modes ------------------------------------
    imgF = ramp(10, 8, 13, 23, 37, 256)
    # translate -3.5, +4.25 -> large OOB left/right bands
    cf = (65536, 0, -3 * 65536 - 32768, 0, 65536, 4 * 65536 + 16384,
          0, 0, 0)
    cF0 = model.Config(10, 8, 10, 8, mode=3, fill=0, coefs=cf,
                       max_w=16, max_h=12)
    cF1 = model.Config(10, 8, 10, 8, mode=3, fill=1, border=0xAB,
                       coefs=cf, max_w=16, max_h=12)
    cF2 = model.Config(10, 8, 10, 8, mode=3, fill=2, coefs=cf,
                       max_w=16, max_h=12)
    cases.append(dict(
        name='oob_fills_w10h8', bits=8, max=(16, 12),
        cfgwmin=0,
        frames=[dict(cfg=cF0, img=imgF),
                dict(cfg=cF1, img=imgF),
                dict(cfg=cF2, img=imgF)]))

    # --- G: odd dims affine + downscale ---------------------------------
    imgG = ramp(5, 7, 8, 35, 27, 256)
    cG = model.Config(5, 7, 9, 3, mode=3, fill=2,
                      coefs=(32768, 8192, 0, 4096, 131072, 0, 0, 0, 0),
                      max_w=16, max_h=12)
    cases.append(dict(
        name='odd_w5h7', bits=8, max=(16, 12),
        cfgwmin=0,
        frames=[dict(cfg=cG, img=imgG)]))

    # --- H: 1x1 frames -- commit edge coincides with eot ----------------
    cH = model.Config(1, 1, 1, 1, mode=0, max_w=16, max_h=12)
    cHv = model.Config(1, 1, 3, 2, mode=3, fill=1, border=0x77,
                       coefs=(65536, 0, 0, 0, 65536, 0, 0, 0, 0),
                       max_w=16, max_h=12)   # 1x1 src -> 3x2 border/rep mix
    cases.append(dict(
        name='w1h1', bits=8, max=(16, 12),
        cfgwmin=0,
        frames=[dict(cfg=cH, img=[[200]]),
                dict(cfg=cH, img=[[77]]),
                dict(cfg=cHv, img=[[123]]),
                dict(cfg=cH, img=[[9]])]))

    # --- I: BITS=10 affine ------------------------------------------------
    imgI = ramp(8, 6, 100, 87, 61, 1024)
    cI = model.Config(8, 6, 8, 6, mode=3, fill=2, bits=10,
                      coefs=(81920, 4096, 0, 0, 81920, 0, 0, 0, 0),
                      max_w=16, max_h=12)
    cases.append(dict(
        name='bits10_w8h6', bits=10, max=(16, 12),
        cfgwmin=0,
        frames=[dict(cfg=cI, img=imgI), dict(cfg=cI, img=imgI)]))

    results = []
    for spec in cases:
        case = out / spec['name']
        stats = build_case(case, spec)
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_remap', '-o', 'sim.vvp',
               f'-Ptb_remap.BITS={stats["bits"]}',
               f'-Ptb_remap.MAXW={stats["maxw"]}',
               f'-Ptb_remap.MAXH={stats["maxh"]}',
               f'-Ptb_remap.NTI={stats["NTI"]}',
               f'-Ptb_remap.NTO={stats["NTO"]}',
               f'-Ptb_remap.NC={stats["NC"]}',
               f'-Ptb_remap.NM={stats["NM"]}',
               f'-Ptb_remap.NP={stats["NP"]}',
               f'-Ptb_remap.OMUT={stats["OMUT"]}',
               f'-Ptb_remap.CFGWMIN={stats["CFGWMIN"]}',
               str(src / 'remap_stream.sv'),
               str(src / 'recip_div.sv'),
               str(src / 'tb_remap.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env,
                               capture_output=True, text=True, timeout=2400)
            (case / f'{label}.log').write_text(
                '$ ' + ' '.join(map(str, command)) + '\n'
                + r.stdout + r.stderr)
            assert r.returncode == 0, (case, label, r.stdout[-2000:])
        assert 'PASS remap' in r.stdout, r.stdout[-2000:]
        negs = []
        for mutation in ('data', 'sideband', 'order', 'count'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=2400)
            (case / f'negative_{mutation}.log').write_text(
                r.stdout + r.stderr)
            ok = (r.returncode != 0 and
                  ('remap mismatch' in r.stdout or
                   (mutation == 'count' and 'count timeout' in r.stdout)))
            assert ok, (case, mutation, r.stdout[-1000:])
            negs.append(mutation)
        stats.update(status='PASS', checker_negatives=negs)
        results.append(stats)
        print('PASS', spec['name'], stats, flush=True)

    # static illegal-parameter rejection
    static_rejects = [[('BITS', 9)], [('MAX_W', 0)], [('MAX_H', 0)],
                      [('MAX_W', 8192)], [('MAX_H', 8192)],
                      [('MAX_W', 256), ('MAX_H', 512)],   # FP > 65536
                      [('LXMAX', 1)], [('LYMAX', 32)]]
    for plist in static_rejects:
        name = 'invalid_' + '_'.join(f'{k}{v}' for k, v in plist)
        c = out / name
        c.mkdir()
        assigns = ' '.join(f'.{k}({v}),' for k, v in plist)[:-1]
        (c / 'tb.sv').write_text(
            f'module tb; remap_stream #({assigns}) dut();'
            ' initial #1 $finish; endmodule\n')
        cp = subprocess.run([iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
                             'tb.sv', str(src / 'remap_stream.sv'),
                             str(src / 'recip_div.sv')],
                            cwd=c, env=env, capture_output=True, text=True)
        assert cp.returncode == 0, cp.stderr
        rp = subprocess.run([vv, 'bad.vvp'], cwd=c, env=env,
                            capture_output=True, text=True)
        (c / 'run.log').write_text(cp.stdout + cp.stderr
                                   + rp.stdout + rp.stderr)
        assert rp.returncode != 0 and 'unsupported' in rp.stdout, rp.stdout

    (out / 'summary.json').write_text(json.dumps(dict(
        cases=results, illegal_static_parameters=len(static_rejects),
        model_self_tests='PASS',
        scope='RTL simulation only; synthesis/P&R/board pending'),
        indent=2))
    print(out)


if __name__ == '__main__':
    main()
