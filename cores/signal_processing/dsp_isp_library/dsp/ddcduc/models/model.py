"""Independent float and bit-exact references for DSP-03 (DDC/DUC chains).

Chain conventions shared by rtl/ddc_stream.sv and rtl/duc_stream.sv:

  * samples are signed16 Q1.15 complex pairs (i, q)
  * NCO: 32-bit phase accumulator, phase_k = (init + k*inc) mod 2**32, beat k
    uses the pre-increment phase.  sin/cos come from a 128-entry quarter-wave
    case ROM T[o]=round(32767*sin(pi*o/256)): effective 9-bit phase resolution
    (2 quadrant + 7 index bits), NO interpolation.
  * mixer (3-multiplier form, one rounding point):
      DDC: y = x*e^{-jphi}  i'=xi*c+xq*s  q'=xq*c-xi*s
      DUC: y = x*e^{+jphi}  i'=xi*c-xq*s  q'=xi*s+xq*c
    realized as m1=(xi+xq)*s plus xi*(c-s)/xq*(c+s)  (DDC) or
    xi*(c+s)/xq*(c-s) (DUC); the exact two's-complement arithmetic is in
    mix_ddc_int/mix_duc_int.
  * CIC: M=1, order N (static 1..4), rate R (runtime 2..64), 40-bit wrapping
    integrators/combs (Hogenauer modulo arithmetic; result fits for all legal
    configs).  Decimator: integrate at input rate, comb once per R inputs on
    the post-update accumulator.  Interpolator: comb once per input, then
    R zero-stuffed beats into the integrators.
  * scale: variable >>shift with round-nearest-even (half ties to even) then
    signed16 saturation.
  * FIR: symmetric odd taps T=3..31 (or 1 = bypass), unique coeffs signed18
    Q3.15 (32768 == 1.0), y[n] = sum_k g[k]*x[n-k] over zero-initialized
    history; one RNE+sat at output; every input produces exactly one output
    (no tail flush).

Rate contracts (exact, stall-independent):
  ddc: outputs = floor(inputs / R)
  duc: outputs = inputs * R
"""
import math
import cmath

W = 40                      # CIC internal width
MASK40 = (1 << W) - 1
QWAVE = tuple(round(32767 * math.sin(math.pi * i / 256)) for i in range(128))

R_MIN, R_MAX = 2, 64
N_MIN, N_MAX = 1, 4
SHIFT_MAX = 24
TAPS_MAX = 31               # odd; 1 selects FIR bypass


# ----------------------------------------------------------- primitives ---
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


def w40(v):
    """Signed interpretation of a 40-bit wrapping accumulator."""
    v &= MASK40
    return v - (1 << W) if v >> (W - 1) else v


def scale_shift(v, s):
    """RTL scale_sat: variable >>s with RNE then signed16 saturate."""
    if s == 0:
        q = v
    else:
        q = v >> s                                   # arithmetic (floor)
        rem = v & ((1 << s) - 1)
        half = 1 << (s - 1)
        if rem > half or (rem == half and q & 1):
            q += 1
    return sat16(q)


def scale_clip(v, s):
    q = v if s == 0 else _rne_shift(v, s)
    return not (-32768 <= q <= 32767)


def _rne_shift(v, s):
    q = v >> s
    rem = v & ((1 << s) - 1)
    half = 1 << (s - 1)
    if rem > half or (rem == half and q & 1):
        q += 1
    return q


# ------------------------------------------------------------------ NCO ---
def qwave(a):
    """9-bit phase word a -> Q1.15 sine, quarter-wave table lookup."""
    a &= 0x1FF
    quad, off = a >> 7, a & 0x7F
    t = QWAVE[off] if quad % 2 == 0 else QWAVE[127 - off]
    return -t if quad >= 2 else t


def nco_sin(phase):
    return qwave((phase >> 23) & 0x1FF)


def nco_cos(phase):
    return qwave(((phase >> 23) + 128) & 0x1FF)


def phase_k(init, inc, k):
    return (init + k * inc) & 0xFFFFFFFF


def inc_for(fc_over_fs):
    """Tuning word for a given cycles/sample frequency (may be negative)."""
    return round(fc_over_fs * (1 << 32)) & 0xFFFFFFFF


# ----------------------------------------------------------------- mixer --
def _mix_iq(xi, xq, c, s, up):
    """Shared 3-product structure; exact signed arithmetic then RNE+sat."""
    m1 = (xi + xq) * s
    if up:                                              # x*e^{+jphi}
        iacc = xi * (c + s) - m1
        qacc = xq * (c - s) + m1
    else:                                               # x*e^{-jphi}
        iacc = xi * (c - s) + m1
        qacc = xq * (c + s) - m1
    return sat16(rne(iacc)), sat16(rne(qacc))


def mix_ddc_int(xi, xq, phase):
    return _mix_iq(xi, xq, nco_cos(phase), nco_sin(phase), up=False)


def mix_duc_int(xi, xq, phase):
    return _mix_iq(xi, xq, nco_cos(phase), nco_sin(phase), up=True)


def mix_float(xi, xq, phase, up):
    ang = 2.0 * math.pi * (phase & 0xFFFFFFFF) / (1 << 32)
    c, s = math.cos(ang), math.sin(ang)
    if up:
        return xi * c - xq * s, xi * s + xq * c
    return xi * c + xq * s, xq * c - xi * s


# ------------------------------------------------------------------ CIC ---
def cic_decimate(seq_i, seq_q, rate, order):
    """wrapping 40b integrators at input rate, combs once per R inputs."""
    ig_i = [0] * order; ig_q = [0] * order
    cd_i = [0] * order; cd_q = [0] * order
    out = []
    for n, (xi, xq) in enumerate(zip(seq_i, seq_q)):
        vi, vq = xi, xq
        for k in range(order):
            ig_i[k] = w40(ig_i[k] + vi); vi = ig_i[k]
            ig_q[k] = w40(ig_q[k] + vq); vq = ig_q[k]
        if n % rate == rate - 1:
            for k in range(order):
                t = w40(vi - cd_i[k]); cd_i[k] = vi; vi = t
                t = w40(vq - cd_q[k]); cd_q[k] = vq; vq = t
            out.append((vi, vq))
    return out


def cic_interpolate(seq_i, seq_q, rate, order):
    """combs at low rate, zero-stuffed xR burst, integrators at high rate."""
    cd_i = [0] * order; cd_q = [0] * order
    ig_i = [0] * order; ig_q = [0] * order
    out = []
    for xi, xq in zip(seq_i, seq_q):
        vi, vq = xi, xq
        for k in range(order):
            t = w40(vi - cd_i[k]); cd_i[k] = vi; vi = t
            t = w40(vq - cd_q[k]); cd_q[k] = vq; vq = t
        for r in range(rate):
            ui = vi if r == 0 else 0
            uq = vq if r == 0 else 0
            for k in range(order):
                ig_i[k] = w40(ig_i[k] + ui); ui = ig_i[k]
                ig_q[k] = w40(ig_q[k] + uq); uq = ig_q[k]
            out.append((ui, uq))
    return out


# ------------------------------------------------------------------ FIR ---
def check_taps(taps):
    if taps == 1:
        return
    if not isinstance(taps, int) or taps % 2 == 0 or not 3 <= taps <= TAPS_MAX:
        raise ValueError('taps must be 1 (bypass) or odd in 3..%d' % TAPS_MAX)


def expand_coeffs(taps, ucoeffs):
    check_taps(taps)
    if taps == 1:
        return [32768]
    if len(ucoeffs) != (taps + 1) // 2:
        raise ValueError('unique coefficient count mismatch')
    if any(not -131072 <= c <= 131071 for c in ucoeffs):
        raise ValueError('signed18 coefficient required')
    h = [0] * taps
    for j, g in enumerate(ucoeffs):
        h[j] = h[taps - 1 - j] = g
    return h


def fir_iq(seq_i, seq_q, taps, ucoeffs):
    """One output per input, causal convolution, zero initial history."""
    if taps == 1:
        return [(sat16(i), sat16(q)) for i, q in zip(seq_i, seq_q)]
    h = expand_coeffs(taps, ucoeffs)
    n = len(seq_i)
    out = []
    for t in range(n):
        ai = sum(seq_i[k] * h[t - k] for k in range(n) if 0 <= t - k < taps)
        aq = sum(seq_q[k] * h[t - k] for k in range(n) if 0 <= t - k < taps)
        out.append((sat16(rne(ai)), sat16(rne(aq))))
    return out


def legal_config(rate, shift, taps):
    return (R_MIN <= rate <= R_MAX and 0 <= shift <= SHIFT_MAX and
            (taps == 1 or (taps % 2 == 1 and 3 <= taps <= TAPS_MAX)))


# ------------------------------------------------------------- chains -----
def ddc_int(samples, inc, init, rate, shift, taps, ucoeffs, order=3):
    """Bit-exact DDC: mix e^{-jphi} -> CIC decim -> scale -> FIR."""
    mixed_i, mixed_q = [], []
    for n, (xi, xq) in enumerate(samples):
        mi, mq = mix_ddc_int(xi, xq, phase_k(init, inc, n))
        mixed_i.append(mi); mixed_q.append(mq)
    dec = cic_decimate(mixed_i, mixed_q, rate, order)
    sc = [(scale_shift(i, shift), scale_shift(q, shift)) for i, q in dec]
    return fir_iq([p[0] for p in sc], [p[1] for p in sc], taps, ucoeffs)


def duc_int(samples, inc, init, rate, shift, taps, ucoeffs, order=3):
    """Bit-exact DUC: FIR -> CIC interp -> scale -> mix e^{+jphi}."""
    f = fir_iq([p[0] for p in samples], [p[1] for p in samples],
               taps, ucoeffs)
    up = cic_interpolate([p[0] for p in f], [p[1] for p in f], rate, order)
    out = []
    for m, (vi, vq) in enumerate(up):
        xi, xq = scale_shift(vi, shift), scale_shift(vq, shift)
        out.append(mix_duc_int(xi, xq, phase_k(init, inc, m)))
    return out


def ddc_float(samples, fc_over_fs, init_turns, rate, shift, taps, hcoeffs,
              order=3):
    """Float DDC: ideal sin/cos, unquantized mix, CIC, 2^-shift, float FIR."""
    mixed = []
    for n, (xi, xq) in enumerate(samples):
        ang = 2 * math.pi * (init_turns + n * fc_over_fs)
        c, s = math.cos(ang), math.sin(ang)
        mixed.append((xi * c + xq * s, xq * c - xi * s))
    # CIC in float (identical to int while inside 40 bits)
    ig_i = [0.0] * order; ig_q = [0.0] * order
    cd_i = [0.0] * order; cd_q = [0.0] * order
    dec = []
    for n, (vi, vq) in enumerate(mixed):
        for k in range(order):
            ig_i[k] += vi; vi = ig_i[k]
            ig_q[k] += vq; vq = ig_q[k]
        if n % rate == rate - 1:
            for k in range(order):
                t = vi - cd_i[k]; cd_i[k] = vi; vi = t
                t = vq - cd_q[k]; cd_q[k] = vq; vq = t
            dec.append((vi / (1 << shift), vq / (1 << shift)))
    out = []
    if taps == 1:
        return dec
    for t in range(len(dec)):
        ai = sum(dec[k][0] * hcoeffs[t - k] for k in range(len(dec))
                 if 0 <= t - k < taps)
        aq = sum(dec[k][1] * hcoeffs[t - k] for k in range(len(dec))
                 if 0 <= t - k < taps)
        out.append((ai, aq))
    return out


def duc_float(samples, fc_over_fs, init_turns, rate, shift, taps, hcoeffs,
              order=3):
    """Float DUC: float FIR -> CIC -> 2^-shift -> ideal mix e^{+jphi}."""
    f = list(samples)
    if taps > 1:
        f = []
        for t in range(len(samples)):
            ai = sum(samples[k][0] * hcoeffs[t - k]
                     for k in range(len(samples)) if 0 <= t - k < taps)
            aq = sum(samples[k][1] * hcoeffs[t - k]
                     for k in range(len(samples)) if 0 <= t - k < taps)
            f.append((ai, aq))
    cd_i = [0.0] * order; cd_q = [0.0] * order
    ig_i = [0.0] * order; ig_q = [0.0] * order
    up = []
    for vi, vq in f:
        for k in range(order):
            t = vi - cd_i[k]; cd_i[k] = vi; vi = t
            t = vq - cd_q[k]; cd_q[k] = vq; vq = t
        for r in range(rate):
            ui = vi if r == 0 else 0.0
            uq = vq if r == 0 else 0.0
            for k in range(order):
                ig_i[k] += ui; ui = ig_i[k]
                ig_q[k] += uq; uq = ig_q[k]
            up.append((ui, uq))
    out = []
    for m, (vi, vq) in enumerate(up):
        ang = 2 * math.pi * (init_turns + m * fc_over_fs)
        c, s = math.cos(ang), math.sin(ang)
        vi2, vq2 = vi / (1 << shift), vq / (1 << shift)
        out.append((vi2 * c - vq2 * s, vi2 * s + vq2 * c))
    return out


# -------------------------------------------- coefficient/twiddle tools ---
def _blackman(n, taps):
    return 0.42 - 0.5 * math.cos(2 * math.pi * n / (taps - 1)) \
        + 0.08 * math.cos(4 * math.pi * n / (taps - 1))


def _solve(A, b):
    n = len(A)
    m = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c and m[r][c]:
                f = m[r][c] / m[c][c]
                for col in range(n):
                    m[r][col] -= f * m[c][col]
                m[r][n] -= f * m[c][n]
    return [m[i][n] / m[i][i] for i in range(n)]


def cic_mag(order, rate, f_out):
    """CIC decimator magnitude at f_out in cycles/output-sample (DC=1)."""
    if f_out <= 0.0:
        return 1.0
    return abs(math.sin(math.pi * f_out)
               / (rate * math.sin(math.pi * f_out / rate))) ** order


def design_comp(order, rate, taps, fp=0.2, fstop=None, wstop=16.0):
    """Weighted-LS inverse-droop symmetric FIR (same recipe as DSP-10).

    Returns (unique_coeffs tuple len (taps+1)/2, float unique, int full taps).
    Exact integer DC gain 1.0 (sum h == 32768).  fp/fstop are in cycles per
    *output* (low-rate) sample.
    """
    check_taps(taps)
    if taps == 1:
        raise ValueError('bypass taps has no design')
    if not N_MIN <= order <= N_MAX or not R_MIN <= rate <= 64:
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
    qi.append(32768 - 2 * sum(qi))
    uc = tuple(qi)
    hq = expand_coeffs(taps, uc)
    assert sum(hq) == 32768
    return uc, g, hq


def pack_coeffs(ucoeffs):
    """Pack unique coeffs low-first into the cfg_coeffs 288-bit field."""
    v = 0
    for i, c in enumerate(ucoeffs):
        v |= (c & 0x3FFFF) << (18 * i)
    return v


# ------------------------------------------------------------- analysis ---
def dft_mag(seq_i, seq_q, k=None):
    """|X[k]| of complex sequence; k defaults to all bins."""
    n = len(seq_i)
    ks = range(n) if k is None else [k]
    out = []
    for kk in ks:
        s = sum(complex(seq_i[t], seq_q[t]) *
                cmath.exp(-2j * math.pi * kk * t / n) for t in range(n))
        out.append(abs(s))
    return out


def response(taps_full, f):
    return sum(c / 32768 * cmath.exp(-2j * math.pi * f * k)
               for k, c in enumerate(taps_full))


def nco_spur_bound():
    """Max LUT error: |qw(phase)-sin(2pi p/512)| over all 512 phases."""
    worst = 0.0
    for a in range(512):
        ideal = math.sin(2 * math.pi * a / 512)
        got = qwave(a) / 32768.0
        worst = max(worst, abs(got - ideal))
    return worst
