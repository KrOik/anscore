"""Independent floating-point and bit-exact references for INFRA-05 fixed-point cores.

Pure standard library only. Every bit-exact function replicates the RTL
algorithm operation for operation; floating-point helpers quantify the error
of the same configuration against real-valued math. The two are never mixed:
`test_models.py` measures the bit-exact model against floats, `test_rtl.py`
compares RTL against the bit-exact model only.
"""
import math

TAB_P = 30
# round(log2(1+2^-j) * 2^TAB_P), j = 1..40. Values >= j=32 round to zero and are
# retained so parameter ranges never index past the table.
TAB30 = [0] + [round(math.log2(1 + 2.0**-j) * (1 << TAB_P)) for j in range(1, 41)]


def _ltab(j, p):
    """Table entry used by RTL/model at internal precision p (truncated shift)."""
    return TAB30[j] >> (TAB_P - p)


def rne(v, s):
    """Round v / 2**s to the nearest integer, ties to even. Works for v < 0."""
    if s <= 0:
        return v
    q, r = divmod(v, 1 << s)  # floor division keeps fraction in [0,1)
    h = 1 << (s - 1)
    if r > h or (r == h and q & 1):
        q += 1
    return q


def sat(v, w):
    """Saturate v to signed w bits; returns (value, clipped)."""
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    return (min(hi, max(lo, v)), int(not lo <= v <= hi))


def usat(v, w):
    """Saturate v to unsigned w bits; returns (value, clipped)."""
    hi = (1 << w) - 1
    return (min(hi, max(0, v)), int(not 0 <= v <= hi))


def _signed(v, w):
    return v - (1 << w) if v >= (1 << (w - 1)) else v


# ---------------------------------------------------------------- sat_round
def sat_round_model(v, in_w, shift, out_w, signed_in=1):
    """y = saturate_outw(RNE(v / 2**shift)); flags (clip, inexact)."""
    if signed_in:
        v = _signed(v & ((1 << in_w) - 1), in_w)
    else:
        v &= (1 << in_w) - 1
    q = rne(v, shift)
    r, clip = sat(q, out_w)
    inexact = int(shift > 0 and (v & ((1 << shift) - 1)) != 0)
    return r, (clip, inexact)


def sat_round_float(v, shift):
    return v / (1 << shift)


# ----------------------------------------------------------------- cplx_mac
def cplx_mac_model(beats, data_w, acc_w, out_w, shift):
    """One accumulation run: sum a*b over beats of (a_re,a_im,b_re,b_im) signed.

    Accumulator saturates per update at ACC_W with a sticky overflow flag.
    Output is RNE(acc/2**shift) saturated to OUT_W per component.
    Returns ((re,im),(clip,ovf)) or None for an empty run.
    """
    lo, hi = -(1 << (acc_w - 1)), (1 << (acc_w - 1)) - 1
    acc_r = acc_i = 0
    have = False
    ovf = 0
    for a_re, a_im, b_re, b_im in beats:
        tr = a_re * b_re - a_im * b_im
        ti = a_re * b_im + a_im * b_re
        for name, term in (('r', tr), ('i', ti)):
            base = (acc_r if name == 'r' else acc_i) if have else 0
            s = base + term
            if s > hi:
                s, ovf = hi, 1
            elif s < lo:
                s, ovf = lo, 1
            if name == 'r':
                acc_r = s
            else:
                acc_i = s
        have = True
    if not have:
        return None
    rr, c1 = sat(rne(acc_r, shift), out_w)
    ri, c2 = sat(rne(acc_i, shift), out_w)
    return (rr, ri), (c1 | c2, ovf)


def cplx_mac_float(beats, shift):
    """Complex accumulate on real values, no saturation."""
    acc = sum(complex(a_re, a_im) * complex(b_re, b_im) for a_re, a_im, b_re, b_im in beats)
    return acc / (1 << shift)


# ----------------------------------------------------------------- division
def div_model(a, b, aw, bw, fb, out_w):
    """q = saturate_outw(RNE(a * 2**fb / b)) for signed a,b.

    b == 0 -> defined output: a < 0 gives OUT_MIN else OUT_MAX, flags (1,1).
    Returns (q, (div0, clip)).
    """
    a = _signed(a & ((1 << aw) - 1), aw)
    b = _signed(b & ((1 << bw) - 1), bw)
    lo, hi = -(1 << (out_w - 1)), (1 << (out_w - 1)) - 1
    if b == 0:
        return (lo if a < 0 else hi), (1, 1)
    ua, ub = abs(a), abs(b)
    q, r = divmod(ua << fb, ub)
    if 2 * r > ub or (2 * r == ub and q & 1):
        q += 1
    if (a < 0) != (b < 0):
        q = -q
    out, clip = sat(q, out_w)
    return out, (0, clip)


def div_float(a, b, fb):
    return None if b == 0 else a * (1 << fb) / b


# --------------------------------------------------------------------- sqrt
def sqrt_model(x, in_w, fb):
    """r = RNE(sqrt(x) * 2**fb); flags (zero, exact). x is unsigned in_w bits."""
    x &= (1 << in_w) - 1
    n = (in_w + 2 * fb + 1) // 2
    op = x << (2 * fb)
    rem = root = 0
    for i in range(n):
        rem = (rem << 2) | ((op >> (2 * (n - 1 - i))) & 3)
        t = (root << 2) | 1
        if rem >= t:
            rem -= t
            root = (root << 1) | 1
        else:
            root <<= 1
    if rem > root:
        root += 1
    return root, (int(x == 0), int(rem == 0))


def sqrt_float(x, fb):
    return math.sqrt(x) * (1 << fb)


# --------------------------------------------------------------------- log2
def log2_out_w(in_w, fb):
    return fb + (in_w - 1).bit_length() + 1


def log2_model(x, in_w, fb, g, signed_in=0):
    """y = log2(x) as signed Q(log2_out_w-fb).fb. Abnormal input -> (MIN,1)."""
    p = fb + g
    if p > TAB_P - 2:
        raise ValueError('internal precision P must be <= TAB_P-2')
    if in_w - 1 > p:
        raise ValueError('IN_W-1 must be <= FB+G')
    out_w = log2_out_w(in_w, fb)
    abnormal = (_signed(x & ((1 << in_w) - 1), in_w) <= 0) if signed_in else (x == 0)
    if abnormal:
        return -(1 << (out_w - 1)), 1
    ux = _signed(x & ((1 << in_w) - 1), in_w) if signed_in else x
    k = ux.bit_length() - 1
    m = ux << (p - k)  # [2**p, 2**(p+1)) i.e. Q1.p in [1,2)
    f = 0
    for j in range(1, p + 3):
        t = m + (m >> j)
        if t < (2 << p):
            m = t
            f += _ltab(j, p)
    val = ((k + 1) << p) - f  # log2(x) * 2**p
    return rne(val, p - fb), 0


def log2_float(x):
    return math.log2(x)


# --------------------------------------------------------------------- exp2
def exp2_model(xn, iw, fb, g, out_w, fraco):
    """y = saturate_uoutw(RNE(2**(xn/2**fb) * 2**fraco)); flags (clip,under)."""
    p = fb + g
    if p > TAB_P - 2:
        raise ValueError('internal precision P must be <= TAB_P-2')
    xn = _signed(xn & ((1 << iw) - 1), iw)
    k = xn >> fb
    rem = (xn & ((1 << fb) - 1)) << (p - fb)
    r = 1 << p
    for j in range(1, p + 3):
        lj = _ltab(j, p)
        if rem >= lj:
            rem -= lj
            r += r >> j
    s = k + fraco - p
    if s >= 0:
        threshold = ((1 << out_w) - 1) >> s
        if r > threshold:
            return (1 << out_w) - 1, (1, 0)
        return r << s, (0, int(r << s == 0))
    q = rne(r, -s)
    if q > (1 << out_w) - 1:
        return (1 << out_w) - 1, (1, 0)
    return q, (0, int(q == 0))


def exp2_float(xn, fb, fraco):
    return 2.0 ** (xn / (1 << fb)) * (1 << fraco)
