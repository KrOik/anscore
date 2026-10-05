"""ISP-10 integral image / local statistics / adaptive threshold references.

Two independent references live here:

* ``float_stats`` -- real-valued semantics.  Means and variances are exact
  rationals (``fractions.Fraction``), so no rounding decision is hidden.
* ``stats`` -- the bit-exact integer contract implemented by the RTL.

Window contract (shared by both): the local window for output pixel (x, y) is
the *causal trailing* rectangle rows max(0, y-WH+1)..y by columns
max(0, x-WW+1)..x.  Windows are clipped at the top and left image edges only;
the window never looks ahead, so no bottom/right clipping can occur.  The
reported area is min(y+1, WH) * min(x+1, WW).  Every input pixel produces
exactly one output beat in raster order (same-size output).

Integer contract per pixel:
    isum, isq : integral image I(x,y) / I2(x,y) over rows 0..y, cols 0..x
    wsum, wsq : trailing-window sums of p and p^2
    area      : min(x+1, WW) * min(y+1, WH)
    mean      : floor(wsum / area)                      (exact floor division)
    var       : floor(wsq / area) - mean*mean           (>= 0 by Cauchy)
    bin       : 1 iff (pixel + C) * area > wsum         (exact, no division)
    m_tdata   : all-ones pixel when bin else 0

``bin`` equals the real rule ``pixel > mean_real - C`` exactly, because
``pixel + C > wsum/area`` is equivalent to ``(pixel+C)*area > wsum`` for
positive integer ``area``.  The RTL therefore needs no divider for the
threshold decision.
"""
from dataclasses import dataclass
from fractions import Fraction

WIN_MAX = 15
FRAME_BOUND = 65536  # MAX_W * MAX_H must not exceed this (accumulator bound)


def _frame(frame):
    if not frame or not frame[0]:
        raise ValueError('empty frame')
    w = len(frame[0])
    if any(len(r) != w for r in frame):
        raise ValueError('ragged frame')
    if any(not isinstance(v, int) or isinstance(v, bool) or v < 0
           for r in frame for v in r):
        raise ValueError('pixels must be unsigned integers')
    return len(frame), w


@dataclass(frozen=True)
class Config:
    """Atomic runtime configuration; every field committed or rejected whole."""
    img_w: int
    img_h: int
    win_w: int = 3
    win_h: int = 3
    c: int = 0
    max_w: int = 32
    max_h: int = 24

    def __post_init__(self):
        if not 1 <= self.img_w <= self.max_w:
            raise ValueError('img_w out of range')
        if not 1 <= self.img_h <= self.max_h:
            raise ValueError('img_h out of range')
        if not 1 <= self.win_w <= WIN_MAX:
            raise ValueError('win_w out of range')
        if not 1 <= self.win_h <= WIN_MAX:
            raise ValueError('win_h out of range')
        if not -128 <= self.c <= 127:
            raise ValueError('C must be signed8')
        if self.max_w < 1 or self.max_h < 1 or self.max_w * self.max_h > FRAME_BOUND:
            raise ValueError('max frame bound')


def widths(bits=8, max_w=32, max_h=24, win_w_max=WIN_MAX, win_h_max=WIN_MAX):
    """Single source of truth for derived RTL/vector widths (CLOG2 rules)."""
    def clog2(v):
        return max(1, (v - 1).bit_length())
    maxpix = (1 << bits) - 1
    iw = clog2(max_w * max_h * maxpix + 1)
    return {
        'bits': bits, 'iw': iw, 'isw': iw + 2 * bits,
        'csw': clog2(win_h_max * maxpix + 1),
        'wsw': clog2(win_w_max * win_h_max * maxpix + 1),
        'aw': clog2(win_w_max * win_h_max + 1),
        'xw': max(1, clog2(max_w)), 'yw': max(1, clog2(max_h)),
        'cwx': clog2(max_w + 1), 'cwy': clog2(max_h + 1),
        'fw': clog2(max_w * max_h + 1), 'vw': 2 * bits,
    }


def widths_full(bits=8, max_w=32, max_h=24, win_w_max=WIN_MAX, win_h_max=WIN_MAX):
    w = widths(bits, max_w, max_h, win_w_max, win_h_max)
    w['cqw'] = w['csw'] + bits          # column sum-of-squares width
    w['wssw'] = w['wsw'] + bits         # window sum-of-squares width
    w['ew'] = (2 + w['bits'] + w['bits'] + w['vw'] + w['aw']
               + w['wsw'] + w['wssw'] + w['iw'] + w['isw'])
    w['cfgw'] = 8 + 4 + 4 + w['cwy'] + w['cwx']
    return w


def integral(frame, square=False):
    """2D prefix sums I(x,y); independent storage, no DUT line-bank model."""
    h, w = _frame(frame)
    prev = [0] * w
    out = []
    for row in frame:
        rs = 0
        orow = []
        for x, v in enumerate(row):
            rs += v * v if square else v
            prev[x] += rs
            orow.append(prev[x])
        out.append(orow)
    return out


def window_direct(frame, win_w, win_h, square=False):
    """Nested-loop trailing-window sums; fully independent of integral storage."""
    h, w = _frame(frame)
    out = []
    for y in range(h):
        orow = []
        y0 = max(0, y - win_h + 1)
        for x in range(w):
            x0 = max(0, x - win_w + 1)
            s = 0
            for yy in range(y0, y + 1):
                for xx in range(x0, x + 1):
                    v = frame[yy][xx]
                    s += v * v if square else v
            orow.append(s)
        out.append(orow)
    return out


def window_integral(frame, win_w, win_h):
    """Trailing-window sums via the integral image (prefix-sum path)."""
    h, w = _frame(frame)
    isum = integral(frame)
    isq = integral(frame, square=True)

    def box(ii, y, x):
        y0 = y - win_h
        x0 = x - win_w
        v = ii[y][x]
        if x0 >= 0:
            v -= ii[y][x0]
        if y0 >= 0:
            v -= ii[y0][x]
        if x0 >= 0 and y0 >= 0:
            v += ii[y0][x0]
        return v

    return ([[box(isum, y, x) for x in range(w)] for y in range(h)],
            [[box(isq, y, x) for x in range(w)] for y in range(h)])


def stats(frame, cfg, bits=8, crosscheck=True):
    """Bit-exact per-pixel record matching the RTL integer contract."""
    h, w = _frame(frame)
    if w != cfg.img_w or h != cfg.img_h:
        raise ValueError('config size mismatch')
    if max(v for r in frame for v in r) >= (1 << bits):
        raise ValueError('pixel exceeds configured bit width')
    isum = integral(frame)
    isq = integral(frame, square=True)
    wsum, wsq = window_integral(frame, cfg.win_w, cfg.win_h)
    if crosscheck:
        # The prefix-sum path must agree with the independent direct path.
        if wsum != window_direct(frame, cfg.win_w, cfg.win_h):
            raise AssertionError('integral path disagrees with direct path')
        if wsq != window_direct(frame, cfg.win_w, cfg.win_h, square=True):
            raise AssertionError('integral square path disagrees')
    out = []
    for y in range(h):
        for x in range(w):
            area = min(x + 1, cfg.win_w) * min(y + 1, cfg.win_h)
            s = wsum[y][x]
            q = wsq[y][x]
            p = frame[y][x]
            mean = s // area
            var = q // area - mean * mean
            b = int((p + cfg.c) * area > s)
            out.append({
                'x': x, 'y': y, 'pixel': p,
                'isum': isum[y][x], 'isq': isq[y][x],
                'wsum': s, 'wsq': q, 'area': area,
                'mean': mean, 'var': var, 'bin': b,
                'out': ((1 << bits) - 1) if b else 0,
            })
    return out


def float_stats(frame, win_w, win_h, c):
    """Real-valued semantics: exact rational mean/variance, real threshold."""
    h, w = _frame(frame)
    wsum, wsq = window_integral(frame, win_w, win_h)
    out = []
    for y in range(h):
        for x in range(w):
            area = min(x + 1, win_w) * min(y + 1, win_h)
            s = wsum[y][x]
            q = wsq[y][x]
            mean = Fraction(s, area)
            var = Fraction(q, area) - mean * mean
            out.append({
                'x': x, 'y': y, 'area': area, 'wsum': s, 'wsq': q,
                'mean': mean, 'var': var,
                'bin': int(frame[y][x] > mean - c),
            })
    return out


def pack_input(pixel, sof, eol, bits):
    return (sof << (bits + 1)) | (eol << bits) | pixel


def pack_expected(rec, w):
    """MSB->LSB: tuser, tlast, tdata, mean, var, area, wsum, wsq, isum, isq."""
    word = rec['sof']
    word = (word << 1) | rec['eol']
    for field, width in (('out', w['bits']), ('mean', w['bits']),
                         ('var', w['vw']), ('area', w['aw']),
                         ('wsum', w['wsw']), ('wsq', w['wssw']),
                         ('isum', w['iw']), ('isq', w['isw'])):
        word = (word << width) | (rec[field] & ((1 << width) - 1))
    return word


def pack_config(cfg, cwx, cwy):
    """MSB->LSB: c(8), win_h(4), win_w(4), img_h(cwy), img_w(cwx)."""
    return (((cfg.c & 0xFF) << (4 + 4 + cwy + cwx))
            | (cfg.win_h << (4 + cwy + cwx))
            | (cfg.win_w << (cwy + cwx))
            | (cfg.img_h << cwx) | cfg.img_w)
