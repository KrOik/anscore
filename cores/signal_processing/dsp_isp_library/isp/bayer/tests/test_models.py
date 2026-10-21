"""ISP-07 model self-checks: float rational semantics vs the bit-exact
integer contract, phase/origin identities, boundary replication, edge cases,
illegal args.  Pure stdlib.  Writes evidence/model_validation.json.
"""
import datetime
import json
import random
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (CFA_NAMES, Config, R_PHASE, demosaic, demosaic_float,
                       site_color, taps3x3)

HERE = Path(__file__).resolve().parents[1]


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


def mosaic(rgb, cfg):
    """Sample an RGB image through the Bayer mosaic defined by cfg."""
    h, w = len(rgb), len(rgb[0])
    return [[{'R': rgb[y][x][0], 'G': rgb[y][x][1], 'B': rgb[y][x][2]}[
             site_color(cfg.cfa, x, y, cfg.ox, cfg.oy)]
             for x in range(w)] for y in range(h)]


def main():
    cases = 0
    sizes = [(1, 1), (2, 2), (3, 3), (4, 3), (3, 4), (7, 5), (32, 24),
             (1, 9), (9, 1), (5, 5)]
    # Site-color coverage: every (cfa, ox, oy) must produce both R and B
    # phases and two G phases on any >= 2x2 area.
    for cfa in range(4):
        rph = R_PHASE[cfa]
        assert site_color(cfa, rph[1], rph[0]) == 'R'
        assert site_color(cfa, rph[1] ^ 1, rph[0] ^ 1) == 'B'
        assert site_color(cfa, rph[1], rph[0] ^ 1) == 'G'
        cases += 1
    # Origin-shift identities: BGGR/GRBG/GBRG are RGGB at shifted origins,
    # and a nonzero ROI origin on RGGB reproduces the other named patterns.
    f = frame(6, 5, 'random', 8, 99)
    for shifted, cfa in [((1, 1), 1), ((1, 0), 2), ((0, 1), 3)]:
        a = demosaic(f, Config(cfa=0, ox=shifted[0], oy=shifted[1]), 8)
        b = demosaic(f, Config(cfa=cfa, ox=0, oy=0), 8)
        assert a == b, (shifted, cfa)
        cases += 1
    # Bit-exact contract vs exact rational semantics on every combo.
    for w, h in sizes:
        for bits in (8, 10):
            for kind in ('uniform', 'zeros', 'max', 'gradient', 'checker',
                         'random'):
                for cfg in (Config(0, 0, 0), Config(1, 1, 0), Config(2, 0, 1),
                            Config(3, 1, 1)):
                    img = frame(w, h, kind, bits, w * 7 + h * 31 + cfg.cfa)
                    got = demosaic(img, cfg, bits)
                    ref = demosaic_float(img, cfg)
                    assert len(got) == w * h == len(ref)
                    mx = (1 << bits) - 1
                    for g, r in zip(got, ref):
                        assert 0 <= g['r'] <= mx and 0 <= g['g'] <= mx
                        assert 0 <= g['b'] <= mx
                        assert g['site'] == r['site']
                        # truncating mean <= exact rational mean < trunc+1
                        for ch in ('r', 'g', 'b'):
                            assert Fraction(g[ch]) <= r[ch] < g[ch] + 1
                        # the site channel is copied, never averaged
                        site_ch = g['site'].lower()
                        assert Fraction(g[site_ch]) == r[site_ch] == g['pixel']
                        if g['x'] == 0 and g['y'] == 0:
                            assert g['sof'] == 1
                        if g['x'] == w - 1:
                            assert g['eol'] == 1
                    cases += 1
    # Known answer 1: per-channel-constant mosaic reconstructs exactly in the
    # interior (every averaged tap is a true same-color neighbor).  Borders
    # legitimately differ: REPLICATE taps copy the edge site into averages of
    # a different site color -- the specified and tested boundary semantics.
    for cfa in range(4):
        for ox in (0, 1):
            for oy in (0, 1):
                cfg = Config(cfa, ox, oy)
                rgb = [[(17, 91, 203)] * 7 for _ in range(5)]
                mos = mosaic(rgb, cfg)
                for rec in demosaic(mos, cfg, 8):
                    if 0 < rec['x'] < 6 and 0 < rec['y'] < 4:
                        assert (rec['r'], rec['g'], rec['b']) == (17, 91, 203)
                    else:
                        # border channels remain within the min/max span of
                        # the clamped 3x3 taps (averages of real samples).
                        tv = list(taps3x3(mos, rec['x'], rec['y']).values())
                        assert all(min(tv) <= c <= max(tv)
                                   for c in (rec['r'], rec['g'], rec['b']))
                cases += 1
    # Known answer 2: uniform mosaic -> gray output equal to input.
    for cfg in (Config(0, 0, 0), Config(3, 1, 1)):
        for rec in demosaic(frame(4, 4, 'uniform', 8, 5), cfg, 8):
            assert rec['r'] == rec['g'] == rec['b'] == rec['pixel']
        cases += 1
    # Known answer 3: hand-computed 3x3 RGGB center + corners.
    #   R G R / G B G / R G R with distinct values.
    img = [[10, 20, 30], [40, 50, 60], [70, 80, 90]]
    got = demosaic(img, Config(0, 0, 0), 8)
    # center (1,1) is B site: B=50, G=(20+80+40+60)>>2=50, R=(10+30+70+90)>>2=50
    assert (got[4]['r'], got[4]['g'], got[4]['b']) == (50, 50, 50)
    # (0,0) R site with REPLICATE taps: R=10,
    #   cross taps up=10(dn clamp),dn=40,lf=10,rt=20 -> g=(10+40+10+20)>>2=20
    #   diag taps tl=10,tr=20,bl=40,br=50 -> b=(10+20+40+50)>>2=30
    assert (got[0]['r'], got[0]['g'], got[0]['b']) == (10, 20, 30)
    # (1,0) G on R row: G=20, R=(lf+rt)>>1=(10+30)>>1=20,
    #   B=(up+dn)>>1=(20+50)>>1=35 (up is replicated row-0 value at (1,-1)=20)
    assert (got[1]['r'], got[1]['g'], got[1]['b']) == (20, 20, 35)
    cases += 1
    # taps3x3 clamp semantics spot check.
    t = taps3x3([[1, 2], [3, 4]], 0, 0)
    assert t['tl'] == t['up'] == t['lf'] == t['c'] == 1
    assert t['tr'] == t['rt'] == 2 and t['bl'] == t['dn'] == 3 and t['br'] == 4
    cases += 1
    # Illegal configurations must raise.
    bad = [dict(cfa=4), dict(cfa=-1), dict(ox=2), dict(oy=-1),
           dict(reserved=1), dict(reserved=9)]
    for kw in bad:
        try:
            Config(**kw)
        except ValueError:
            cases += 1
        else:
            raise AssertionError('illegal config accepted: %r' % kw)
    # Demosaic must reject bad frames / over-range pixels.
    for call in (lambda: demosaic([], Config(), 8),
                 lambda: demosaic([[1], [2, 3]], Config(), 8),
                 lambda: demosaic([[300]], Config(), 8),
                 lambda: demosaic_float([[-1]], Config())):
        try:
            call()
        except ValueError:
            cases += 1
        else:
            raise AssertionError('illegal input accepted')
    out = HERE / 'evidence' / 'model_validation.json'
    out.parent.mkdir(exist_ok=True)
    summary = {
        'status': 'PASS', 'cases': cases,
        'checks': ['R/B/G site phases for all cfa',
                   'origin-shift pattern identities',
                   'float rational semantics vs integer contract',
                   'site channel copied exactly',
                   'per-channel-constant mosaic exact reconstruction',
                   'REPLICATE clamp boundary taps',
                   'hand-computed 3x3 known answers',
                   'illegal config/input rejection'],
        'scope': 'model-only; no RTL/board claim',
        'time': datetime.datetime.now().isoformat(timespec='seconds'),
    }
    out.write_text(json.dumps(summary, indent=2))
    print('PASS model cases=%d -> %s' % (cases, out))


if __name__ == '__main__':
    main()
