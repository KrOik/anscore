"""Validate INFRA-05 bit-exact models against independent float math.

Pure stdlib. Checks RNE/saturation identities exhaustively on small widths,
divider/sqrt on directed + random vectors, and measures worst-case error of
the log2/exp2 shift-add algorithms against math.log2 / 2**x.
"""
import sys, json, math, random, hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (rne, sat, sat_round_model, cplx_mac_model, div_model,
                       sqrt_model, log2_model, exp2_model, log2_out_w, TAB30)

rng = random.Random(0x1F05)
report = {}

# --- rne: independent definition check (floor + nearest-even) --------------
for v in range(-2000, 2001):
    for s in range(0, 6):
        got = rne(v, s)
        want = math.floor(v / (1 << s) + 0.5)
        frac = v / (1 << s) - math.floor(v / (1 << s))
        if abs(frac - 0.5) < 1e-12:
            want = 2 * round(v / (1 << s) / 2)
        assert got == want, (v, s, got, want)

# --- sat_round: exhaustive on small geometry -------------------------------
for v in range(-128, 128):
    y, (clip, inex) = sat_round_model(v, 8, 3, 6)
    ref = v / 8
    assert clip == (rne(v, 3) != y), (v, y, clip)
    assert inex == int((v & 7) != 0), (v, inex)
    assert -32 <= y <= 31
    d = abs(y - ref)
    assert d <= 0.5 or (clip and y in (-32, 31))
for v in range(0, 256):
    y, (clip, _) = sat_round_model(v, 8, 3, 6, signed_in=0)
    assert 0 <= y <= 31 and (abs(y - v / 8) <= 0.5 or (clip and y == 31))
report['sat_round'] = 'exhaustive 8->6 bit shift3 + unsigned mode'

# --- cplx_mac: no saturation error when within range -----------------------
for trial in range(400):
    n = rng.randrange(1, 9)
    beats = [(rng.randrange(-32768, 32768), rng.randrange(-32768, 32768),
              rng.randrange(-32768, 32768), rng.randrange(-32768, 32768))
             for _ in range(n)]
    (rr, ri), (clip, ovf) = cplx_mac_model(beats, 16, 48, 32, 0)
    acc = sum(complex(a, b) * complex(c, d) for a, b, c, d in beats)
    assert not ovf  # 8 beats of |term|<=2**31 cannot reach 2**47
    want_clip = int(not (-(1 << 31) <= acc.real <= (1 << 31) - 1) or
                    not (-(1 << 31) <= acc.imag <= (1 << 31) - 1))
    assert clip == want_clip
    sr, _ = sat(int(acc.real), 32); si, _ = sat(int(acc.imag), 32)
    assert (rr, ri) == (sr, si), (rr, ri, acc)
# forced accumulator saturation, ACC_W deliberately small
beats = [(32767, 32767, 32767, 32767)] * 20
(rr, ri), (clip, ovf) = cplx_mac_model(beats, 16, 34, 32, 0)
assert ovf and clip and rr == 0 and ri == (1 << 31) - 1  # re cancels, im clamps
report['cplx_mac'] = '400 random runs exact + forced saturation'

# --- div: exhaustive small, then random default ----------------------------
for a in range(-64, 65):
    for b in range(-64, 65):
        q, (d0, cl) = div_model(a, b, 8, 8, 4, 10)
        if b == 0:
            assert d0 and cl and q == (-512 if a < 0 else 511)
        else:
            ref = a * 16 / b
            assert not d0 and abs(q - ref) <= 0.5 or cl
            assert -512 <= q <= 511
# RNE tie check: a*16/b exact .5 cases
q, _ = div_model(3, 32, 8, 8, 4, 10)   # 1.5 -> 2 (odd side)
assert q == 2, q
q, _ = div_model(5, 32, 8, 8, 4, 10)   # 2.5 -> 2 (even side)
assert q == 2, q
q, _ = div_model(-3, 32, 8, 8, 4, 10)  # -1.5 -> -2
assert q == -2, q
q, _ = div_model(-5, 32, 8, 8, 4, 10)  # -2.5 -> -2
assert q == -2, q
worst = 0
for _ in range(30000):
    a = rng.randrange(-32768, 32768)
    b = rng.randrange(-32768, 32768)
    q, (d0, cl) = div_model(a, b, 16, 16, 15, 18)
    if b == 0:
        assert d0 and cl
        continue
    ref = a * (1 << 15) / b
    if not cl:
        assert abs(q - ref) <= 0.5, (a, b, q, ref)
        worst = max(worst, abs(q - ref))
    assert -(1 << 17) <= q <= (1 << 17) - 1
report['div'] = {'small_exhaustive': '64x64', 'random': 30000,
                 'max_abs_err_lsb': worst}

# --- sqrt: exhaustive 16-bit vs math.isqrt ---------------------------------
for x in range(0, 65536):
    r, (z, ex) = sqrt_model(x, 16, 0)
    f = math.isqrt(x)
    assert z == int(x == 0) and ex == int(f * f == x)
    assert r == f or r == f + 1, (x, r, f)
    # RNE: r is nearest integer to sqrt(x)
    assert abs(r - math.sqrt(x)) <= 0.5, (x, r)
# fractional sqrt
worst = 0
for _ in range(30000):
    x = rng.randrange(0, 1 << 16)
    r, _ = sqrt_model(x, 16, 8)
    ref = math.sqrt(x) * 256
    assert abs(r - ref) <= 0.5, (x, r, ref)
    worst = max(worst, abs(r - ref))
report['sqrt'] = {'exhaustive_16bit': True, 'fb8_random': 30000,
                  'max_abs_err_lsb': worst}

# --- log2: exhaustive over 16-bit input ------------------------------------
worst = 0
arg = None
for x in range(1, 65536):
    y, ab = log2_model(x, 16, 12, 6)
    assert not ab
    e = abs(y / 4096 - math.log2(x))
    if e > worst:
        worst, arg = e, x
y, ab = log2_model(0, 16, 12, 6)
assert ab and y == -(1 << (log2_out_w(16, 12) - 1))
y, ab = log2_model(1, 16, 12, 6)
assert not ab and y == 0
# signed variant: nonpositive rejected
for x in (-5, 0):
    y, ab = log2_model(x & 0xFFFF, 16, 12, 6, signed_in=1)
    assert ab, x
y, ab = log2_model(1024, 16, 12, 6, signed_in=1)
assert not ab and y == 10 << 12
report['log2'] = {'exhaustive_16bit': True, 'max_err': worst,
                  'max_err_ulp': worst * 4096, 'argmax': arg}

# --- exp2: exhaustive over signed 16-bit input -----------------------------
worst = worst_abs = 0
arg = arg_abs = None
clip_c = under_c = 0
for xn in range(-32768, 32768):
    q, (cl, un) = exp2_model(xn, 16, 12, 6, 28, 12)
    ref = 2.0 ** (xn / 4096) * 4096
    if cl:
        clip_c += 1
        assert q == (1 << 28) - 1 and ref > (1 << 28) - 1
    elif un:
        under_c += 1
        assert q == 0 and ref < 0.5 + 1e-9
    else:
        ea = abs(q - ref)
        if ea > worst_abs:
            worst_abs, arg_abs = ea, xn
        if ref >= 64:
            e = ea / ref
            if e > worst:
                worst, arg = e, xn
report['exp2'] = {'exhaustive_16bit': True,
                  'max_rel_err_ref_ge_64lsb': worst,
                  'max_rel_ulp': worst * 4096, 'argmax': arg,
                  'max_abs_err_lsb': worst_abs, 'argmax_abs': arg_abs,
                  'clip_count': clip_c, 'under_count': under_c}
# narrower geometries exercise the clip and underflow paths
clip_c = 0
for xn in range(-32768, 32768):
    q, (cl, un) = exp2_model(xn, 16, 12, 6, 15, 8)
    ref = 2.0 ** (xn / 4096) * 256
    if cl:
        clip_c += 1
        assert q == (1 << 15) - 1 and ref > (1 << 15) - 1
    else:
        assert abs(q - ref) / ref < 2e-4 or abs(q - ref) < 1.0
assert clip_c > 0
under_c = 0
for xn in range(-32768, 32768):
    q, (cl, un) = exp2_model(xn, 16, 12, 6, 16, 4)
    ref = 2.0 ** (xn / 4096) * 16
    if un:
        under_c += 1
        assert q == 0 and ref <= 0.5  # RNE ties-to-even sends 0.5 -> 0
    else:
        assert not cl and abs(q - ref) / max(ref, 1e-9) < 2e-4 or abs(q - ref) < 1.0
assert under_c > 0
report['exp2_narrow'] = {'clip_cfg': 'out_w15 fraco8', 'clip_count': clip_c,
                         'under_cfg': 'out_w16 fraco4', 'under_count': under_c}

# --- illegal model parameters must raise ------------------------------------
for fn, args in [(log2_model, (5, 16, 12, 1)), (exp2_model, (1, 16, 12, 40, 28, 12))]:
    try:
        fn(*args)
    except ValueError:
        pass
    else:
        raise AssertionError(('illegal accepted', fn.__name__))

summary = {'status': 'PASS', 'report': report,
           'model_sha256': hashlib.sha256(
               (Path(__file__).resolve().parents[1] / 'models' /
                'reference.py').read_bytes()).hexdigest(),
           'scope': 'bit-exact model vs independent float math; no RTL/board'}
BASE = Path(__file__).resolve().parents[1]
out = BASE / 'evidence' / ('model_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
out.mkdir()
(out / 'summary.json').write_text(json.dumps(summary, indent=2))
print(out)
print(json.dumps(summary, indent=2))
