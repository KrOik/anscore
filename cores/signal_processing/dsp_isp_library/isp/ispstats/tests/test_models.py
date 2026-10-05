"""ISP-12 model self-checks: Bresenham zone map vs direct floor map, zone
boundary correctness, bit-exact records vs exact-rational float reference,
known gradient/overexposure answers, pack roundtrip, offline AE analysis
scenes, illegal arguments.  Pure stdlib.  Writes
evidence/model_validation.json relative to the core dir.
"""
import datetime
import json
import random
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (Config, bresenham_map, luma, pack_record, stats,
                       unpack_record, widths, zone_edges, zone_map,
                       float_stats, ZONES_MAX)
import ae_analysis

HERE = Path(__file__).resolve().parents[1]


def frame(w, h, kind, bits, ch, seed):
    r = random.Random(seed)
    mx = (1 << bits) - 1

    def px3():
        return (r.randrange(mx + 1), r.randrange(mx + 1), r.randrange(mx + 1))
    if ch == 3:
        if kind == 'uniform':
            v = px3()
            return [[v] * w for _ in range(h)]
        if kind == 'zeros':
            return [[(0, 0, 0)] * w for _ in range(h)]
        if kind == 'max':
            return [[(mx, mx, mx)] * w for _ in range(h)]
        if kind == 'gradient':
            return [[((x * 3 + y * 2) & mx, (x + y * 5) & mx, (x * 7 + y) & mx)
                     for x in range(w)] for y in range(h)]
        if kind == 'vedge':
            hi = (mx, mx // 2, mx // 3)
            return [[(0, 0, 0) if x < w // 2 else hi for x in range(w)]
                    for y in range(h)]
        if kind == 'highlight':
            f = [[(mx // 4, mx // 4, mx // 4)] * w for _ in range(h)]
            for yy in range(h // 4, (3 * h) // 4):
                for xx in range(w // 4, (3 * w) // 4):
                    f[yy][xx] = (mx, mx, mx)
            return f
        if kind == 'checker':
            v = px3()
            return [[v if (x + y) % 2 else (0, 0, 0) for x in range(w)]
                    for y in range(h)]
        return [[px3() for _ in range(w)] for _ in range(h)]
    # gray
    if kind == 'uniform':
        v = r.randrange(mx + 1)
        return [[v] * w for _ in range(h)]
    if kind == 'zeros':
        return [[0] * w for _ in range(h)]
    if kind == 'max':
        return [[mx] * w for _ in range(h)]
    if kind == 'gradient':
        return [[(x * 3 + y * 5) & mx for x in range(w)] for y in range(h)]
    if kind == 'vedge':
        return [[0 if x < w // 2 else mx for x in range(w)] for y in range(h)]
    if kind == 'highlight':
        f = [[mx // 4] * w for _ in range(h)]
        for yy in range(h // 4, (3 * h) // 4):
            for xx in range(w // 4, (3 * w) // 4):
                f[yy][xx] = mx
        return f
    if kind == 'checker':
        v = r.randrange(1, mx + 1)
        return [[(x + y) % 2 * v for x in range(w)] for y in range(h)]
    return [[r.randrange(mx + 1) for _ in range(w)] for _ in range(h)]


def main():
    cases = 0
    # 1. Bresenham raster map == direct floor map, all legal pairs.
    for dim in range(1, 65):
        for z in range(1, min(ZONES_MAX, dim) + 1):
            assert bresenham_map(dim, z) == zone_map(dim, z), (dim, z)
            cases += 1
    # 2. Zone edges: contiguous, non-empty, covering, increasing.
    for dim, z in [(1, 1), (7, 3), (32, 8), (24, 5), (2, 2), (64, 8)]:
        e = zone_edges(dim, z)
        assert len(e) == z
        cov = []
        for zi, (a, b) in enumerate(e):
            assert a < b
            cov.extend(range(a, b))
            if zi:
                assert e[zi - 1][1] == a
        assert cov == list(range(dim))
        cases += 1
    # 3. Bit-exact records vs rational float reference, all grids on small
    #    frames + representative grids on large ones, gray and RGB.
    sizes = [(1, 1), (2, 2), (7, 5), (32, 24), (1, 9), (9, 1), (4, 3)]
    grids = [(1, 1), (2, 2), (3, 2), (4, 4), (8, 8), (8, 1), (1, 8),
             (5, 7), (2, 3), (7, 8)]
    pats = ['uniform', 'zeros', 'max', 'gradient', 'checker', 'vedge',
            'highlight', 'random']
    for w, h in sizes:
        for bits in (8, 10):
            for ch in (1, 3):
                mx = (1 << bits) - 1
                legal = [g for g in grids if g[0] <= w and g[1] <= h]
                for i, (zxn, zyn) in enumerate(legal):
                    kind = pats[(i + w + h) % len(pats)]
                    th = [0, 1, mx // 2, mx - 1, mx][i % 5]
                    f = frame(w, h, kind, bits, ch, w * 977 + h * 31 + i + bits)
                    cfg = Config(w, h, zxn, zyn, th, bits=bits, ch=ch,
                                 max_w=64, max_h=64)
                    recs = stats(f, cfg)
                    refs = float_stats(f, cfg)
                    assert len(recs) == zxn * zyn == len(refs)
                    # every zone non-empty and total count = W*H
                    assert all(r['count'] > 0 for r in recs)
                    assert sum(r['count'] for r in recs) == w * h
                    for rec, ref in zip(recs, refs):
                        assert rec['count'] == ref['count']
                        assert Fraction(rec['sum0'], rec['count']) == ref['mean0']
                        assert Fraction(rec['sum1'], rec['count']) == ref['mean1']
                        assert Fraction(rec['sum2'], rec['count']) == ref['mean2']
                        assert Fraction(rec['oe'], rec['count']) == ref['oe_frac']
                        assert rec['focus'] == ref['focus']
                    cases += 1
    # 4. Known answers.
    # 4a. Flat gray frame: focus 0, sums exact, oe per threshold.
    cfg = Config(7, 5, 3, 2, 100, bits=8, ch=1, max_w=64, max_h=64)
    recs = stats([[50] * 7 for _ in range(5)], cfg)
    for r in recs:
        assert r['focus'] == 0 and r['sum0'] == 50 * r['count']
        assert r['oe'] == 0  # 50 < 100
    assert sum(r['count'] for r in recs) == 35
    cases += 1
    cfg = Config(7, 5, 3, 2, 50, bits=8, ch=1, max_w=64, max_h=64)
    recs = stats([[50] * 7 for _ in range(5)], cfg)
    assert all(r['oe'] == r['count'] for r in recs)  # 50 >= 50: all clipped
    cases += 1
    # 4b. Vertical edge gray 8x2, zones 2x1: e = mx at boundary column, per
    #     row; zone 0 (flat left) focus = |edge at x=w/2|?  boundary pixel
    #     belongs to zone of x=w/2.  w=8, zones_x=2 -> boundary x=4 in zone 1.
    f = [[0] * 4 + [200] * 4 for _ in range(2)]
    cfg = Config(8, 2, 2, 1, 255, bits=8, ch=1, max_w=64, max_h=64)
    recs = stats(f, cfg)
    # zone0 (x 0..3): all zero -> focus 0; zone1 (x 4..7): gx at x=4 = 200,
    # rest 0 -> focus 200 per row -> 2*200 = 400.
    assert recs[0]['focus'] == 0 and recs[1]['focus'] == 400
    assert recs[0]['sum0'] == 0 and recs[1]['sum0'] == 4 * 200 * 2
    cases += 1
    # 4c. Horizontal edge gray 2x4, zones 1x2: gy on band boundary row.
    f = [[0, 0]] * 2 + [[100, 100]] * 2
    cfg = Config(2, 4, 1, 2, 255, bits=8, ch=1, max_w=64, max_h=64)
    recs = stats(f, cfg)
    # zone0 rows 0,1 flat -> 0; zone1 rows 2,3: gy at row2 = 100 each px.
    assert recs[0]['focus'] == 0 and recs[1]['focus'] == 2 * 100
    cases += 1
    # 4d. 1x1 frame: single pixel, focus 0.
    recs = stats([[42]], Config(1, 1, 1, 1, 10, bits=8, ch=1,
                                max_w=64, max_h=64))
    r = recs[0]
    assert (r['count'], r['sum0'], r['oe'], r['focus']) == (1, 42, 1, 0)
    cases += 1
    # 4e. RGB luma and any-channel overexposure: only B clipped counts too.
    f = [[(10, 20, 250)] * 4 for _ in range(2)]
    cfg = Config(4, 2, 2, 1, 200, bits=8, ch=3, max_w=64, max_h=64)
    recs = stats(f, cfg)
    for r in recs:
        assert r['sum0'] == 10 * r['count'] and r['sum2'] == 250 * r['count']
        assert r['oe'] == r['count']            # 250 >= 200 on B
        assert r['focus'] == 0                  # uniform luma
    cases += 1
    # 4f. Luma exactness: (r + 2g + b) >> 2.
    assert luma((4, 8, 16), 3) == (4 + 16 + 16) >> 2
    assert luma(77, 1) == 77
    cases += 1
    # 5. Record pack/unpack roundtrip on boundary values.
    for bits, ch, mw, mh in [(8, 3, 32, 24), (10, 1, 64, 64), (10, 3, 256, 256)]:
        w = widths(bits, ch, mw, mh)
        rec = {'count': (1 << w['cntw']) - 1, 'oe': 5,
               'sum0': (1 << w['sumw']) - 1, 'sum1': 7, 'sum2': 9,
               'focus': (1 << w['enw']) - 1}
        assert unpack_record(pack_record(rec, w), w) == rec
        cases += 1
    # 6. Offline AE analysis scenes (host-side model, not a control loop).
    def scene(v, bits=8, ch=3, w=8, h=8, zx=4, zy=4):
        mx = (1 << bits) - 1
        f = [[v] * w for _ in range(h)]
        cfg = Config(w, h, zx, zy, mx, bits=bits, ch=ch, max_w=64, max_h=64)
        return stats(f, cfg)
    s = ae_analysis.suggest_exposure_gain(scene((30, 30, 30)), 8, ch=3)
    assert s['exposure'] > 1.0 or s['gain'] > 1.0      # dark -> brighten
    s = ae_analysis.suggest_exposure_gain(scene((240, 240, 240)), 8, ch=3)
    assert s['exposure'] < 1.0                          # bright -> darken
    s = ae_analysis.suggest_exposure_gain(scene((0, 0, 0)), 8, ch=3)
    assert s['exposure'] == 4.0 and s['gain'] == 8.0    # black -> max
    # clipped scene: >5% overexposed -> brightening suppressed.
    f = [[(10, 10, 10)] * 8 for _ in range(8)]
    for yy in range(4):
        for xx in range(4):
            f[yy][xx] = (255, 255, 255)
    recs = stats(f, Config(8, 8, 4, 4, 200, bits=8, ch=3, max_w=64, max_h=64))
    s = ae_analysis.suggest_exposure_gain(recs, 8, ch=3)
    assert s['highlight_limited'] and s['exposure'] <= 1.0
    # AWB gray-world: red-heavy scene -> r gain below 1, b above 1.
    recs = stats([[(200, 50, 25)] * 8 for _ in range(8)],
                 Config(8, 8, 4, 4, 255, bits=8, ch=3, max_w=64, max_h=64))
    g = ae_analysis.awb_channel_gains(recs)
    assert g['r'] < 1.0 < g['b'] and g['g'] == 1.0
    # AF aid: edge zone outranks flat zone.
    f = [[0] * 4 + [200] * 4 for _ in range(4)]
    recs = stats(f, Config(8, 4, 2, 1, 255, bits=8, ch=1, max_w=64, max_h=64))
    fs = ae_analysis.focus_scores(recs)
    assert fs[0] == 0 and fs[1] > 0
    cases += 6
    # 7. Illegal configurations must raise.
    bad = [dict(img_w=0), dict(img_h=0), dict(img_w=65), dict(img_h=65),
           dict(zones_x=0), dict(zones_x=9), dict(zones_y=0), dict(zones_y=9),
           dict(zones_x=9, img_w=8), dict(zones_y=5, img_h=4),
           dict(thresh=256, bits=8), dict(bits=9), dict(ch=2),
           dict(max_w=64, max_h=2000)]
    for kw in bad:
        args = dict(img_w=8, img_h=8, bits=8, ch=3, max_w=64, max_h=64)
        args.update(kw)
        try:
            Config(**args)
        except ValueError:
            cases += 1
        else:
            raise AssertionError('illegal config accepted: %r' % kw)
    out = HERE / 'evidence' / 'model_validation.json'
    out.parent.mkdir(exist_ok=True)
    summary = {
        'status': 'PASS', 'cases': cases,
        'checks': ['bresenham map == floor zone map (all dim<=64, zones<=8)',
                   'zone edges contiguous/covering',
                   'bit-exact records vs exact rational floats, gray+RGB',
                   'flat/edge/highlight known answers',
                   'record pack/unpack roundtrip',
                   'offline AE/AWB/AF analysis scenes',
                   'illegal config rejection'],
        'scope': 'model-only; no RTL/board claim',
        'time': datetime.datetime.now().isoformat(timespec='seconds'),
    }
    out.write_text(json.dumps(summary, indent=2))
    print('PASS model cases=%d -> %s' % (cases, out))


if __name__ == '__main__':
    main()
