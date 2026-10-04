"""ISP-14 RTL regression: snapshot ccm_stream RTL, generate frames plus a
shadow-write/commit script (legal, illegal and mid-frame commits), run real
iverilog/vvp with randomized handshake, mutations and reset epochs.

Pure stdlib.  Expected outputs come only from models/model.py.
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
from model import (Config, Shadow, mpx, packpix, pixel, simulate,
                   writes_for, ctrl_word, identity_nodes, NODES,
                   CTRL_ADDR, COEF_BASE, BIAS_BASE, LIN_BASE, ENC_BASE)

HERE = pathlib.Path(__file__).resolve().parents[1]
LIB = HERE.parents[1]
ROOT = LIB.parents[1]


# ---------------------------------------------------------------------------
# frame / config generators
# ---------------------------------------------------------------------------

def rnd_lut(r, bits):
    """Random legal monotone node table (non-decreasing, <= MPX)."""
    mx = mpx(bits)
    vals = sorted(r.randrange(mx + 1) for _ in range(NODES))
    vals[0] = r.choice([0, vals[0]])
    vals[-1] = r.choice([mx, vals[-1]])
    return vals


def rnd_cfg(r, bits, tone=False, domain=0):
    mat = [r.randrange(-8192, 8192) for _ in range(9)]
    # keep every row within ROW_GAIN_MAX
    for rr in range(3):
        s = sum(abs(mat[3 * rr + j]) for j in range(3))
        if s > 7 << 13:
            scale = (7 << 13) / s
            for j in range(3):
                mat[3 * rr + j] = int(mat[3 * rr + j] * scale)
    return Config(
        matrix=tuple(mat),
        bias=tuple(r.randrange(-mpx(bits) - 1, mpx(bits) + 1)
                   for _ in range(3)),
        tone_en=(1, 1, 1) if tone else (0, 0, 0),
        domain=domain,
        lin=tuple(sum((rnd_lut(r, bits) for _ in range(3)), [])),
        enc=tuple(sum((rnd_lut(r, bits) for _ in range(3)), [])),
        bits=bits)


def make_frame(w, h, kind, bits, r):
    mx = mpx(bits)
    if kind == 'zeros':
        return [0] * (w * h)
    if kind == 'max':
        return [packpix([mx, mx, mx], bits)] * (w * h)
    if kind == 'gradient':
        return [packpix([(x * 5 + y * 3 + c * 37) & mx for c in range(3)],
                        bits) for y in range(h) for x in range(w)]
    if kind == 'checker':
        v = r.randrange(1, mx + 1)
        return [packpix([(((x + y) % 2) * v + c * 11) & mx for c in range(3)],
                        bits) for y in range(h) for x in range(w)]
    if kind == 'extremes':
        out = []
        for y in range(h):
            for x in range(w):
                pick = (x + y) % 4
                if pick == 0:
                    out.append(packpix([mx, mx, mx], bits))
                elif pick == 1:
                    out.append(0)
                elif pick == 2:
                    out.append(packpix([mx, 0, mx // 2], bits))
                else:
                    out.append(packpix([0, mx, mx // 3], bits))
        return out
    return [packpix([r.randrange(mx + 1) for _ in range(3)], bits)
            for _ in range(w * h)]


# ---------------------------------------------------------------------------
# scenario builder
# ---------------------------------------------------------------------------

def build(bits, seed):
    """Return (inputs, expected, cfgmem entries, cfgpos, doms, checks)."""
    r = random.Random(seed)
    mx = mpx(bits)
    frames = []            # packed pixels, row-major
    geoms = []             # (w, h) per frame, same order
    events = []            # ('w', pos, addr, data, pause) / ('c', pos, pause)
    experr = []            # expected cfg_error per entry, aligned to events
    pos_of = lambda: sum(len(f) for f in frames)

    def add_frame(w, h, kind):
        geoms.append((w, h))
        frames.append(make_frame(w, h, kind, bits, r))
        return pos_of() - w * h          # sof index of this frame

    # replay-shadow computes the expected cfg_error per write beat exactly
    # like the RTL: unmapped address or out-of-range node -> rejected write.
    shchk = Shadow(bits)

    def wr(pos, addr, data, pause):
        events.append(('w', pos, addr, data, pause))
        experr.append(0 if shchk.write(addr, data) else 1)

    def commit(cfg, pos, pause, expect_err=False, cpos=None, extra=()):
        """Full image writes at ``pos``, then a commit request at ``cpos``
        (defaults to ``pos``).  ``extra`` = extra (addr,data) writes between
        the image writes and the commit."""
        for a, d in writes_for(cfg):
            wr(pos, a, d, pause)
        for a, d in extra:
            wr(pos, a, d, pause)
        events.append(('c', pos if cpos is None else cpos, pause))
        experr.append(1 if expect_err else 0)

    # ---- crafted configs ---------------------------------------------------
    cfgA = Config(matrix=(8192, -1024, 256, -512, 9000, -2048,
                          128, -768, 10000), bias=(4, -8, 16), bits=bits)

    enc_nodes = sum(([min(mx, i * (1 << (bits - 5)) + i * i // 12)
                     for i in range(NODES)] for _ in range(3)), [])
    lin_nodes = sum(([max(0, min(mx, (i * (1 << (bits - 5)) * 3) // 4
                                   + mx // 5)) for i in range(NODES)]
                     for _ in range(3)), [])
    cfgB = Config(matrix=(14000, -4000, -1500, -1200, 13000, -2000,
                          -800, -1600, 12000),
                  bias=(2, -4, 0), tone_en=(1, 1, 1), domain=0,
                  lin=tuple(lin_nodes), enc=tuple(enc_nodes), bits=bits)
    assert cfgB.legal()

    cfgC = Config(matrix=(8192, 0, 0, 0, 8192, 0, 0, 0, 8192),
                  bias=(0, 0, 0), tone_en=(1, 1, 1), domain=1,
                  lin=tuple(lin_nodes), enc=tuple(enc_nodes), bits=bits)
    cfgD = Config(matrix=(-4096, 8192, -2048, 8192, -4096, 0,
                          0, -2048, 8192),
                  bias=(-mx - 200, 0, mx + 100), bits=bits)
    assert cfgC.legal() and cfgD.legal()

    # illegal images
    bad_mono = Config(matrix=(8192, 0, 0, 0, 8192, 0, 0, 0, 8192), bits=bits)
    bl = list(bad_mono.lin)
    bl[40], bl[41] = mx, 0            # ch1 lin non-monotone
    bad_mono = Config(lin=tuple(bl), bits=bits)
    assert not bad_mono.legal()

    bad_row = Config(matrix=(20000, 20000, 20000, 0, 8192, 0, 0, 0, 8192),
                     bits=bits)
    assert not bad_row.legal()

    bad_off = Config(matrix=(8192, 0, 0, 0, 8192, 0, 0, 0, 8192),
                     tone_en=(0, 0, 0), bits=bits)
    bo = list(bad_off.enc)
    bo[70], bo[71] = mx, 0            # enc ch2 non-monotone, tone disabled
    bad_off = Config(enc=tuple(bo), bits=bits)
    assert not bad_off.legal()

    cfgE = rnd_cfg(r, bits, tone=True, domain=r.randrange(2))
    cfgF = rnd_cfg(r, bits, tone=False)

    # ---- scenario ----------------------------------------------------------
    add_frame(16, 8, 'random')                    # F0: reset default = identity
    p = pos_of()
    commit(cfgA, p, pause=True)                   # gap -> F1
    add_frame(16, 8, 'gradient')                  # F1: cfgA
    p = pos_of()
    commit(cfgB, p, pause=True)                   # gap -> F2
    add_frame(20, 10, 'extremes')                 # F2: cfgB (+lin tone)
    p = pos_of()
    commit(bad_mono, p, pause=True, expect_err=True)
    commit(bad_row, p, pause=True, expect_err=True)
    # ctrl with reserved bits set (written directly, not via Config)
    wr(p, CTRL_ADDR, 0x00F3, True);   assert experr[-1] == 0
    events.append(('c', p, True)); experr.append(1)
    commit(bad_off, p, pause=True, expect_err=True)
    # unmapped-address write: expect cfg_error on the write beat
    wr(p, 0x77, 0x1234, True);        assert experr[-1] == 1
    # cfgC is legal -> pending -> applies at F3 SOF (enc-bank tone).  An
    # extra node write with wdata > MPX rides inside its write block: the
    # RTL rejects it on the write beat (store dropped), so lin[0] keeps
    # the legal value writes_for(cfgC) just stored and the commit still
    # succeeds -- this covers out-of-range node rejection at write time.
    commit(cfgC, p, pause=True, extra=[(LIN_BASE, mx + 1)])
    assert experr[-2] == 1                        # the extra node write
    assert experr[-1] == 0                        # cfgC commit is legal
    sof_f3 = add_frame(32, 20, 'random')          # F3: cfgC (enc tone)
    # mid-frame commit: writes start when F3 starts; the commit request is
    # placed strictly inside F3 so its apply boundary is the F4 SOF.
    mid3 = sof_f3 + 64
    assert mid3 + 260 < sof_f3 + 32 * 20          # commit lands inside F3
    commit(cfgD, sof_f3, pause=False, cpos=mid3)
    events.append(('c', mid3, False)); experr.append(1)     # double commit
    # shadow writes stalling behind pending_apply (replay legal values)
    for a, d in writes_for(cfgE)[:6]:
        wr(mid3, a, d, False);        assert experr[-1] == 0
    add_frame(16, 8, 'checker')                   # F4: cfgD (neg/negative bias)
    p = pos_of()
    commit(cfgE, p, pause=True)                   # gap -> F5
    add_frame(24, 10, 'random')                   # F5: cfgE random legal
    p = pos_of()
    commit(bad_mono, p, pause=True, expect_err=True)
    commit(cfgF, p, pause=True)                   # gap -> F6
    add_frame(16, 8, 'extremes')                  # F6: cfgF

    # ---- replay through the model ------------------------------------------
    inputs, frame_start = [], []
    for fi, f in enumerate(frames):
        w = geoms[fi][0]
        frame_start.append(len(inputs))
        for i, pxx in enumerate(f):
            sof = int(i == 0)
            eol = int(i % w == w - 1)
            inputs.append((sof << (3 * bits + 1)) | (eol << (3 * bits)) | pxx)

    m_events = [(e[0], e[1], e[2], e[3]) if e[0] == 'w' else ('c', e[1])
                for e in events]
    frame_cfg, outcomes = simulate(m_events, frame_start, bits)

    # expected outputs
    expected = []
    oi = iter(frame_start)
    bounds = frame_start + [len(inputs)]
    for fi in range(len(frames)):
        s0, s1 = bounds[fi], bounds[fi + 1]
        cfg = frame_cfg[s0]
        for i in range(s0, s1):
            px = inputs[i] & ((1 << (3 * bits)) - 1)
            out = pixel(px, cfg)
            expected.append((inputs[i] & (3 << (3 * bits))) | out)

    # check outcomes match intended experr bits; a rejected write (unmapped
    # address or out-of-range node) consumes an 'error' outcome.
    oi = 0
    doms = []
    for ev, ee in zip(events, experr):
        if ev[0] == 'w':
            if ee:
                assert outcomes[oi][0] == 'error', (ev, outcomes[oi])
                oi += 1
        else:
            kind, dom = outcomes[oi]; oi += 1
            assert ee == (1 if kind == 'error' else 0), (ev, kind)
            if kind == 'done':
                doms.append(dom)
    assert oi == len(outcomes)

    # passthrough check: F0 uses the reset-default identity config
    for i in range(frame_start[1]):
        assert expected[i] == inputs[i], 'identity frame must pass through'

    cfgmem, cfgpos = [], []
    for ev, ee in zip(events, experr):
        if ev[0] == 'w':
            _, pos, addr, data, pause = ev
            cfgmem.append((0 << 25) | (ee << 24) | (addr << 16) | data)
        else:
            _, pos, pause = ev
            cfgmem.append((1 << 25) | (ee << 24))
        cfgpos.append((int(pause) << 31) | pos)
    return inputs, expected, cfgmem, cfgpos, doms


def run_case(out, bits, src_dir, env, iv, vv):
    case = out / f'b{bits}'
    case.mkdir()
    inputs, expected, cfgmem, cfgpos, doms = build(bits, 910 + bits)
    for name, data in [('input', inputs), ('expected', expected),
                       ('cfg', cfgmem), ('cfgpos', cfgpos), ('dom', doms)]:
        (case / (name + '.mem')).write_text(
            ''.join(f'{v:x}\n' for v in data))
    cmd = [iv, '-g2012', '-Wall', '-s', 'tb_ccm', '-o', 'sim.vvp',
           f'-Ptb_ccm.BITS={bits}', f'-Ptb_ccm.NCFG={len(cfgmem)}',
           f'-Ptb_ccm.NT={len(inputs)}', f'-Ptb_ccm.NDOM={len(doms)}',
           str(src_dir / 'ccm_stream.sv'), str(src_dir / 'tb_ccm.sv')]
    for label, command in [('compile', cmd), ('run', [vv, 'sim.vvp'])]:
        res = subprocess.run(command, cwd=case, env=env, capture_output=True,
                             text=True, timeout=900)
        (case / (label + '.log')).write_text(
            '$ ' + ' '.join(command) + '\n' + res.stdout + res.stderr)
        assert res.returncode == 0, (case, res.stdout, res.stderr)
    assert 'PASS ccm' in res.stdout, (case, res.stdout)
    for mutation in ('data', 'sideband', 'count', 'order'):
        res = subprocess.run([vv, 'sim.vvp', '+' + mutation], cwd=case,
                             env=env, capture_output=True, text=True,
                             timeout=900)
        (case / f'negative_{mutation}.log').write_text(
            res.stdout + res.stderr)
        assert res.returncode != 0 and (
            'ccm mismatch' in res.stdout
            or mutation == 'count' and 'count timeout' in res.stdout), (
            case, mutation, res.stdout)
    return dict(bits=bits, outputs=len(inputs), cfg_entries=len(cfgmem),
                dones=len(doms), status='PASS', checker_negatives=4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', type=pathlib.Path)
    a = ap.parse_args()
    out = a.output or HERE / 'evidence' / (
        'sim_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    src = out / 'sources'
    src.mkdir()
    files = [HERE / 'rtl' / 'ccm_stream.sv', HERE / 'tests' / 'tb_ccm.sv',
             HERE / 'models' / 'model.py', HERE / 'tests' / 'test_ccm.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))
    cad = ROOT / 'tools' / 'oss-cad-suite' / 'oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = str(cad / 'bin') + os.pathsep + str(cad / 'lib') + \
        os.pathsep + env['PATH']
    iv = shutil.which('iverilog', path=env['PATH'])
    vv = shutil.which('vvp', path=env['PATH'])
    src = src.resolve()
    results = [run_case(out, bits, src, env, iv, vv) for bits in (8, 10)]
    # illegal static parameter build
    bad = out / 'invalid_BITS_9'
    bad.mkdir()
    (bad / 'tb.sv').write_text(
        'module tb; ccm_stream #(.BITS(9)) dut(); '
        'initial #1 $finish; endmodule\n')
    cp = subprocess.run([iv, '-g2012', '-s', 'tb', '-o', 'bad.vvp',
                         str(src / 'ccm_stream.sv'), 'tb.sv'],
                        cwd=bad, env=env, capture_output=True, text=True)
    rp = subprocess.run([vv, 'bad.vvp'], cwd=bad, env=env,
                        capture_output=True, text=True)
    (bad / 'run.log').write_text(cp.stdout + cp.stderr +
                                 rp.stdout + rp.stderr)
    assert rp.returncode != 0 and 'unsupported' in rp.stdout, rp.stdout
    (out / 'summary.json').write_text(json.dumps(dict(
        status='PASS', cases=results, illegal_static_parameters=1,
        scope='RTL simulation; no P&R/board claim'), indent=2))
    print(out)


if __name__ == '__main__':
    main()
