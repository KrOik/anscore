"""ISP-17 frame-difference / background-model regression driver.

Builds deterministic multi-frame fixtures (input/expected/config mem
files), runs the iverilog testbench tb_framediff.sv under three traffic
epochs plus a reset tail, runs mutation replays to prove checker
sensitivity, checks illegal config rejection, and asserts the documented
background convergence bound on the reference model state.  Real RTL
only; no DUT output feeds expectations.
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
BASE = HERE.parent                      # isp/framediff
LIB = BASE.parents[1]                   # dsp_isp_library
ROOT = LIB.parents[1]                   # repo root
sys.path.insert(0, str(BASE / 'models'))
import model                            # noqa: E402

DONE, ERR = 1, 2   # cfg status expectation bits


def marker(x, y, w, bits):
    return ((x == w - 1) << bits) | ((x == 0 and y == 0) << (bits + 1))


def pack_cfg(width=8, height=8, mode=0, thresh=0, alpha=0, scn=128, scpol=0):
    """Raw config-word pack; does NOT validate (used for illegal entries)."""
    return (width | (height << 13) | (mode << 26) | (thresh << 28)
            | (alpha << 38) | (scn << 42) | (scpol << 50))


def uniform(w, h, v):
    return [[v] * w for _ in range(h)]


def rect(w, h, base, x0, y0, x1, y1, v):
    return [[v if x0 <= x <= x1 and y0 <= y <= y1 else base
             for x in range(w)] for y in range(h)]


def ramp(w, h, base, sx, sy, mod):
    return [[(base + x * sx + y * sy) % mod for x in range(w)]
            for y in range(h)]


def random_frame(w, h, rng, bits):
    return [[rng.randrange(1 << bits) for _ in range(w)] for _ in range(h)]


def build_case(cdir, spec):
    """Write input/expected/config mems; return stats for summary.json."""
    bits = spec['bits']
    maxw, maxh = spec['max']
    state = model.State(maxw, maxh)
    inputs, expected, cfg_entries = [], [], []
    nscn = 0
    events = []
    starts = []
    off = 0
    for cfg in spec['cfgs']:
        starts.append(off)
        off += cfg.width * cfg.height
    # a config bundle is emitted for frame 0 and for every frame whose
    # sched_cfg flag is set; omitted frames reuse the active configuration.
    sched = spec.get('sched_cfg', [True] * len(spec['frames']))
    for f, (cfg, fr) in enumerate(zip(spec['cfgs'], spec['frames'])):
        if sched[f]:
            # config for frame f is offered at the SOF of frame f-1: it
            # stays pending for the whole of f-1 and commits at SOF(f).
            # Frame 0's config is offered first.
            trig = 0 if f == 0 else starts[f - 1]
            cfg_entries.append([trig, cfg.pack(), DONE])
        out, event = model.run_frame(fr, cfg, state)
        if event:
            nscn += 1
        events.append(event)
        for y in range(cfg.height):
            for x in range(cfg.width):
                inputs.append(fr[y][x] | marker(x, y, cfg.width, bits))
                expected.append(out[y][x] | marker(x, y, cfg.width, bits))
    # illegal configs are offered *inside a pending window* (one pixel into
    # a frame, while the next frame's legal bundle is already pending) so
    # cfg_ready backpressure is deterministically exercised; they are
    # rejected with cfg_error and leave the pending bundle intact.
    for fidx, bad in spec['invalid']:
        npf = spec['cfgs'][fidx].width * spec['cfgs'][fidx].height
        trig = starts[fidx] + min(1, npf - 1)
        cfg_entries.append([trig, bad, ERR])
    cfg_entries.sort(key=lambda e: e[0])
    # mutation 'order' replays expected[OMUT] at index 0; pick the first
    # index whose expected word differs from expected[0].
    omut = next((i for i, e in enumerate(expected) if e != expected[0]), None)
    assert omut is not None, spec['name']
    np0 = spec['cfgs'][0].width * spec['cfgs'][0].height
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / 'input.mem').write_text(''.join(f'{v:x}\n' for v in inputs))
    (cdir / 'expected.mem').write_text(''.join(f'{v:x}\n' for v in expected))
    (cdir / 'config.mem').write_text(
        ''.join(f'{t:x}\n{w:x}\n{e:x}\n' for t, w, e in cfg_entries))
    row = dict(name=spec['name'], bits=bits, maxw=maxw, maxh=maxh,
               frames=len(spec['frames']), NT=len(inputs),
               NC=len(cfg_entries), NP=np0, OMUT=omut, NSCN=nscn,
               CFGWMIN=spec.get('cfgwmin', 1), events=events)
    # scene-change recovery: frames after the event until an all-zero mask
    # (only meaningful for mask modes 0/2)
    if nscn:
        offs = [0]
        for cfg in spec['cfgs']:
            offs.append(offs[-1] + cfg.width * cfg.height)
        rec = []
        for ei in [i for i, e in enumerate(events) if e]:
            n = 0
            for f in range(ei + 1, len(spec['frames'])):
                seg = expected[offs[f]:offs[f + 1]]
                n += 1
                if all((v & ((1 << bits) - 1)) == 0 for v in seg):
                    break
            rec.append(n)
        row['recovery_frames'] = rec
    return row, state


def main():
    # model self-checks
    assert model.residual_bound(0) == 0 and model.residual_bound(4) == 15
    assert model.frames_to_bound(200, 0) == 1
    assert 60 < model.frames_to_bound(200, 4) < 200
    st = model.State(4, 4)
    c = model.Config(2, 2, mode=0, thresh=10)
    out, ev = model.run_frame(uniform(2, 2, 100), c, st)
    assert out == [[0, 0], [0, 0]] and not ev and st.valid
    out, ev = model.run_frame(uniform(2, 2, 200), c, st)
    assert out == [[255, 255], [255, 255]]
    try:
        model.Config(0, 8)
    except ValueError:
        pass
    else:
        raise AssertionError('model accepted zero width')

    p = argparse.ArgumentParser()
    p.add_argument('--output', type=pathlib.Path, default=None)
    a = p.parse_args()
    out = a.output or BASE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = [BASE / 'rtl/framediff_stream.sv', BASE / 'models/model.py',
             HERE / 'tb_framediff.sv', HERE / 'test_framediff.py']
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
    # --- A: mode-0 frame diff, moving block, illegal config rejection ----
    W, H = 16, 12
    cfA = model.Config(W, H, mode=0, thresh=30, alpha=4, scn=128)
    cases.append(dict(
        name='fdiff_w16h12', bits=8, max=(16, 12),
        cfgs=[cfA] * 4,
        frames=[uniform(W, H, 40),
                rect(W, H, 40, 4, 3, 8, 7, 190),
                rect(W, H, 40, 7, 5, 11, 9, 190),
                uniform(W, H, 40)],
        invalid=[(0, pack_cfg(width=0)),
                 (0, pack_cfg(height=0)),
                 (1, pack_cfg(mode=3)),
                 (1, pack_cfg(scn=200)),
                 (2, pack_cfg(width=W + 1)),
                 (2, pack_cfg(height=H + 1))]))
    # --- B: threshold edges, diff = thresh-2..thresh+3 --------------------
    W, H = 8, 8
    rngB = random.Random(1702)
    cfB = model.Config(W, H, mode=0, thresh=64, scn=128)
    cases.append(dict(
        name='thresh_edge_w8h8', bits=8, max=(8, 8),
        cfgs=[cfB] * 3,
        frames=[uniform(W, H, 100),
                [[100 + 62 + x if x < 6 else 100 for x in range(W)]
                 for y in range(H)],
                random_frame(W, H, rngB, 8)],
        invalid=[(0, pack_cfg(mode=3)),
                 (1, pack_cfg(width=W + 1))]))
    # --- C: running-mean convergence, alpha = 4 ---------------------------
    W, H = 8, 8
    cfC = model.Config(W, H, mode=1, alpha=4, scn=128)
    nf_c = model.frames_to_bound(200, cfC.alpha) + 20
    cases.append(dict(
        name='bgconv_a4_w8h8', bits=8, max=(8, 8),
        cfgs=[cfC] * (nf_c + 1),
        frames=[ramp(W, H, 3, 37, 51, 251)] + [uniform(W, H, 200)] * nf_c,
        invalid=[(5, pack_cfg(height=0))],
        conv_target=200, conv_alpha=cfC.alpha))
    # --- C2: alpha = 0 instant adopt --------------------------------------
    cfC2 = model.Config(W, H, mode=1, alpha=0, scn=128)
    cases.append(dict(
        name='bgconv_a0_w8h8', bits=8, max=(8, 8),
        cfgs=[cfC2] * 3,
        frames=[uniform(W, H, 17), uniform(W, H, 213), uniform(W, H, 213)],
        invalid=[(0, pack_cfg(mode=3))],
        conv_target=213, conv_alpha=0))
    # --- D: motion mask vs converged background ---------------------------
    W, H = 16, 12
    cfD = model.Config(W, H, mode=2, thresh=40, alpha=2, scn=128)
    scn_img = rect(W, H, 100, 2, 2, 4, 4, 150)
    cases.append(dict(
        name='motion_w16h12', bits=8, max=(16, 12),
        cfgs=[cfD] * 18,
        frames=[scn_img] * 10
               + [rect(W, H, 100, 9, 6, 11, 8, 220)] * 4
               + [scn_img] * 4,
        invalid=[(2, pack_cfg(scn=129))]))
    # --- E: scene change with RESET policy --------------------------------
    cfE = model.Config(W, H, mode=2, thresh=40, alpha=2, scn=64, scpol=0)
    cases.append(dict(
        name='scnreset_w16h12', bits=8, max=(16, 12),
        cfgs=[cfE] * 10,
        frames=[uniform(W, H, 100)] * 6 + [uniform(W, H, 220)] * 4,
        invalid=[(1, pack_cfg(mode=3))]))
    # --- F: scene change with FAST_ADAPT policy ---------------------------
    cfF = model.Config(W, H, mode=2, thresh=40, alpha=2, scn=64, scpol=1)
    cases.append(dict(
        name='scnfa_w16h12', bits=8, max=(16, 12),
        cfgs=[cfF] * 10,
        frames=[uniform(W, H, 100)] * 6 + [uniform(W, H, 220)] * 4,
        invalid=[(1, pack_cfg(width=0))]))
    # --- G: runtime geometry switching, tiny frames -----------------------
    cfG2 = model.Config(2, 2, mode=0, thresh=20, scn=128)
    cfG4 = model.Config(4, 2, mode=0, thresh=20, scn=128)
    cases.append(dict(
        name='dimswitch_w4h4', bits=8, max=(4, 4),
        cfgs=[cfG2, cfG4, cfG2, cfG2],
        frames=[uniform(2, 2, 50), uniform(4, 2, 200),
                uniform(2, 2, 90), uniform(2, 2, 90)],
        invalid=[(0, pack_cfg(mode=3)),
                 (1, pack_cfg(scn=129))]))
    # --- H: 1x1 frames -- same-address RAM collision forwarding -----------
    # Single config commit (4 one-pixel frames cannot drain more bundles);
    # the illegal configs queue behind cfg0's pending window.
    cfH = model.Config(1, 1, mode=0, thresh=50, scn=128)
    cases.append(dict(
        name='w1h1', bits=8, max=(4, 4),
        cfgs=[cfH] * 4,
        frames=[[[0]], [[200]], [[200]], [[100]]],
        sched_cfg=[True, False, False, False],
        invalid=[(0, pack_cfg(height=0)),
                 (0, pack_cfg(mode=3))],
        # 1-pixel frames: the pending window collapses onto the commit
        # edge, so no cv&&!cr cycle is observable here; cfg_ready
        # backpressure is covered by the eight other cases.
        cfgwmin=0))
    # --- I: BITS=10, mode switch 0 -> 1 mid-sequence ----------------------
    W, H = 8, 8
    cfI0 = model.Config(W, H, mode=0, thresh=300, bits=10)
    cfI1 = model.Config(W, H, mode=1, alpha=1, scn=128, bits=10)
    cases.append(dict(
        name='bits10_w8h8', bits=10, max=(8, 8),
        cfgs=[cfI0, cfI0, cfI1, cfI1, cfI1, cfI1],
        frames=[uniform(W, H, 512), ramp(W, H, 512, 97, 61, 1024)]
               + [uniform(W, H, 700)] * 4,
        invalid=[(1, pack_cfg(mode=3))]))

    results = []
    for spec in cases:
        case = out / spec['name']
        stats, state = build_case(case, spec)
        # documented convergence bound checked on the reference state
        if 'conv_target' in spec:
            npf = spec['cfgs'][-1].width * spec['cfgs'][-1].height
            resid = max(abs(r - spec['conv_target'])
                        for r in state.ref[:npf])
            bound = model.residual_bound(spec['conv_alpha'])
            assert resid <= bound, (spec['name'], resid, bound)
            stats['bg_residual'] = resid
            stats['bg_bound'] = bound
        cmd = [iv, '-g2012', '-Wall', '-s', 'tb_framediff', '-o', 'sim.vvp',
               f'-Ptb_framediff.BITS={stats["bits"]}',
               f'-Ptb_framediff.MAXW={stats["maxw"]}',
               f'-Ptb_framediff.MAXH={stats["maxh"]}',
               f'-Ptb_framediff.NT={stats["NT"]}',
               f'-Ptb_framediff.NC={stats["NC"]}',
               f'-Ptb_framediff.NP={stats["NP"]}',
               f'-Ptb_framediff.NSCN={stats["NSCN"]}',
               f'-Ptb_framediff.OMUT={stats["OMUT"]}',
               f'-Ptb_framediff.CFGWMIN={stats["CFGWMIN"]}',
               str(src / 'framediff_stream.sv'), str(src / 'tb_framediff.sv')]
        for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
            r = subprocess.run(command, cwd=case, env=env,
                               capture_output=True, text=True, timeout=1200)
            (case / f'{label}.log').write_text(
                '$ ' + ' '.join(map(str, command)) + '\n'
                + r.stdout + r.stderr)
            assert r.returncode == 0, (case, label, r.stdout[-2000:])
        assert 'PASS framediff' in r.stdout, r.stdout[-2000:]
        negs = []
        for mutation in ('data', 'sideband', 'order', 'count'):
            r = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                               env=env, capture_output=True, text=True,
                               timeout=1200)
            (case / f'negative_{mutation}.log').write_text(
                r.stdout + r.stderr)
            ok = (r.returncode != 0 and
                  ('framediff mismatch' in r.stdout or
                   (mutation == 'count' and 'count timeout' in r.stdout)))
            assert ok, (case, mutation, r.stdout[-1000:])
            negs.append(mutation)
        stats.update(status='PASS', checker_negatives=negs)
        results.append(stats)
        print('PASS', spec['name'], stats, flush=True)

    # static illegal-parameter rejection
    static_rejects = [[('BITS', 9)], [('MAX_W', 0)], [('MAX_H', 0)],
                      [('MAX_W', 8192)], [('MAX_H', 8192)],
                      [('MAX_W', 256), ('MAX_H', 512)]]  # FP > 65536
    for plist in static_rejects:
        name = 'invalid_' + '_'.join(f'{k}{v}' for k, v in plist)
        c = out / name
        c.mkdir()
        assigns = ' '.join(f'.{k}({v}),' for k, v in plist)[:-1]
        (c / 'tb.sv').write_text(
            f'module tb; framediff_stream #({assigns}) dut();'
            ' initial #1 $finish; endmodule\n')
        cp = subprocess.run([iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
                             'tb.sv', str(src / 'framediff_stream.sv')],
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
