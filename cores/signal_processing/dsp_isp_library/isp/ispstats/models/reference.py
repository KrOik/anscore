"""ISP-12 AE/AWB/AF statistics references.

Two independent references live here:

* ``float_stats`` -- real-valued semantics.  Zone means, luma and gradient
  energy are computed with exact rationals (``fractions.Fraction``) so no
  rounding decision is hidden.
* ``stats`` -- the bit-exact integer contract implemented by
  ``rtl/ispstats_stream.sv``.

Frame model: ``frame`` is a list of rows; each pixel is an ``int`` in gray
mode (CH=1) or an ``(r, g, b)`` tuple of ints in RGB mode (CH=3).  On the
wire, RGB pixels are packed ``{R, G, B}`` MSB->LSB inside ``3*BITS`` bits,
matching ``isp/csc_stream.v`` channel order (channel 0 = R in the most
significant ``BITS`` lane).

Zone grid contract (shared by both references and the RTL):

* Runtime grid ``zones_x`` columns x ``zones_y`` rows, each in [1, 8].
* ``zones_x <= img_w`` and ``zones_y <= img_h`` are required, so every zone
  is non-empty and a single-carry Bresenham raster map suffices.
* Column zone of pixel x: ``zx = floor(x * zones_x / img_w)``; row zone of
  pixel y: ``zy = floor(y * zones_y / img_h)``.  ``zone_map`` computes this
  directly; ``bresenham_map`` computes the identical map incrementally the
  way the RTL does.  ``test_models.py`` proves they agree for every legal
  (dim, zones) pair.

Per-pixel integer contract (bit-exact):

    v(x,y) = pixel                       (CH=1)
           = (r + 2*g + b) >> 2          (CH=3; exact floor luma, <= MPX)
    gx(x,y) = 0 if x == 0 else |v(x,y) - v(x-1,y)|
    gy(x,y) = 0 if y == 0 else |v(x,y) - v(x,y-1)|
    e(x,y)  = gx + gy                    <= 2*MPX, attributed to zone(x,y)
    overexposed(x,y) = (max channel >= thresh)     # any-channel clip detect
                       gray: pixel >= thresh

Per-zone record, emitted in zy-major/zx-minor push order when each zone's
last pixel commits (last column of the zone on the last row of its band):

    {count, sum0, sum1, sum2, oe, focus}
    count : pixels in zone
    sum0/1/2 : channel sums (gray: sum0 only, sum1 = sum2 = 0)
    oe    : overexposed pixel count
    focus : sum of e(x,y) over the zone

Result readout contract: records are written to one of two ping-pong record
RAM banks; ``res_done[bank]``/``res_frame``/``res_count`` identify a
complete frame's record set.  Host reads via ``res_bank``/``res_addr`` with
one-cycle synchronous-read latency.
"""
from dataclasses import dataclass
from fractions import Fraction

ZONES_MAX = 8
FRAME_BOUND = 65536          # MAX_W * MAX_H must not exceed this
DIM_BOUND = 1024             # per-dimension bound


def _clog2(v):
    return max(1, (v - 1).bit_length())


def _frame(frame, ch):
    if not frame or not frame[0]:
        raise ValueError('empty frame')
    w = len(frame[0])
    if any(len(r) != w for r in frame):
        raise ValueError('ragged frame')
    for row in frame:
        for p in row:
            if ch == 1:
                vals = (p,)
            else:
                if not (isinstance(p, tuple) and len(p) == 3):
                    raise ValueError('RGB pixel must be (r,g,b) tuple')
                vals = p
            if any(not isinstance(v, int) or isinstance(v, bool) or v < 0
                   for v in vals):
                raise ValueError('pixels must be unsigned integers')
    return len(frame), w


@dataclass(frozen=True)
class Config:
    """Atomic runtime configuration; every field committed or rejected whole."""
    img_w: int
    img_h: int
    zones_x: int = 4
    zones_y: int = 4
    thresh: int = -1         # -1 = reset default (maxpix); a real 0 is legal
    bits: int = 8
    ch: int = 3
    max_w: int = 32
    max_h: int = 24

    def __post_init__(self):
        mpx = (1 << self.bits) - 1
        if self.thresh == -1:
            object.__setattr__(self, 'thresh', mpx)
        if self.bits not in (8, 10):
            raise ValueError('bits must be 8 or 10')
        if self.ch not in (1, 3):
            raise ValueError('ch must be 1 (gray) or 3 (RGB)')
        if not 1 <= self.img_w <= self.max_w:
            raise ValueError('img_w out of range')
        if not 1 <= self.img_h <= self.max_h:
            raise ValueError('img_h out of range')
        if not 1 <= self.zones_x <= ZONES_MAX:
            raise ValueError('zones_x out of range')
        if not 1 <= self.zones_y <= ZONES_MAX:
            raise ValueError('zones_y out of range')
        if self.zones_x > self.img_w:
            raise ValueError('zones_x exceeds img_w (empty zones unsupported)')
        if self.zones_y > self.img_h:
            raise ValueError('zones_y exceeds img_h (empty zones unsupported)')
        if not 0 <= self.thresh <= mpx:
            raise ValueError('thresh out of range')
        if not 1 <= self.max_w <= DIM_BOUND or not 1 <= self.max_h <= DIM_BOUND:
            raise ValueError('dimension bound')
        if self.max_w * self.max_h > FRAME_BOUND:
            raise ValueError('max frame bound')


def widths(bits=8, ch=3, max_w=32, max_h=24):
    """Single source of truth for derived RTL/vector widths (CLOG2 rules)."""
    fp = max_w * max_h
    mpx = (1 << bits) - 1
    cntw = _clog2(fp + 1)
    sumw = _clog2(fp * mpx + 1)
    enw = _clog2(fp * 2 * mpx + 1)
    return {
        'bits': bits, 'ch': ch, 'mpx': mpx, 'fp': fp,
        'cntw': cntw, 'sumw': sumw, 'enw': enw,
        'rw': 2 * cntw + 3 * sumw + enw,
        'xw': max(1, _clog2(max_w)), 'yw': max(1, _clog2(max_h)),
        'cwx': _clog2(max_w + 1), 'cwy': _clog2(max_h + 1),
        'inw': ch * bits,
        'cfgw': bits + 4 + 4 + _clog2(max_h + 1) + _clog2(max_w + 1),
    }


def zone_map(dim, zones):
    """floor(x * zones / dim): direct definition of the zone raster map."""
    if not 1 <= zones <= dim:
        raise ValueError('zones must be in [1, dim]')
    return [x * zones // dim for x in range(dim)]


def bresenham_map(dim, zones):
    """Incremental zone map exactly as the RTL derives it: one accumulator,
    at most one carry per step (legal because zones <= dim)."""
    if not 1 <= zones <= dim:
        raise ValueError('zones must be in [1, dim]')
    out = []
    acc, z = 0, 0
    for _ in range(dim):
        out.append(z)
        acc += zones
        if acc >= dim:
            acc -= dim
            z += 1
    return out


def zone_edges(dim, zones):
    """[start, end) column/row ranges per zone index, for readability/tests."""
    zm = zone_map(dim, zones)
    edges = []
    for zi in range(zones):
        idx = [i for i, z in enumerate(zm) if z == zi]
        edges.append((idx[0], idx[-1] + 1))
    return edges


def luma(pixel, ch):
    """Gradient/overexposure source value; exact floor for RGB."""
    if ch == 1:
        return pixel
    r, g, b = pixel
    return (r + 2 * g + b) >> 2


def _channels(pixel, ch):
    return (pixel, 0, 0) if ch == 1 else pixel


def stats(frame, cfg, crosscheck=True):
    """Bit-exact zone records matching the RTL integer contract.

    Returns records in push order (zy-major, zx-minor) — the order in which
    zones complete on the raster stream and therefore the order of result
    RAM addresses 0..zones_x*zones_y-1.
    """
    h, w = _frame(frame, cfg.ch)
    if w != cfg.img_w or h != cfg.img_h:
        raise ValueError('config size mismatch')
    mpx = (1 << cfg.bits) - 1

    def chk(v, name):
        if isinstance(v, tuple):
            vv = v
        else:
            vv = (v,)
        if max(vv) > mpx:
            raise ValueError('%s exceeds bit width' % name)

    for row in frame:
        for p in row:
            chk(p, 'pixel')
    zx_map = zone_map(w, cfg.zones_x)
    zy_map = zone_map(h, cfg.zones_y)
    if crosscheck:
        if zx_map != bresenham_map(w, cfg.zones_x):
            raise AssertionError('x zone map disagrees with bresenham')
        if zy_map != bresenham_map(h, cfg.zones_y):
            raise AssertionError('y zone map disagrees with bresenham')
    acc = {}
    for zy in range(cfg.zones_y):
        for zx in range(cfg.zones_x):
            acc[(zy, zx)] = dict(count=0, sum0=0, sum1=0, sum2=0, oe=0, focus=0)
    vprev_row = [0] * w
    for y in range(h):
        vprev = 0
        for x in range(w):
            p = frame[y][x]
            c0, c1, c2 = _channels(p, cfg.ch)
            v = luma(p, cfg.ch)
            gx = 0 if x == 0 else abs(v - vprev)
            gy = 0 if y == 0 else abs(v - vprev_row[x])
            r = acc[(zy_map[y], zx_map[x])]
            r['count'] += 1
            r['sum0'] += c0
            r['sum1'] += c1
            r['sum2'] += c2
            r['oe'] += int(max(c0, c1, c2) >= cfg.thresh)
            r['focus'] += gx + gy
            vprev = v
            vprev_row[x] = v
    return [acc[(zy, zx)] for zy in range(cfg.zones_y) for zx in range(cfg.zones_x)]


def float_stats(frame, cfg):
    """Real-valued semantics: exact rational zone means and energies.

    The gradient energy and counts are already integers, so they are exact;
    means and luma are rationals.
    """
    recs = stats(frame, cfg, crosscheck=False)
    out = []
    for r in recs:
        n = r['count']
        out.append({
            'count': n,
            'mean0': Fraction(r['sum0'], n),
            'mean1': Fraction(r['sum1'], n),
            'mean2': Fraction(r['sum2'], n),
            'mean_lum': Fraction(r['sum0'] + 2 * r['sum1'] + r['sum2'], 4 * n)
            if cfg.ch == 3 else Fraction(r['sum0'], n),
            'oe_frac': Fraction(r['oe'], n),
            'focus': r['focus'],
        })
    return out


def pack_input(pixel, sof, eol, bits, ch):
    if ch == 1:
        return (sof << (bits + 1)) | (eol << bits) | pixel
    r, g, b = pixel
    return ((sof << (3 * bits + 1)) | (eol << (3 * bits))
            | (r << (2 * bits)) | (g << bits) | b)


def pack_record(rec, w):
    """MSB->LSB: focus[ENW], oe[CNTW], sum2, sum1, sum0[SUMW], count[CNTW]."""
    word = rec['focus'] & ((1 << w['enw']) - 1)
    word = (word << w['cntw']) | (rec['oe'] & ((1 << w['cntw']) - 1))
    word = (word << w['sumw']) | (rec['sum2'] & ((1 << w['sumw']) - 1))
    word = (word << w['sumw']) | (rec['sum1'] & ((1 << w['sumw']) - 1))
    word = (word << w['sumw']) | (rec['sum0'] & ((1 << w['sumw']) - 1))
    word = (word << w['cntw']) | (rec['count'] & ((1 << w['cntw']) - 1))
    return word


def unpack_record(word, w):
    """Inverse of pack_record for host-side consumers/tests."""
    cntw, sumw, enw = w['cntw'], w['sumw'], w['enw']
    rec = {}
    rec['count'] = word & ((1 << cntw) - 1)
    word >>= cntw
    rec['sum0'] = word & ((1 << sumw) - 1)
    word >>= sumw
    rec['sum1'] = word & ((1 << sumw) - 1)
    word >>= sumw
    rec['sum2'] = word & ((1 << sumw) - 1)
    word >>= sumw
    rec['oe'] = word & ((1 << cntw) - 1)
    word >>= cntw
    rec['focus'] = word & ((1 << enw) - 1)
    return rec


def pack_config(cfg, cwx, cwy):
    """MSB->LSB: thresh[BITS], zones_y[4], zones_x[4], img_h[CWY], img_w[CWX]."""
    return (((cfg.thresh & ((1 << cfg.bits) - 1)) << (4 + 4 + cwy + cwx))
            | (cfg.zones_y << (4 + cwy + cwx))
            | (cfg.zones_x << (cwy + cwx))
            | (cfg.img_h << cwx) | cfg.img_w)
