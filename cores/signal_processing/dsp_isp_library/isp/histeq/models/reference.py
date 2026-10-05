"""ISP-11 histogram equalization / CLAHE references.

Two independent references live here:

* ``float_*`` -- real-valued semantics (``fractions.Fraction``): the
  ideal normalized-CDF map and exact-rational bilinear interpolation.
* bit-exact contract functions -- the integer rules implemented by
  ``rtl/histeq_stream.sv``.  ``//`` below is floor division.

Modes (see SPEC.md):
    0 HE_PREV : output of frame N uses LUT from frame N-1's histogram
                (frame 0 uses the identity ramp).  Streamable.
    1 HE_CUR  : output of frame N uses LUT from frame N's own histogram.
    2 CLAHE   : per-tile clipped/redistributed maps + bilinear blend.

Quantization: global bins = 256 (gb = p >> BITS-8); CLAHE bins = 64 per
tile (cb = p >> BITS-6).  Maps are BITS wide.

Bit-exact integer contract (MPX = 2^BITS-1, N = W*H, T = tile area):

    identity[i] = min(MPX, (2*i*MPX + 255)//510)
    HE:  cdf_min = cdf at first occupied bin; den = N - cdf_min
         den==0 -> identity; else
         map[i]  = min(MPX, (2*max(0,cdf[i]-cdf_min)*MPX + den)//(2*den))
    CLAHE: hc = min(h,clip); excess = T - sum(hc)
           base = excess>>6; rem = excess & 63
           h'[i] = hc[i] + base + (i<rem)
           map_t[i] = min(MPX, (2*cdf'[i]*MPX + T)//(2*T))
    frac table fxt[n] = (128*n + t)//(2*t)  (weight of next tile, 1/64)
    bilinear out = (m00*(64-fx)*(64-fy) + m01*fx*(64-fy)
                  + m10*(64-fx)*fy + m11*fx*fy + 2048) >> 12, clamp MPX
"""
from dataclasses import dataclass
from fractions import Fraction

NBINS = 256
CBINS = 64
TILE_LOG2_MAX = 4          # txl,tyl <= 4 and txl+tyl <= 4 (<=16 tiles)
FRAME_BOUND = 65536


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
    mode: int = 0          # 0 HE_PREV, 1 HE_CUR, 2 CLAHE
    txl: int = 0           # log2 tiles across (CLAHE only)
    tyl: int = 0           # log2 tiles down    (CLAHE only)
    clip: int = 0          # per-bin clip limit (CLAHE only)
    max_w: int = 32
    max_h: int = 24
    clahe_en: bool = True

    def __post_init__(self):
        if not 1 <= self.img_w <= self.max_w:
            raise ValueError('img_w out of range')
        if not 1 <= self.img_h <= self.max_h:
            raise ValueError('img_h out of range')
        if self.max_w < 1 or self.max_h < 1 or self.max_w * self.max_h > FRAME_BOUND:
            raise ValueError('max frame bound')
        if self.mode not in (0, 1, 2):
            raise ValueError('mode out of range')
        if not (0 <= self.txl <= 7 and 0 <= self.tyl <= 7):
            raise ValueError('txl/tyl field range')
        if not 0 <= self.clip <= 0xFFFF:
            raise ValueError('clip field range')
        if self.mode == 2:
            if not self.clahe_en:
                raise ValueError('CLAHE disabled')
            if self.txl > TILE_LOG2_MAX or self.tyl > TILE_LOG2_MAX:
                raise ValueError('tile log2 bound')
            if self.txl + self.tyl > TILE_LOG2_MAX:
                raise ValueError('tile count bound')
            if self.img_w % (1 << self.txl) or self.img_h % (1 << self.tyl):
                raise ValueError('tile grid must divide image')
            if self.clip < 1:
                raise ValueError('clip must be >= 1')


def widths(bits=8, max_w=32, max_h=24):
    """Single source of truth for derived RTL/vector widths (CLOG2 rules)."""
    def clog2(v):
        return max(1, (v - 1).bit_length())
    return {
        'bits': bits,
        'xw': max(1, clog2(max_w)), 'yw': max(1, clog2(max_h)),
        'cwx': clog2(max_w + 1), 'cwy': clog2(max_h + 1),
        'fw': clog2(max_w * max_h + 1),
        'aw': max(1, clog2(max_w * max_h)),
        'ew': bits + 2,                            # {sof, eol, tdata}
        'cfgw': 16 + 2 + 3 + 3 + clog2(max_h + 1) + clog2(max_w + 1),
    }


# ---------------------------------------------------------------- bit-exact

def gbin(p, bits):
    return p >> (bits - 8)


def cbin(p, bits):
    return p >> (bits - 6)


def hist_global(frame, bits):
    h = [0] * NBINS
    for row in frame:
        for v in row:
            h[gbin(v, bits)] += 1
    return h


def identity_map(bits):
    mpx = (1 << bits) - 1
    return [min(mpx, (2 * i * mpx + 255) // 510) for i in range(NBINS)]


def he_map(h, bits):
    """Global histogram-equalization map, bit-exact."""
    mpx = (1 << bits) - 1
    n = sum(h)
    cdf = []
    acc = 0
    cdf_min = None
    for v in h:
        acc += v
        cdf.append(acc)
        if cdf_min is None and v:
            cdf_min = acc
    if cdf_min is None:
        cdf_min = 0
    den = n - cdf_min
    if den == 0 or n == 0:
        return identity_map(bits)
    return [min(mpx, (2 * max(0, c - cdf_min) * mpx + den) // (2 * den))
            for c in cdf]


def clahe_tile_map(h64, clip, t, bits):
    """Clip + single-pass redistribute + normalized CDF, bit-exact."""
    if len(h64) != CBINS:
        raise ValueError('tile histogram must have 64 bins')
    mpx = (1 << bits) - 1
    hc = [min(v, clip) for v in h64]
    excess = sum(h64) - sum(hc)
    base = excess >> 6
    rem = excess & 63
    cdf = 0
    out = []
    for i in range(CBINS):
        cdf += hc[i] + base + (1 if i < rem else 0)
        out.append(min(mpx, (2 * cdf * mpx + t) // (2 * t)))
    assert cdf == t, 'redistribution must preserve tile area'
    return out


def frac_tab(t):
    """Weight-of-next-tile table, 1/64 units, round-half-up."""
    return [(128 * n + t) // (2 * t) for n in range(t)]


def _pair(idx, off, half, ntiles):
    """Tile pair for interpolation; returns (a, b, degenerate)."""
    if off < half:
        a = idx - 1 if idx > 0 else 0
        return a, idx
    a = idx
    b = idx + 1 if idx < ntiles - 1 else idx
    return a, b


def bilinear(m00, m01, m10, m11, fx, fy, bits):
    mpx = (1 << bits) - 1
    num = (m00 * (64 - fx) * (64 - fy) + m01 * fx * (64 - fy)
           + m10 * (64 - fx) * fy + m11 * fx * fy + 2048)
    return min(mpx, num >> 12)


def he_frame(frame, lut, bits):
    """Apply a 256-entry map through the global bin index."""
    h, w = _frame(frame)
    return [[lut[gbin(frame[y][x], bits)] for x in range(w)] for y in range(h)]


def clahe_frame(frame, cfg, bits):
    """Full CLAHE transform, bit-exact (maps + bilinear blend)."""
    h, w = _frame(frame)
    if w != cfg.img_w or h != cfg.img_h:
        raise ValueError('config size mismatch')
    if max(v for r in frame for v in r) >= (1 << bits):
        raise ValueError('pixel exceeds configured bit width')
    ntx = 1 << cfg.txl
    nty = 1 << cfg.tyl
    tw = w >> cfg.txl
    th = h >> cfg.tyl
    t = tw * th
    # per-tile maps
    maps = {}
    for ty in range(nty):
        for tx in range(ntx):
            h64 = [0] * CBINS
            for y in range(ty * th, (ty + 1) * th):
                for x in range(tx * tw, (tx + 1) * tw):
                    h64[cbin(frame[y][x], bits)] += 1
            maps[(tx, ty)] = clahe_tile_map(h64, cfg.clip, t, bits)
    fxt = frac_tab(tw)
    fyt = frac_tab(th)
    cx = tw >> 1
    cy = th >> 1
    out = []
    for y in range(h):
        ty, dy = divmod(y, th)
        orow = []
        for x in range(w):
            tx, dx = divmod(x, tw)
            ta, tb = _pair(tx, dx, cx, ntx)
            nx = dx + tw - cx if dx < cx else dx - cx
            fx = 0 if ta == tb else fxt[nx]
            ua, ub = _pair(ty, dy, cy, nty)
            ny = dy + th - cy if dy < cy else dy - cy
            fy = 0 if ua == ub else fyt[ny]
            cb = cbin(frame[y][x], bits)
            orow.append(bilinear(maps[(ta, ua)][cb], maps[(tb, ua)][cb],
                                 maps[(ta, ub)][cb], maps[(tb, ub)][cb],
                                 fx, fy, bits))
        out.append(orow)
    return out


def run_frames(frames, cfgs, bits):
    """Frame-sequence semantics: returns per-frame output images.

    Mode 0 uses the GLUT built from the previous processed HE frame
    (identity for the first frame); modes 0/1 rebuild GLUT from the
    frame's own global histogram; mode 2 leaves GLUT untouched.
    """
    if len(frames) != len(cfgs):
        raise ValueError('frames/cfgs length mismatch')
    glut = identity_map(bits)
    outs = []
    for f, cfg in zip(frames, cfgs):
        if cfg.mode == 0:
            outs.append(he_frame(f, glut, bits))
            glut = he_map(hist_global(f, bits), bits)
        elif cfg.mode == 1:
            glut = he_map(hist_global(f, bits), bits)
            outs.append(he_frame(f, glut, bits))
        else:
            outs.append(clahe_frame(f, cfg, bits))
    return outs


# ------------------------------------------------------------------ float

def he_map_real(h, bits):
    """Exact-rational HE map (None marks the degenerate constant frame)."""
    mpx = (1 << bits) - 1
    n = sum(h)
    cdf = []
    acc = 0
    cdf_min = None
    for v in h:
        acc += v
        cdf.append(acc)
        if cdf_min is None and v:
            cdf_min = acc
    if cdf_min is None or n - cdf_min == 0:
        return [Fraction(i * mpx, NBINS - 1) for i in range(NBINS)]
    den = n - cdf_min
    return [max(Fraction(0), min(Fraction(mpx),
            Fraction(c - cdf_min) * mpx / den)) for c in cdf]


def clahe_tile_map_real(h64, clip, t, bits):
    """Same redistribution, but real-valued normalized CDF."""
    mpx = (1 << bits) - 1
    hc = [min(v, clip) for v in h64]
    excess = sum(h64) - sum(hc)
    base = excess >> 6
    rem = excess & 63
    cdf = 0
    out = []
    for i in range(CBINS):
        cdf += hc[i] + base + (1 if i < rem else 0)
        out.append(Fraction(cdf * mpx, t))
    return out


def clahe_frame_real(frame, cfg, bits):
    """Real-valued CLAHE: rational weights (no 1/64 rounding)."""
    h, w = _frame(frame)
    ntx = 1 << cfg.txl
    nty = 1 << cfg.tyl
    tw = w >> cfg.txl
    th = h >> cfg.tyl
    t = tw * th
    mpx = (1 << bits) - 1
    maps = {}
    for ty in range(nty):
        for tx in range(ntx):
            h64 = [0] * CBINS
            for y in range(ty * th, (ty + 1) * th):
                for x in range(tx * tw, (tx + 1) * tw):
                    h64[cbin(frame[y][x], bits)] += 1
            maps[(tx, ty)] = clahe_tile_map_real(h64, cfg.clip, t, bits)
    cx = tw >> 1
    cy = th >> 1
    out = []
    for y in range(h):
        ty, dy = divmod(y, th)
        orow = []
        for x in range(w):
            tx, dx = divmod(x, tw)
            ta, tb = _pair(tx, dx, cx, ntx)
            nx = dx + tw - cx if dx < cx else dx - cx
            fx = Fraction(0) if ta == tb else Fraction(nx, tw)
            ua, ub = _pair(ty, dy, cy, nty)
            ny = dy + th - cy if dy < cy else dy - cy
            fy = Fraction(0) if ua == ub else Fraction(ny, th)
            cb = cbin(frame[y][x], bits)
            v = (maps[(ta, ua)][cb] * (1 - fx) * (1 - fy)
                 + maps[(tb, ua)][cb] * fx * (1 - fy)
                 + maps[(ta, ub)][cb] * (1 - fx) * fy
                 + maps[(tb, ub)][cb] * fx * fy)
            orow.append(min(Fraction(mpx), max(Fraction(0), v)))
        out.append(orow)
    return out


# ------------------------------------------------------------------ pack

def pack_input(pixel, sof, eol, bits):
    return (sof << (bits + 1)) | (eol << bits) | pixel


def pack_expected(sof, eol, out, bits):
    return (sof << (bits + 1)) | (eol << bits) | out


def pack_config(cfg, cwx, cwy):
    """MSB->LSB: clip(16), mode(2), txl(3), tyl(3), img_h(cwy), img_w(cwx)."""
    return (((cfg.clip & 0xFFFF) << (2 + 3 + 3 + cwy + cwx))
            | (cfg.mode << (3 + 3 + cwy + cwx))
            | (cfg.txl << (3 + cwy + cwx))
            | (cfg.tyl << (cwy + cwx))
            | (cfg.img_h << cwx) | cfg.img_w)
