"""Independent float and bit-exact references for DSP-10.

Half-band 2x decimator/interpolator and CIC-compensation symmetric FIR.
Samples are signed16 Q1.15. Coefficients are signed18 Q3.15 (32768 == 1.0).
All integer models below mirror the RTL exactly: folded symmetric pair sums
(signed17), signed18 x signed17 products, one shared accumulation, and a
single round-nearest-even + saturate at the output. No intermediate wrap.

Half-band structure contract (odd taps T, center c=(T-1)/2):
  * h[c] == 0.5 exactly (implicit, not configured)
  * h[n] == 0 for all n != c with (n-c) even (structural, not configured)
  * h[n] == h[T-1-n] (structural symmetry)
  * P = pairs_of(T) configurable nonzero unique coefficients u_i multiply
    the symmetric pairs (lo_i, T-1-lo_i) with lo_i = 2i + (T%4==1).
"""
import math
import cmath
from dataclasses import dataclass

PAIRS_MAX = 9                      # hardware unique-pair capacity
HB_MAX_TAPS = 4 * PAIRS_MAX + 1    # 37
COMP_MAX_TAPS = 31                 # cic_comp_fir maximum odd taps
COMP_U_MAX = (COMP_MAX_TAPS + 1) // 2


def rne(v, b=15):
    """Round-half-even of signed integer v / 2**b."""
    q = v >> b
    r = v & ((1 << b) - 1)
    return q + (r > (1 << (b - 1)) or (r == (1 << (b - 1)) and q & 1))


def sat16(v):
    return min(32767, max(-32768, v))


def clip16(v):
    s = sat16(v)
    return s, int(s != v)


# ------------------------------------------------------------ structure
def pairs_of(taps):
    """Number of configurable nonzero symmetric pairs of halfband length T."""
    if not isinstance(taps, int) or taps % 2 == 0 or not 3 <= taps:
        raise ValueError('halfband taps must be odd and >=3')
    return (taps - 1) // 4 if taps % 4 == 1 else (taps + 1) // 4


def check_halfband_taps(taps, max_pairs=PAIRS_MAX):
    if not isinstance(taps, int) or taps % 2 == 0:
        raise ValueError('halfband taps must be odd')
    if not 3 <= taps <= 4 * max_pairs + 1:
        raise ValueError('taps out of range')
    if pairs_of(taps) > max_pairs:
        raise ValueError('too many nonzero pairs')


def lo_index(taps, i):
    """First-half tap index of unique coefficient i (i < pairs_of(taps))."""
    return 2 * i + (1 if taps % 4 == 1 else 0)


def check_comp_taps(taps, max_taps=COMP_MAX_TAPS):
    if not isinstance(taps, int) or taps % 2 == 0 or not 3 <= taps <= max_taps:
        raise ValueError('comp taps must be odd in 3..%d' % max_taps)


def expand_halfband(taps, ucoeffs):
    """Full integer tap vector from P unique nonzero coefficients."""
    check_halfband_taps(taps)
    if len(ucoeffs) != pairs_of(taps):
        raise ValueError('unique coefficient count mismatch')
    if any(not -131072 <= c <= 131071 for c in ucoeffs):
        raise ValueError('signed18 coefficient required')
    h = [0] * taps
    c = (taps - 1) // 2
    for i, u in enumerate(ucoeffs):
        n = lo_index(taps, i)
        h[n] = h[taps - 1 - n] = u
    h[c] = 16384
    return h


def expand_comp(taps, ucoeffs):
    """Full integer tap vector from U=(T+1)/2 unique symmetric coefficients."""
    check_comp_taps(taps)
    if len(ucoeffs) != (taps + 1) // 2:
        raise ValueError('unique coefficient count mismatch')
    if any(not -131072 <= c <= 131071 for c in ucoeffs):
        raise ValueError('signed18 coefficient required')
    h = [0] * taps
    for k, g in enumerate(ucoeffs):
        h[k] = h[taps - 1 - k] = g
    return h


# ------------------------------------------------------- coefficient design
def _blackman(n, taps):
    return 0.42 - 0.5 * math.cos(2 * math.pi * n / (taps - 1)) \
        + 0.08 * math.cos(4 * math.pi * n / (taps - 1))


def design_halfband(taps):
    """Blackman-windowed sinc halfband, cutoff fs/4.

    Returns (unique_coeffs tuple, float full taps, integer full taps).
    The largest unique coefficient is adjusted so sum(u_i) == 8192 exactly:
    DC gain is exactly 1.0 and each interpolation polyphase branch sums to
    exactly 0.5 after quantization.
    """
    check_halfband_taps(taps)
    c = (taps - 1) // 2
    p = pairs_of(taps)
    h = [0.0] * taps
    for i in range(p):
        n = lo_index(taps, i)
        t = n - c                                    # always odd
        v = math.sin(math.pi * t / 2) / (math.pi * t) * _blackman(n, taps)
        h[n] = h[taps - 1 - n] = v
    h[c] = 0.5
    u = [round(h[lo_index(taps, i)] * 32768) for i in range(p)]
    delta = 8192 - sum(u)
    if delta:
        k = max(range(p), key=lambda i: abs(u[i]))
        u[k] += delta
    uc = tuple(u)
    hq = expand_halfband(taps, uc)
    assert sum(hq) == 32768
    return uc, h, hq


def cic_mag(order, rate, f_out):
    """Normalized CIC decimator magnitude vs output-rate frequency.

    |H(f)| = |sin(pi f) / (R sin(pi f/R))|^N, f in cycles/output-sample.
    DC is exactly 1; the first null sits at f=1.0 (outside output Nyquist).
    """
    if f_out <= 0.0:
        return 1.0
    return abs(math.sin(math.pi * f_out)
               / (rate * math.sin(math.pi * f_out / rate))) ** order


def _solve(A, b):
    """Gauss-Jordan with partial pivoting; small well-conditioned systems."""
    n = len(A)
    m = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c and m[r][c]:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def design_ciccomp(order, rate, taps, fp=0.2, fstop=None, wstop=16.0):
    """Weighted least-squares inverse-droop symmetric FIR, odd taps.

    Desired response: 1/CIC(f) on [0, fp] (weight 1) and 0 on
    [fstop, 0.5] (weight wstop); the transition band between is free.
    fp/fstop are cycles per *output* sample (fp/rate per input sample).
    Returns (unique_coeffs tuple length (taps+1)/2, float unique coeffs,
    integer full taps). The center tap is chosen for an exact integer DC
    gain of 1.0.
    """
    check_comp_taps(taps)
    if not 1 <= order <= 8 or not 2 <= rate <= 64:
        raise ValueError('unsupported CIC order/rate')
    if fstop is None:
        fstop = min(0.5, fp + 0.15)
    if not 0.01 <= fp < fstop <= 0.5:
        raise ValueError('need 0 < fp < fstop <= 0.5')
    c = (taps - 1) // 2
    u = (taps + 1) // 2
    rows = []
    for i in range(257):
        f = fp * i / 256
        rows.append(([2 * math.cos(2 * math.pi * f * (c - k))
                     for k in range(u - 1)] + [1.0],
                    1.0 / cic_mag(order, rate, f), 1.0))
    for i in range(257):
        f = fstop + (0.5 - fstop) * i / 256
        rows.append(([2 * math.cos(2 * math.pi * f * (c - k))
                     for k in range(u - 1)] + [1.0], 0.0, wstop))
    ata = [[0.0] * u for _ in range(u)]
    atb = [0.0] * u
    for b, d, w in rows:
        for a in range(u):
            atb[a] += w * b[a] * d
            for bb in range(u):
                ata[a][bb] += w * b[a] * b[bb]
    g = _solve(ata, atb)
    qi = [round(x * 32768) for x in g[:u - 1]]
    qi.append(32768 - 2 * sum(qi))                   # exact DC = 1.0
    uc = tuple(qi)
    hq = expand_comp(taps, uc)
    assert sum(hq) == 32768
    return uc, g, hq


# ------------------------------------------------------- bit-exact models
def _output(acc):
    """Shared output stage: RNE /2**15 then signed16 saturate."""
    wide = rne(acc)
    return sat16(wide), int(not -32768 <= wide <= 32767)


def decim_int(samples, taps, ucoeffs, flush=True):
    """y[m] = sum_n x[2m-n] h[n]; outputs in order m=0,1,...

    Without flush only outputs whose last required input (index 2m) has
    arrived are produced. With flush the full convolution support
    2m <= N-1+T-1 is emitted using virtual zeros.
    """
    h = expand_halfband(taps, ucoeffs)
    n = len(samples)
    if n == 0:
        return []
    last = n - 1 + taps - 1 if flush else 2 * ((n - 1) // 2)
    out = []
    for m in range(last // 2 + 1):
        t = 2 * m
        acc = sum(samples[k] * h[t - k]
                  for k in range(n) if 0 <= t - k < taps)
        out.append(_output(acc))
    return out


def decim_stream_count(n, taps):
    """Outputs emitted while streaming N real inputs (no flush)."""
    return 0 if n == 0 else (n - 1) // 2 + 1


def decim_total_count(n, taps):
    """Total outputs after flush (0 for an empty block)."""
    return 0 if n == 0 else (n + taps - 2) // 2 + 1


def interp_int(samples, taps, ucoeffs, flush=True):
    """y[t] = sum_k x[k] h[t-2k]; two outputs per input in order.

    The shared halfband table has sum h = 1 (center 0.5, phase sums 0.5).
    Interpolation applies the standard x2 gain so the output keeps the
    input amplitude: the delay phase emits x[n-d] exactly, the filtered
    phase emits RNE(2*acc/2**15). Ordering follows the tap form.
    Virtual zero inputs after flush emit the remaining T-2 outputs (the
    (T-1)/2-th virtual input produces only its first output; the trailing
    t=2N+T-2 output would be a structural zero and is not emitted).
    """
    check_halfband_taps(taps)
    p = pairs_of(taps)
    if len(ucoeffs) != p:
        raise ValueError('unique coefficient count mismatch')
    n = len(samples)
    if n == 0:
        return []
    total = 2 * n + taps - 2 if flush else 2 * n
    d = 2 * p - 1
    ddir = p if taps % 4 == 1 else p - 1
    direct_first = taps % 4 == 1

    def xq(k):
        return samples[k] if 0 <= k < n else 0

    out = []
    for t in range(total):
        nn = t // 2
        if (t % 2 == 0) == direct_first:
            out.append((xq(nn - ddir), 0))
        else:
            acc = sum(ucoeffs[i] * (xq(nn - i) + xq(nn - (d - i)))
                      for i in range(p))
            wide = rne(acc, 14)
            out.append((sat16(wide), int(not -32768 <= wide <= 32767)))
    return out


def comp_int(samples, taps, ucoeffs, flush=True):
    """Causal symmetric FIR y[n]=sum g[k] x[n-k]; flush drains N+T-1."""
    h = expand_comp(taps, ucoeffs)
    n = len(samples)
    if n == 0:
        return []
    total = n + taps - 1 if flush else n
    out = []
    for t in range(total):
        acc = sum(samples[k] * h[t - k]
                  for k in range(n) if 0 <= t - k < taps)
        out.append(_output(acc))
    return out


# --------------------------------------------------------- float models
def decim_float(samples, taps, h, flush=True):
    n = len(samples)
    if n == 0:
        return []
    last = n - 1 + taps - 1 if flush else 2 * ((n - 1) // 2)
    return [math.fsum(samples[k] / 32768 * h[2 * m - k]
                      for k in range(n) if 0 <= 2 * m - k < taps)
            for m in range(last // 2 + 1)]


def interp_float(samples, taps, h, flush=True):
    """Float interpolator with the same x2 output gain as interp_int."""
    n = len(samples)
    if n == 0:
        return []
    total = 2 * n + taps - 2 if flush else 2 * n
    return [2 * math.fsum(samples[k] / 32768 * h[t - 2 * k]
                          for k in range(n) if 0 <= t - 2 * k < taps)
            for t in range(total)]


def comp_float(samples, taps, h, flush=True):
    n = len(samples)
    if n == 0:
        return []
    total = n + taps - 1 if flush else n
    return [math.fsum(samples[k] / 32768 * h[t - k]
                      for k in range(n) if 0 <= t - k < taps)
            for t in range(total)]


# ------------------------------------------------------------ spectrum
def response(taps_full, f):
    """Quantized FIR response at cycles/sample f; coefficients are ints."""
    return sum(c / 32768 * cmath.exp(-2j * math.pi * f * k)
               for k, c in enumerate(taps_full))


def halfband_metrics(taps, ucoeffs, pass_edge=0.2, stop_edge=0.3):
    """Measured quantized metrics; edges are cycles/input (decim) or
    cycles/output (interp) sample — the filter runs at the high rate."""
    hq = expand_halfband(taps, ucoeffs)
    pv = [abs(response(hq, pass_edge * i / 256)) for i in range(257)]
    sv = [abs(response(hq, stop_edge + (0.5 - stop_edge) * i / 256))
          for i in range(257)]
    return {'taps': taps, 'pass_edge': pass_edge, 'stop_edge': stop_edge,
            'dc_gain': abs(response(hq, 0.0)),
            'nyquist_gain': abs(response(hq, 0.5)),
            'passband_max_abs_db': max(
                abs(20 * math.log10(max(v, 1e-15))) for v in pv),
            'stopband_attenuation_db':
                -20 * math.log10(max(max(sv), 1e-15))}


def ciccomp_metrics(order, rate, taps, ucoeffs, fp, stop_edge=None):
    """Measured composite CIC*comp flatness on [0,fp] and own stopband."""
    hq = expand_comp(taps, ucoeffs)
    if stop_edge is None:
        stop_edge = min(0.5, fp + 0.15)
    comp = [abs(response(hq, fp * i / 256)) for i in range(257)]
    worst = 0.0
    for i in range(257):
        f = fp * i / 256
        c = cic_mag(order, rate, f) * comp[i]
        worst = max(worst, abs(20 * math.log10(max(c, 1e-15))))
    sv = [abs(response(hq, stop_edge + (0.5 - stop_edge) * i / 256))
          for i in range(257)]
    return {'order': order, 'rate': rate, 'taps': taps, 'fp': fp,
            'stop_edge': stop_edge,
            'dc_gain': abs(response(hq, 0.0)),
            'corrected_max_abs_db': worst,
            'stopband_attenuation_db':
                -20 * math.log10(max(max(sv), 1e-15))}
