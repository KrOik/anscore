"""ISP-07 Bayer demosaic references (bilinear RGGB/BGGR/GRBG/GBRG -> RGB).

Two independent references live here:

* ``demosaic_float`` -- real-valued semantics.  Every interpolated channel is
  the exact rational mean (``fractions.Fraction``) of its kernel taps, so no
  rounding decision is hidden.
* ``demosaic`` -- the bit-exact integer contract implemented by the RTL
  (truncating averages: ``sum >> 2`` for 4-tap kernels, ``sum >> 1`` for
  2-tap kernels; the site channel itself is copied, never averaged).

Bayer phase contract (shared by both): the phase coordinate of frame pixel
``(x, y)`` is ``pp = ((y + oy) & 1, (x + ox) & 1)`` -- the pattern is anchored
at the frame's SOF pixel and ``ox``/``oy`` are the parity of the frame origin
inside the full sensor array, i.e. the post-ROI Bayer phase.  ``cfa`` selects
the named pattern by the phase position of its R site (the B site is always
the diagonally opposite phase)::

    cfa 0 RGGB: R at pp=(0,0), B at (1,1)    cfa 1 BGGR: R at (1,1), B at (0,0)
    cfa 2 GRBG: R at pp=(0,1), B at (1,0)    cfa 3 GBRG: R at (1,0), B at (0,1)

Equivalently BGGR/GRBG/GBRG are RGGB shifted by an origin parity of
(1,1)/(1,0)/(0,1) -- the model tests assert exactly those identities.

Window / boundary contract: the 3x3 neighborhood of output pixel (x,y) is
gathered with independently clamped coordinates --

    tap(dx, dy) = frame[min(max(y+dy,0),h-1)][min(max(x+dx,0),w-1)]

which is precisely the REPLICATE pad mode of ``stream_window_padded``; corner
and edge pixels therefore average replicated edge samples, never zeros.

Bilinear kernel per site color (truncating integer form; float form uses the
exact rational mean of the same taps)::

    R site : R=c              G=avg4(up,dn,lf,rt)   B=avg4(tl,tr,bl,br)
    B site : B=c              G=avg4(up,dn,lf,rt)   R=avg4(tl,tr,bl,br)
    G site : G=c;  horizontal neighbor color HCOL = color(phase {yp,~xp}):
             the channel whose axis is horizontal uses avg2(lf,rt),
             the other uses avg2(up,dn).

The phase decision for the axis uses the *pattern* phase of the neighbor
position, never a clamped-fetch color -- identical to the RTL phase logic.
"""
from dataclasses import dataclass
from fractions import Fraction

CFA_NAMES = ('RGGB', 'BGGR', 'GRBG', 'GBRG')
# R-site phase (yp, xp) per cfa; B site is always the diagonal opposite.
R_PHASE = {0: (0, 0), 1: (1, 1), 2: (0, 1), 3: (1, 0)}


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
    cfa: int = 0            # 0=RGGB 1=BGGR 2=GRBG 3=GBRG
    ox: int = 0             # frame-origin column parity in sensor coordinates
    oy: int = 0             # frame-origin row parity
    reserved: int = 0       # must be 0 (illegal otherwise)

    def __post_init__(self):
        if self.cfa not in (0, 1, 2, 3):
            raise ValueError('cfa must be 0..3')
        if self.ox not in (0, 1) or self.oy not in (0, 1):
            raise ValueError('origin parity must be 0/1')
        if self.reserved != 0:
            raise ValueError('reserved config bits must be 0')

    @property
    def name(self):
        return CFA_NAMES[self.cfa]


def site_color(cfa, x, y, ox=0, oy=0):
    """Color of the Bayer site at frame pixel (x, y): 'R', 'G' or 'B'."""
    pp = ((y + oy) & 1, (x + ox) & 1)
    rp = R_PHASE[cfa]
    if pp == rp:
        return 'R'
    if pp == (rp[0] ^ 1, rp[1] ^ 1):
        return 'B'
    return 'G'


def taps3x3(frame, x, y):
    """REPLICATE-clamped 3x3 neighborhood, exact padded-window semantics."""
    h, w = _frame(frame)

    def t(dx, dy):
        return frame[min(max(y + dy, 0), h - 1)][min(max(x + dx, 0), w - 1)]

    return {
        'tl': t(-1, -1), 'up': t(0, -1), 'tr': t(1, -1),
        'lf': t(-1, 0), 'c': t(0, 0), 'rt': t(1, 0),
        'bl': t(-1, 1), 'dn': t(0, 1), 'br': t(1, 1),
    }


def _avg(vals, exact):
    if exact:
        return Fraction(sum(vals), len(vals))
    return sum(vals) >> (2 if len(vals) == 4 else 1)


def _pixel(frame, x, y, cfg, exact):
    t = taps3x3(frame, x, y)
    site = site_color(cfg.cfa, x, y, cfg.ox, cfg.oy)
    cross = (t['up'], t['dn'], t['lf'], t['rt'])
    diag = (t['tl'], t['tr'], t['bl'], t['br'])
    if site == 'R':
        return t['c'], _avg(cross, exact), _avg(diag, exact)
    if site == 'B':
        return _avg(diag, exact), _avg(cross, exact), t['c']
    # G site: axis is decided by the horizontal neighbor's pattern phase.
    hcol = site_color(cfg.cfa, x + 1, y, cfg.ox, cfg.oy)
    havg = _avg((t['lf'], t['rt']), exact)
    vavg = _avg((t['up'], t['dn']), exact)
    if hcol == 'R':
        return havg, t['c'], vavg
    return vavg, t['c'], havg


def demosaic(frame, cfg, bits=8):
    """Bit-exact per-pixel records matching the RTL integer contract."""
    h, w = _frame(frame)
    if max(v for r in frame for v in r) >= (1 << bits):
        raise ValueError('pixel exceeds configured bit width')
    out = []
    for y in range(h):
        for x in range(w):
            r, g, b = _pixel(frame, x, y, cfg, exact=False)
            out.append({'x': x, 'y': y, 'pixel': frame[y][x],
                        'site': site_color(cfg.cfa, x, y, cfg.ox, cfg.oy),
                        'r': r, 'g': g, 'b': b,
                        'sof': int(x == 0 and y == 0), 'eol': int(x == w - 1)})
    return out


def demosaic_float(frame, cfg):
    """Real-valued semantics: exact rational channel means, same kernel taps."""
    h, w = _frame(frame)
    out = []
    for y in range(h):
        for x in range(w):
            r, g, b = _pixel(frame, x, y, cfg, exact=True)
            out.append({'x': x, 'y': y, 'r': r, 'g': g, 'b': b,
                        'site': site_color(cfg.cfa, x, y, cfg.ox, cfg.oy)})
    return out


def widths(bits=8):
    """Derived bus widths (single source of truth for TB/vector packing)."""
    return {'bits': bits, 'ow': 3 * bits, 'ew': 3 * bits + 2, 'cfgw': 8}


def pack_input(pixel, sof, eol, bits):
    return (sof << (bits + 1)) | (eol << bits) | pixel


def pack_expected(rec, bits):
    """MSB->LSB: tuser, tlast, r, g, b."""
    return ((rec['sof'] << (3 * bits + 1)) | (rec['eol'] << (3 * bits))
            | (rec['r'] << (2 * bits)) | (rec['g'] << bits) | rec['b'])


def pack_config(cfg):
    """Config byte, MSB->LSB: reserved(4), cfa(2), oy(1), ox(1)."""
    return ((cfg.reserved & 0xF) << 4) | (cfg.cfa << 2) | (cfg.oy << 1) | cfg.ox
