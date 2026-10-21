"""ISP-10 model self-checks: prefix-sum path vs independent direct path,
float semantics vs the bit-exact integer contract, edge cases, illegal args.
Pure stdlib. Writes evidence/model_validation.json relative to the core dir.
"""
import datetime
import json
import random
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (Config, float_stats, integral, stats, widths,
                       window_direct, window_integral, WIN_MAX)

HERE = Path(__file__).resolve().parents[1]
rng = random.Random(0x1510)


def frame(w, h, kind, bits, seed):
    r = random.Random(seed)
    mx = (1 << bits) - 1
    if kind == 'uniform':
        v = r.randrange(mx + 1)
        return [[v] * w for _ in range(h)]
    if kind == 'zeros':
        return [[0] * w for _ in range(h)]
    if kind == 'max':
        return [[mx] * w for _ in range(h)]
    if kind == 'gradient':
        return [[(x * 3 + y * 5) & mx for x in range(w)] for y in range(h)]
    if kind == 'checker':
        v = r.randrange(1, mx + 1)
        return [[(x + y) % 2 * v for x in range(w)] for y in range(h)]
    return [[r.randrange(mx + 1) for _ in range(w)] for _ in range(h)]


def main():
    sizes = [(1, 1), (2, 2), (7, 5), (32, 24), (1, 9), (9, 1), (4, 3)]
    wins = [(1, 1), (3, 3), (5, 5), (15, 15), (15, 3), (2, 9), (7, 1)]
    cases = 0
    # Integral path must agree with the independent direct path everywhere.
    for w, h in sizes:
        for ww, wh in wins:
            f = frame(w, h, 'random', 10, w * 1000 + h * 37 + ww)
            assert window_integral(f, ww, wh) == (
                window_direct(f, ww, wh), window_direct(f, ww, wh, square=True))
            cases += 1
    # Bit-exact contract vs exact rational semantics.
    for w, h in sizes:
        for bits in (8, 10):
            for kind in ('uniform', 'zeros', 'max', 'gradient', 'checker', 'random'):
                for ww, wh, c in [(3, 3, 0), (5, 5, 25), (1, 1, -1),
                                  (15, 15, -64), (2, 9, 127), (15, 3, -128)]:
                    f = frame(w, h, kind, bits, w * 7 + h + ww * 13 + c)
                    cfg = Config(w, h, ww, wh, c, max_w=64, max_h=64)
                    got = stats(f, cfg, bits)
                    ref = float_stats(f, ww, wh, c)
                    assert len(got) == w * h == len(ref)
                    for g, r in zip(got, ref):
                        assert g['wsum'] == r['wsum'] and g['wsq'] == r['wsq']
                        assert g['area'] == r['area']
                        # floor mean <= exact rational mean < floor+1
                        assert g['mean'] <= r['mean'] < g['mean'] + 1
                        # bin: integer rule equals real rule exactly
                        assert g['bin'] == r['bin']
                        # integer variance contract: var=floor(q/a)-mean^2 is
                        # within (-1, 2*mean+1) of the exact rational variance
                        # (exact whenever sum % area == 0, e.g. uniform areas)
                        assert g['var'] >= 0
                        dev = Fraction(g['var']) - r['var']
                        assert -1 < dev < 2 * g['mean'] + 1
                    cases += 1
    # Known answers: uniform frame -> mean=v, var=0, bin=1 iff c>0.
    for v in (0, 5, 200):
        for c in (-1, 0, 1):
            cfg = Config(7, 5, 3, 3, c, max_w=64, max_h=64)
            got = stats([[v] * 7 for _ in range(5)], cfg, 8)
            for g in got:
                assert g['mean'] == v and g['var'] == 0
                assert g['bin'] == int(c > 0)
                assert g['out'] == (255 if c > 0 else 0)
                cases += 1
    # 1x1 frame: window clips to single pixel.
    got = stats([[42]], Config(1, 1, 15, 15, 3, max_w=64, max_h=64), 10)
    g = got[0]
    assert (g['isum'], g['isq'], g['wsum'], g['wsq'], g['area']) == (42, 1764, 42, 1764, 1)
    assert g['mean'] == 42 and g['var'] == 0 and g['bin'] == 1  # 45*1 > 42
    cases += 1
    # Integral image spot check on 2x2.
    assert integral([[1, 2], [3, 4]]) == [[1, 3], [4, 10]]
    assert integral([[1, 2], [3, 4]], square=True) == [[1, 5], [10, 30]]
    cases += 1
    # Width derivation sanity: no overflow for documented max config.
    w = widths(10, 256, 256)
    assert w['iw'] == 26 and w['isw'] == 46 and w['wsw'] == 18 and w['aw'] == 8
    w = widths(10, 64, 64)
    assert w['iw'] == 22
    # Illegal configurations must raise.
    bad = [dict(img_w=0), dict(img_h=0), dict(img_w=65), dict(img_h=65),
           dict(win_w=0), dict(win_w=16), dict(win_h=0), dict(win_h=16),
           dict(c=-129), dict(c=128), dict(max_w=256, max_h=257)]
    for kw in bad:
        args = dict(img_w=8, img_h=8, max_w=64, max_h=64)
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
        'checks': ['integral path == direct path',
                   'float rational semantics vs integer contract',
                   'known uniform answers', '1x1 edge', 'width bounds',
                   'illegal config rejection'],
        'scope': 'model-only; no RTL/board claim',
        'time': datetime.datetime.now().isoformat(timespec='seconds'),
    }
    out.write_text(json.dumps(summary, indent=2))
    print('PASS model cases=%d -> %s' % (cases, out))


if __name__ == '__main__':
    main()
