"""DSP-05 spectrum pre/post processing: float and bit-exact references.

Data formats (see SPEC.md):
  real sample   signed16 Q1.15
  complex sample paired {i,q} on one 32-bit beat, i in low 16 bits
  window coefficient signed18 Q3.15 (1.0 = 32768)
  cosine ROM    signed18 Q3.15, 4096-phase resolution, quarter-wave 0..1024
  mag_squared   unsigned32 integer power units
  block_accum   record {sum[31:0] signed, mean[15:0] signed}
  peak_search   record {index[15:0], magnitude[31:0]}

All rounding is nearest, ties to even (RNE). Block length N = 2**log2n,
log2n = 4..12 (N = 16..4096). Bin/sample index n counts 0..N-1 in arrival
order from the first accepted sample after reset or an accepted legal config.
"""
import math

SAMPLE_MIN, SAMPLE_MAX = -32768, 32767
COEF_MIN, COEF_MAX = -131072, 131071
MIN_LOG2N, MAX_LOG2N = 4, 12
PHASES = 4096
WINDOW_NAMES = {0: 'unity', 1: 'hann', 2: 'hamming', 3: 'blackman', 4: 'custom'}
# Quantized window constants, signed18 Q3.15: w[n] = A0 - A1*cos(t) + A2*cos(2t)
# with t = 2*pi*n/N (periodic / DFT-even window form).
WIN_CONST = {0: (32768, 0, 0), 1: (16384, 16384, 0),
             2: (17695, 15073, 0), 3: (13763, 16384, 2621)}
WIN_FLOAT = {1: (.5, .5, .0), 2: (.54, .46, .0), 3: (.42, .5, .08)}


def rne(n, d):
    """round(n/d), halves to even. d positive int (power of two in hardware)."""
    if d <= 0:
        raise ValueError('divisor')
    q, r = divmod(n, d)
    q += 2 * r > d or (2 * r == d and q & 1)
    return q


def sat(v, lo, hi):
    return min(hi, max(lo, v))


def sat16(v):
    return sat(v, SAMPLE_MIN, SAMPLE_MAX)


def sat18(v):
    return sat(v, COEF_MIN, COEF_MAX)


def check_log2n(log2n):
    return MIN_LOG2N <= log2n <= MAX_LOG2N


# --- window_mult -----------------------------------------------------------

COS = [round(math.cos(2 * math.pi * i / PHASES) * 32768) for i in range(1025)]


def cos_q15(phase):
    """Bit-exact cosine ROM read: signed18 Q3.15 of cos(2*pi*phase/4096)."""
    phase &= 4095
    q, r = divmod(phase, 1024)
    if q == 0:
        return COS[r]
    if q == 1:
        return -COS[1024 - r]
    if q == 2:
        return -COS[r]
    return COS[1024 - r]


def window_coeff(n, log2n, wtype, table=None):
    """Signed18 Q3.15 window coefficient for index n of block N=2**log2n."""
    if not check_log2n(log2n) or not 0 <= n < (1 << log2n):
        raise ValueError('index')
    if wtype == 4:
        if table is None or len(table) < (1 << log2n):
            raise ValueError('custom table')
        c = table[n]
        if not COEF_MIN <= c <= COEF_MAX:
            raise ValueError('coefficient range')
        return c
    if not 0 <= wtype <= 3:
        raise ValueError('window type')
    a0, a1, a2 = WIN_CONST[wtype]
    p = (n << (MAX_LOG2N - log2n)) & 4095
    c1, c2 = cos_q15(p), cos_q15(p << 1)
    return sat18(rne((a0 << 15) - a1 * c1 + a2 * c2, 1 << 15))


def window_sample(x, n, log2n, wtype, shift=0, table=None):
    """(windowed signed16, clip). x signed16 Q1.15, shift -8..15."""
    if not SAMPLE_MIN <= x <= SAMPLE_MAX:
        raise ValueError('sample range')
    if not -8 <= shift <= 15:
        raise ValueError('shift')
    w = window_coeff(n, log2n, wtype, table)
    q = rne(x * w, 1 << (15 + shift))
    return sat16(q), int(not SAMPLE_MIN <= q <= SAMPLE_MAX)


def window_stream(xs, log2n, wtype, shift=0, table=None):
    n = 1 << log2n
    return [window_sample(x, i % n, log2n, wtype, shift, table)
            for i, x in enumerate(xs)]


def float_window(n, N, wtype):
    """Exact real-valued periodic window coefficient."""
    if wtype == 0:
        return 1.0
    a0, a1, a2 = WIN_FLOAT[wtype]
    t = 2 * math.pi * n / N
    return a0 - a1 * math.cos(t) + a2 * math.cos(2 * t)


def gen_window_table(log2n, wtype):
    """Quantized signed18 Q3.15 upload table; identical to internal window."""
    return [window_coeff(n, log2n, wtype) for n in range(1 << log2n)]


def coherent_gain(table):
    """CG = mean(w)/32768 for a signed18 Q3.15 table."""
    return sum(table) / (32768 * len(table))


# --- mag_squared -----------------------------------------------------------

def mag_squared(i, q, shift=0):
    """(power u32, clip). i,q signed16; shift 0..15 RNE right shift."""
    if not SAMPLE_MIN <= i <= SAMPLE_MAX or not SAMPLE_MIN <= q <= SAMPLE_MAX:
        raise ValueError('sample range')
    if not 0 <= shift <= 15:
        raise ValueError('shift')
    v = rne(i * i + q * q, 1 << shift)
    return sat(v, 0, 0xFFFFFFFF), int(not 0 <= v <= 0xFFFFFFFF)


# --- block_accum -----------------------------------------------------------

def accum_records(xs, log2n):
    """One (sum, mean, clip) record per complete block; tail ignored."""
    if not check_log2n(log2n):
        raise ValueError('log2n')
    n = 1 << log2n
    out = []
    for b in range(len(xs) // n):
        s = sum(xs[b * n:(b + 1) * n])
        m = rne(s, n)
        out.append((s, sat16(m), int(not SAMPLE_MIN <= m <= SAMPLE_MAX)))
    return out


# --- peak_search -----------------------------------------------------------

def peak_records(vals, log2n, thr_en=0, threshold=0):
    """One (index, magnitude, thr_met) record per complete block.

    Earliest index wins ties. threshold is unsigned32; thr_met=1 always
    when thr_en=0.
    """
    if not check_log2n(log2n) or thr_en not in (0, 1):
        raise ValueError('config')
    if not 0 <= threshold <= 0xFFFFFFFF:
        raise ValueError('threshold')
    n = 1 << log2n
    out = []
    for b in range(len(vals) // n):
        blk = vals[b * n:(b + 1) * n]
        bi, bv = 0, blk[0]
        for i, v in enumerate(blk):
            if not 0 <= v <= 0xFFFFFFFF:
                raise ValueError('bin range')
            if v > bv:
                bi, bv = i, v
        out.append((bi, bv, int((not thr_en) or bv >= threshold)))
    return out


# --- config legality (whole-field reject contract) -------------------------

def valid_window_cfg(log2n, wtype, shift):
    return check_log2n(log2n) and 0 <= wtype <= 4 and -8 <= shift <= 15


def valid_mag_cfg(shift):
    return 0 <= shift <= 15


def valid_accum_cfg(log2n):
    return check_log2n(log2n)


def valid_peak_cfg(log2n, thr_en):
    return check_log2n(log2n) and thr_en in (0, 1)
