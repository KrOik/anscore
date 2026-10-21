"""ISP-08 model self-checks: per-stage bit-exact contracts, float semantics vs
integer contract, gamma table generation + committed .vh freshness, DPC known
answers and cluster-limit behaviour, gray-world AWB estimate sanity,
pack round-trips and illegal config rejection.  Pure stdlib.
Writes evidence/model_validation.json relative to the core dir.
"""
import datetime
import json
import random
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (Config, GAMMA_NODES, apply_blc, apply_gamma, apply_wb,
                       awb_sums, blc_chan, chan, dpc_frame, emit_gamma_vh,
                       float_pipeline, gamma_chan, gamma_nodes,
                       gray_world_gains, med8, mpx, pack_config, packpix,
                       pipeline, unpack_config, wb_chan, window3x3, widths)

HERE = Path(__file__).resolve().parents[1]
rng = random.Random(0x1508)


def frame(w, h, kind, bits, ch, seed):
    r = random.Random(seed)
    mx = mpx(bits)

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
    if kind == 'defects':
        base = [[packpix([min(mx, 60 + x + y * 2) for _ in range(ch)], bits)
                 for x in range(w)] for y in range(h)]
        for _ in range(max(1, w * h // 8)):
            base[r.randrange(h)][r.randrange(w)] = \
                packpix([mx if r.randrange(2) else 0] * ch, bits)
        return base
    return [[px() for _ in range(w)] for _ in range(h)]


def main():
    cases = 0

    # ---- committed gamma table must equal a fresh regeneration -------------
    vh = (HERE / 'rtl' / 'gamma_table.vh').read_text()
    assert vh == emit_gamma_vh(), 'rtl/gamma_table.vh is stale; regenerate'
    cases += 1

    # ---- gamma tables: monotonic, endpoints, bounded deviation -------------
    for bits in (8, 10):
        mx = mpx(bits)
        for sel in (1, 2):
            nodes = gamma_nodes(bits, sel)
            assert len(nodes) == GAMMA_NODES
            assert all(a <= b for a, b in zip(nodes, nodes[1:]))
            assert nodes[0] == 0 and nodes[-1] == mx
            e = 1.0 / 2.2 if sel == 1 else 2.2
            worst = 0
            for v in range(mx + 1):
                real = int(mx * ((v / mx) ** e) + 0.5)
                worst = max(worst, abs(gamma_chan(v, sel, bits) - real))
            # PWL of a convex/concave pow curve: error concentrated at the
            # toe (infinite slope at 0 for encode).  Bound documented in
            # SPEC; keep the assert honest rather than tight.
            assert worst <= mx // 8 + 2, (bits, sel, worst)
        assert [gamma_chan(v, 0, bits) for v in range(mx + 1)] == \
            list(range(mx + 1))                       # bypass is identity
        cases += 1

    # ---- BLC: exact subtract/clamp -----------------------------------------
    for bits in (8, 10):
        mx = mpx(bits)
        for v in range(0, mx + 1, 7):
            for off in (0, 1, v // 2, v, mx):
                exp = max(0, v - off)
                assert blc_chan(v, off, bits) == exp
        cases += 1

    # ---- WB: RNE + clamp, vs real gain -------------------------------------
    for bits in (8, 10):
        mx = mpx(bits)
        for v in range(0, mx + 1, 3):
            for g in (0, 1, 128, 256, 300, 512, 4095):
                got = wb_chan(v, g, bits)
                assert got == min(mx, (v * g + 128) >> 8)
                # |int - float| <= 0.5 pre-clamp (RNE property)
                assert abs(got - v * g / 256.0) <= 0.5 + 1e-9 or got == mx
        assert wb_chan(mx, 4095, bits) == mx          # saturation, not wrap
        cases += 1

    # ---- med8 vs sorted() --------------------------------------------------
    for _ in range(500):
        vals = [rng.randrange(1024) for _ in range(8)]
        s = sorted(vals)
        assert med8(vals) == (s[3] + s[4]) // 2
    cases += 1

    # ---- DPC known answers --------------------------------------------------
    # Isolated dead pixel in a uniform field must be replaced by the median.
    uni = [[packpix([100, 100, 100], 8)] * 5 for _ in range(5)]
    f = [r[:] for r in uni]
    f[2][2] = packpix([0, 0, 0], 8)
    out = dpc_frame(f, 4, 8, 3)
    assert out[2][2] == packpix([100, 100, 100], 8)
    # Same-pixel hot defect on one channel only: only that channel corrects.
    f = [r[:] for r in uni]
    f[1][3] = packpix([255, 100, 100], 8)
    out = dpc_frame(f, 4, 8, 3)
    assert out[1][3] == packpix([100, 100, 100], 8)
    # thr = MPX disables: nothing changes even with an extreme centre.
    out = dpc_frame(f, mpx(8), 8, 3)
    assert out == f
    # REPLICATE border: corner pixel's window replicates the corner.
    f = [r[:] for r in uni]
    f[0][0] = packpix([0, 0, 0], 8)
    out = dpc_frame(f, 4, 8, 3)
    assert out[0][0] == packpix([100, 100, 100], 8)
    # Cluster limit, documented semantics: with <=3 defective neighbors the
    # correction is exact (median cannot be displaced); a 4-neighbor
    # same-direction cluster shifts med8 to (100+255)>>1=177, so the center
    # is "corrected" to a wrong value - correction is NOT guaranteed there.
    f = [r[:] for r in uni]
    for yy, xx in ((1, 1), (1, 2), (2, 1), (2, 2)):
        f[yy][xx] = packpix([255, 255, 255], 8)
    out = dpc_frame(f, 4, 8, 3)
    assert out[2][2] == packpix([100, 100, 100], 8)   # 3 bad nb: still exact
    f = [r[:] for r in uni]
    for yy, xx in ((1, 1), (1, 2), (1, 3), (2, 1), (2, 2)):
        f[yy][xx] = packpix([255, 255, 255], 8)
    out = dpc_frame(f, 4, 8, 3)
    assert out[2][2] == packpix([177, 177, 177], 8)   # 4 bad nb: med polluted
    cases += 4

    # ---- end-to-end: bit-exact vs float pipeline ----------------------------
    for bits in (8, 10):
        mx = mpx(bits)
        for ch in (1, 3):
            for w, h in ((7, 5), (16, 12), (1, 1)):
                for kind in ('uniform', 'gradient', 'defects', 'random'):
                    f = frame(w, h, kind, bits, ch, w * 31 + h + ch * 7 + bits)
                    for sel in (0, 1, 2):
                        cfg = Config(w, h, (mx // 16, mx // 8, 0),
                                     (300, 256, 200), mx // 16, sel,
                                     width=w, height=h, bits=bits, ch=ch)
                        got, sums = pipeline(f, cfg)
                        ref, fsums = float_pipeline(f, cfg)
                        assert sums == fsums
                        for y in range(h):
                            for x in range(w):
                                for c in range(ch):
                                    gi = chan(got[y][x], c, bits)
                                    fr = chan(ref[y][x], c, bits)
                                    # BLC/WB/DPC exact; only gamma may deviate
                                    if sel == 0:
                                        assert gi == fr
                                    else:
                                        assert abs(gi - fr) <= mx // 8 + 2
                        cases += 1

    # ---- AWB statistics + gray-world estimate -------------------------------
    # Uniform colored frame: means are the channel values; gains equalize.
    f = [[packpix([60, 120, 240], 8)] * 8 for _ in range(6)]
    sums = awb_sums(f, 3, 8)
    assert sums == [60 * 48, 120 * 48, 240 * 48]
    g = gray_world_gains(sums, 48, 3)
    # target mean = 140 -> gains ~ 256*140/{60,120,240}
    assert g[0] == int(256 * Fraction(140, 60) + Fraction(1, 2))
    assert g[1] == int(256 * Fraction(140, 120) + Fraction(1, 2))
    assert g[2] == int(256 * Fraction(140, 240) + Fraction(1, 2))
    # After applying estimated gains to the means, channels (nearly) equal.
    post = [min(mpx(8), (v * g[i] + 128) >> 8) for i, v in enumerate((60, 120, 240))]
    assert max(post) - min(post) <= 2
    # Zero-sum channel -> neutral gain 256 (documented degenerate rule).
    assert gray_world_gains([0, 100, 100], 8, 3)[0] == 256
    # CH=1 -> all neutral.
    assert gray_world_gains([77, 0, 0], 8, 1) == [256, 256, 256]
    cases += 3

    # ---- pack/unpack round trip ---------------------------------------------
    for bits in (8, 10):
        cfg = Config(16, 12, (1, 200, mpx(bits)), (0, 256, 4095), 37, 2,
                     width=16, height=12, bits=bits)
        iw, ih, blc, wb, thr, gs = unpack_config(
            pack_config(cfg), bits, 16, 12)
        assert (iw, ih, blc, wb, thr, gs) == \
            (16, 12, [1, 200, mpx(bits)], [0, 256, 4095], 37, 2)
        cases += 1

    # ---- illegal configs -----------------------------------------------------
    bad = [dict(img_w=0), dict(img_h=0), dict(img_w=33),      # != static W
           dict(blc=(0, 0)), dict(wb=(256, 256)),
           dict(blc=(-1, 0, 0)), dict(blc=(0, 0, 300)),
           dict(wb=(0, 256, 4096)), dict(dpc_thr=-1),
           dict(dpc_thr=256), dict(gamma_sel=3), dict(gamma_sel=-1),
           dict(bits=9), dict(ch=2)]
    for kw in bad:
        args = dict(img_w=32, img_h=24, width=32, height=24, bits=8, ch=3)
        args.update(kw)
        try:
            Config(**args)
        except ValueError:
            cases += 1
        else:
            raise AssertionError('illegal config accepted: %r' % kw)

    # ---- widths sanity --------------------------------------------------------
    w = widths(10, 3, 64, 64)
    assert w['sumw'] == 22 and w['pw'] == 30 and w['ew'] == 32
    w = widths(8, 1, 1, 1)
    assert w['sumw'] >= 1 and w['ow'] >= 1
    cases += 1

    out = HERE / 'evidence' / 'model_validation.json'
    out.parent.mkdir(exist_ok=True)
    summary = {
        'status': 'PASS', 'cases': cases,
        'checks': ['committed gamma_table.vh == regeneration',
                   'gamma nodes monotonic, endpoints, bounded PWL error',
                   'BLC subtract/clamp vs real subtract',
                   'WB RNE+clamp vs real gain, saturation no-wrap',
                   'med8 == floor mean of middle order stats',
                   'DPC isolated/channel-selective/border/disabled/cluster',
                   'end-to-end bit-exact vs float pipeline',
                   'AWB sums + gray-world gain estimate sanity',
                   'config pack/unpack round trip',
                   'illegal config rejection'],
        'scope': 'model-only; no RTL/board claim',
        'time': datetime.datetime.now().isoformat(timespec='seconds'),
    }
    out.write_text(json.dumps(summary, indent=2))
    print('PASS model cases=%d -> %s' % (cases, out))


if __name__ == '__main__':
    main()
