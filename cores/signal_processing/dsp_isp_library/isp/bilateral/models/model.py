"""ISP-18 edge-preserving denoise: 3x3 bilateral filter reference models.

Two independent layers (per goal.md SOP they are never interchangeable):

* ``float_frame`` — floating-point reference: for a 3x3 replicate/zero-padded
  window, w_k = exp(-d_k^2 / (2*sigma_d^2)) * exp(-di_k^2 / (2*sigma_r^2)),
  out = sum(w_k * p_k) / sum(w_k) using real arithmetic.

* ``fixed_frame`` / ``fixed_pixel`` — bit-exact model of
  ``rtl/bilateral_stream.sv``:

      diff_k = |tap_k - center|                    (BITS bits)
      idx_k  = diff_k >> (BITS - WR_AW)            (WR_AW bits, bin of 2^step)
      wr_k   = rlut[idx_k]                         (WR_W unsigned)
      wq_k   = (slut[k] * wr_k) >> WS_W            (truncated, <= WR_W bits)
      num    = sum(tap_k * wq_k)                   (BITS + DEN_W bits)
      den    = sum(wq_k)                           (DEN_W bits)
      out    = center                        if den == 0 (zero-denominator)
             = center                        if bypass
             = RNE(num / den)                otherwise (fp_div_pipe rounding)

LUT generation is intentionally shared with ``gen_luts.py`` so the RTL
default parameters (SLUT_INIT / RLUT_INIT), the model defaults and the
fixture files are one source of truth.  Weight table quantization uses
Python's round() (round-half-even) and is reproduced verbatim.
"""

import math

BITS = 8          # pixel width (8 or 10)
WS_W = 4          # spatial weight width  -> ws in [0, 15]
WR_W = 8          # range  weight width   -> wr in [0, 255]
WR_AW = 6         # range LUT address bits -> 2**WR_AW entries
RLN = 1 << WR_AW  # range LUT length
SLN = 9           # spatial LUT length (3x3 taps, row-major)
DEN_W = WR_W + 4  # weight-sum width (9 * 239 = 2151 max -> 12 bits)

SIGMA_D_REF = 1.0   # reference config sigma_d
SIGMA_R_REF = 25.0  # reference config sigma_r (8-bit domain)


def spatial_table(sigma_d, ws_w=WS_W):
    """9-entry row-major spatial LUT: ws[k] = RNE((2**ws_w-1) * e^{-d2/2sd^2}).

    Tap k maps to window (row=k//3, col=k%3); d2 = (row-1)^2 + (col-1)^2 in
    {0,1,2}.  Tap 4 (center) always gets the maximum weight.
    """
    if sigma_d <= 0:
        raise ValueError('sigma_d must be > 0')
    m = (1 << ws_w) - 1
    out = []
    for k in range(SLN):
        r, c = divmod(k, 3)
        d2 = (r - 1) ** 2 + (c - 1) ** 2
        out.append(int(round(m * math.exp(-d2 / (2.0 * sigma_d * sigma_d)))))
    return out


def range_table(sigma_r, bits=BITS, wr_w=WR_W, wr_aw=WR_AW):
    """2**wr_aw-entry range LUT: wr[i] = RNE((2**wr_w-1) * e^{-d^2/2sr^2}).

    Bin i represents |diff| in [i*step, i*step+step-1] with
    step = 2**(bits-wr_aw); the representative difference is the bin's left
    edge d = i*step (documented in SPEC.md; the RTL index is diff >> log2(step)).
    """
    if sigma_r <= 0:
        raise ValueError('sigma_r must be > 0')
    if wr_aw >= bits:
        raise ValueError('wr_aw must be < bits')
    m = (1 << wr_w) - 1
    step = 1 << (bits - wr_aw)
    return [int(round(m * math.exp(-((i * step) ** 2)
                                   / (2.0 * sigma_r * sigma_r))))
            for i in range(1 << wr_aw)]


DEFAULT_SLUT = spatial_table(SIGMA_D_REF)                    # {6,9,6,9,15,9,6,9,6}
DEFAULT_RLUT = range_table(SIGMA_R_REF)


def pack_slut(tab):
    """Pack spatial table MSB-first (entry 8 first) like RTL SLUT_INIT."""
    v = 0
    for e in reversed(tab):
        v = (v << WS_W) | e
    return v


def pack_rlut(tab, wr_w=WR_W):
    v = 0
    for e in reversed(tab):
        v = (v << wr_w) | e
    return v


def window3(frame, x, y, pad=1):
    """Row-major 3x3 taps for centre (x,y); pad 1 = replicate, 0 = zero."""
    h = len(frame)
    w = len(frame[0])
    taps = []
    for r in (-1, 0, 1):
        for c in (-1, 0, 1):
            iy, ix = y + r, x + c
            if 0 <= iy < h and 0 <= ix < w:
                taps.append(frame[iy][ix])
            elif pad == 1:
                taps.append(frame[min(max(iy, 0), h - 1)][min(max(ix, 0), w - 1)])
            else:
                taps.append(0)
    return taps


def rne_div(num, den):
    """Exact round-half-even num/den for num>=0, den>0 (fp_div_pipe result)."""
    q, r = divmod(num, den)
    cmp = 2 * r - den
    if cmp > 0 or (cmp == 0 and (q & 1)):
        q += 1
    return q


def fixed_pixel(taps, slut, rlut, bits=BITS, bypass=False):
    """Bit-exact bilateral output for one 3x3 window (taps row-major)."""
    c = taps[4]
    num = den = 0
    for k in range(SLN):
        idx = abs(taps[k] - c) >> (bits - WR_AW)
        wq = (slut[k] * rlut[idx]) >> WS_W
        num += taps[k] * wq
        den += wq
    if den == 0 or bypass:
        return c
    return rne_div(num, den)


def fixed_frame(frame, slut=None, rlut=None, bits=BITS, pad=1, bypass=False):
    """Whole-frame bit-exact model; default tables = RTL reset values."""
    slut = DEFAULT_SLUT if slut is None else slut
    rlut = DEFAULT_RLUT if rlut is None else rlut
    if len(slut) != SLN or len(rlut) != RLN:
        raise ValueError('bad table lengths')
    return [[fixed_pixel(window3(frame, x, y, pad), slut, rlut, bits, bypass)
             for x in range(len(frame[0]))] for y in range(len(frame))]


def float_pixel(taps, dist2, sigma_d, sigma_r):
    c = taps[4]
    num = den = 0.0
    for k in range(SLN):
        w = (math.exp(-dist2[k] / (2.0 * sigma_d * sigma_d))
             * math.exp(-((taps[k] - c) ** 2) / (2.0 * sigma_r * sigma_r)))
        num += w * taps[k]
        den += w
    return c if den == 0.0 else num / den


_DIST2 = [(k // 3 - 1) ** 2 + (k % 3 - 1) ** 2 for k in range(SLN)]


def float_frame(frame, sigma_d=SIGMA_D_REF, sigma_r=SIGMA_R_REF, pad=1):
    """Floating-point reference (unquantised weights, real divide)."""
    h = len(frame)
    w = len(frame[0])
    return [[float_pixel(window3(frame, x, y, pad), _DIST2, sigma_d, sigma_r)
             for x in range(w)] for y in range(h)]


def lt_entry(addr, data, exp_err=0):
    """Pack one lut.mem write word: {exp_err[15], addr[14:8], data[7:0]}."""
    return (exp_err << 15) | (addr << 8) | (data & 0xFF)


def cfg_word(bypass=0, lswap=0, rsvd=0):
    """Pack one config.mem word: {rsvd[7:2], lswap[1], bypass[0]}."""
    return ((rsvd & 0x3F) << 2) | ((lswap & 1) << 1) | (bypass & 1)


def marker(x, y, w, bits):
    """input.mem/expected.mem sideband packing: {tuser<<(bits+1)|tlast<<bits|pix}."""
    return ((x == w - 1) << bits) | ((x == 0 and y == 0) << (bits + 1))
