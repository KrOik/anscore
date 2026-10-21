"""Independent ISP-19 geometric-remap references.

Two levels live here; neither imports RTL or DUT data.

* ``float_remap`` -- real-valued bilinear remap for algorithm sanity.
* ``run_frame``   -- the bit-exact contract implemented by
  ``rtl/remap_stream.sv``.  All coordinate math is integer Q16; ``>>``
  below is Python's floor shift on signed values, matching the RTL
  arithmetic-shift / bit-slice semantics exactly.

Modes (cfg mode field):
    0 FLIP_H : sx = in_w-1-ox , sy = oy
    1 FLIP_V : sx = ox        , sy = in_h-1-oy
    2 ROT90  : sx = oy        , sy = in_h-1-ox   (90 deg clockwise;
               out_w==in_h and out_h==in_w required)
    3 AFFINE : sx = a0*ox+a1*oy+a2 , sy = a3*ox+a4*oy+a5   (a6..a8 unused)
    4 PERSP  : nx,ny as AFFINE, d = a6*ox+a7*oy+a8;
               sx = RNE(nx*2^16/d), sy = RNE(ny*2^16/d) -- exactly the
               fp_div_iter(AW=BW=42, FB=16, OUT_W=42) contract incl.
               divide-by-zero saturation to a huge signed coordinate
               (which then renders as out-of-bounds fill).
    5 LENS   : per-output-pixel source coordinate read from a mesh of
               (sy,sx) Q16 nodes with pitch 2^kx x 2^ky output pixels,
               bilinearly interpolated with floor-shift >>8 weights
               (i = min(ox>>kx, lx-2), same style as the LSC grid).

Coordinates are signed Q16 throughout.  Matrix coefficients a0..a8 are
signed Q9.16 in 26 bits.

Bilinear sampling: taps at (floor(sx), floor(sy)) .. (+1,+1), weights
wx1 = frac_q8 = sx[15:8], wx0 = 256-wx1 (sum exactly 256 per axis);
out = (sum tap*w + 2^15) >> 16 (round half up).  Out-of-bounds fill:
  ZERO (0)      OOB tap contributes 0
  BORDER (1)    OOB tap contributes cfg.border
  REPLICATE (2) the Q16 coordinate is clamped into [0, dim-1] first
tap(x1) is OOB iff sx OOB or x0 == in_w-1 (one-past-edge rule).
"""
from dataclasses import dataclass

MODE_FLIPH = 0
MODE_FLIPV = 1
MODE_ROT90 = 2
MODE_AFFINE = 3
MODE_PERSP = 4
MODE_LENS = 5
MODES = (MODE_FLIPH, MODE_FLIPV, MODE_ROT90, MODE_AFFINE, MODE_PERSP,
         MODE_LENS)

FILL_ZERO = 0
FILL_BORDER = 1
FILL_REPLICATE = 2
FILLS = (FILL_ZERO, FILL_BORDER, FILL_REPLICATE)

Q = 16                              # coordinate fractional bits
COEF_MIN = -(1 << 25)               # signed 26-bit coefficient range
COEF_MAX = (1 << 25) - 1
NODE_MIN = -(1 << 26)               # signed 27-bit mesh node coordinate
NODE_MAX = (1 << 26) - 1

# fp_div_iter geometry instantiated by the RTL
DIV_FB = 16
DIV_OUT_W = 42
DIV_OMAX = (1 << (DIV_OUT_W - 1)) - 1
DIV_OMIN = -(1 << (DIV_OUT_W - 1))


def fdiv(a, b):
    """Bit-exact fp_div_iter(AW=42,BW=42,FB=16,OUT_W=42):
    q = sat42(RNE(a*2^16/b)); b==0 -> sign(a) ? OMIN : OMAX."""
    if b == 0:
        return DIV_OMIN if a < 0 else DIV_OMAX
    ua, ub = abs(a), abs(b)
    q, r = divmod(ua << DIV_FB, ub)
    # RTL: up = (2*rem > ub) || (2*rem == ub && quot[0])  -> round to even
    if 2 * r > ub or (2 * r == ub and q & 1):
        q += 1
    sq = -q if (a < 0) != (b < 0) else q
    return max(DIV_OMIN, min(DIV_OMAX, sq))


@dataclass
class Config:
    """One atomic 320-bit configuration bundle."""
    iw: int
    ih: int
    ow: int
    oh: int
    mode: int = MODE_FLIPH
    coefs: tuple = (0,) * 9          # a0..a8 signed Q9.16 integers
    fill: int = FILL_ZERO
    border: int = 0
    lx: int = 2                      # lens mesh nodes per row
    ly: int = 2                      # lens mesh rows
    kx: int = 0                      # log2 horizontal node pitch (out px)
    ky: int = 0
    clr: int = 0                     # clear mesh written_bits at accept
    bits: int = 8
    max_w: int = 128                 # static bounds the core was built with
    max_h: int = 128
    lxmax: int = 17
    lymax: int = 17

    def errors(self, written=None):
        """Legality violations, mirroring the RTL cfg_error conditions.
        ``written`` is the set of flat mesh indices (row*LXMAX+col)
        already accepted; required to evaluate lens coverage."""
        e = []
        if not 1 <= self.iw <= self.max_w:
            e.append('in_w')
        if not 1 <= self.ih <= self.max_h:
            e.append('in_h')
        if not 1 <= self.ow <= 8191:
            e.append('out_w')
        if not 1 <= self.oh <= 8191:
            e.append('out_h')
        if self.mode not in MODES:
            e.append('mode')
        if self.fill not in FILLS:
            e.append('fill')
        # NOTE: the RTL has NO border legality check -- cfg_data carries a
        # 10-bit field and only the low BITS bits reach the sampler, so an
        # oversized border truncates silently (same effect here via mask).
        for k, c in enumerate(self.coefs):
            if not COEF_MIN <= c <= COEF_MAX:
                e.append('coef%d' % k)
        if self.mode == MODE_ROT90:
            if self.ow != self.ih or self.oh != self.iw:
                e.append('rot90 dims')
        if self.mode == MODE_LENS:
            if not 2 <= self.lx <= self.lxmax or not 2 <= self.ly <= self.lymax:
                e.append('mesh dims')
            else:
                if ((self.lx - 1) << self.kx) < self.ow - 1:
                    e.append('mesh cover x')
                if ((self.ly - 1) << self.ky) < self.oh - 1:
                    e.append('mesh cover y')
                if written is not None and any(
                        j * self.lxmax + i not in written
                        for j in range(self.ly) for i in range(self.lx)):
                    e.append('mesh unwritten')
        return e

    def pack(self):
        """320-bit config word shared with tests/tb_remap.sv:
        [12:0]iw [25:13]ih [38:26]ow [51:39]oh [54:52]mode [56:55]fill
        [66:57]border [71:67]lx [76:72]ly [80:77]kx [84:81]ky
        [85+26k +: 26] a_k signed   [319] clr_mesh."""
        w = (self.iw | (self.ih << 13) | (self.ow << 26)
             | (self.oh << 39) | (self.mode << 52) | (self.fill << 55)
             | (self.border << 57) | (self.lx << 67) | (self.ly << 72)
             | (self.kx << 77) | (self.ky << 81) | (self.clr << 319))
        for k, c in enumerate(self.coefs):
            w |= (c & ((1 << 26) - 1)) << (85 + 26 * k)
        return w


def pack_raw(base=0, **kw):
    """Unchecked word edit for illegal-bundle tests (same layout)."""
    w = base
    for name, lo, width in (
            ('iw', 0, 13), ('ih', 13, 13), ('ow', 26, 13), ('oh', 39, 13),
            ('mode', 52, 3), ('fill', 55, 2), ('border', 57, 10),
            ('lx', 67, 5), ('ly', 72, 5), ('kx', 77, 4), ('ky', 81, 4),
            ('clr', 319, 1)):
        if name in kw:
            w &= ~(((1 << width) - 1) << lo)
            w |= (kw[name] & ((1 << width) - 1)) << lo
    for k in range(9):
        name = 'a%d' % k
        if name in kw:
            lo = 85 + 26 * k
            w &= ~(((1 << 26) - 1) << lo)
            w |= (kw[name] & ((1 << 26) - 1)) << lo
    return w


class Mesh:
    """Lens mesh state: nodes indexed (row, col) -> (sx, sy) Q16 ints,
    plus the written-coverage flags that gate a lens APPLY."""

    def __init__(self, lxmax=17, lymax=17):
        self.lxmax = lxmax
        self.lymax = lymax
        self.nodes = {}
        self.written = set()

    def write(self, row, col, sx, sy):
        """Returns False (and writes nothing) when out of range, matching
        the l_error rejection path."""
        if not (0 <= row < self.lxmax and 0 <= col < self.lxmax):
            return False
        if not NODE_MIN <= sx <= NODE_MAX or not NODE_MIN <= sy <= NODE_MAX:
            raise ValueError('node coordinate out of Q11.16 range')
        self.nodes[(row, col)] = (sx, sy)
        self.written.add(row * self.lxmax + col)
        return True

    def clear(self):
        self.nodes.clear()
        self.written.clear()

    def node(self, row, col):
        return self.nodes[(row, col)]

    def pack_word(self, row, col):
        sx, sy = self.nodes[(row, col)]
        return ((sy & ((1 << 27) - 1)) << 27) | (sx & ((1 << 27) - 1))


def _check_frame(frame, w, h):
    if len(frame) != h or any(len(r) != w for r in frame):
        raise ValueError('frame shape does not match config')
    for row in frame:
        for v in row:
            if not isinstance(v, int) or v < 0:
                raise ValueError('pixels must be unsigned integers')


def src_coord(cfg, ox, oy, mesh):
    """Q16 integer source coordinate for output pixel (ox,oy)."""
    m = cfg.mode
    c = cfg.coefs
    if m == MODE_FLIPH:
        return ((cfg.iw - 1 - ox) << Q, oy << Q)
    if m == MODE_FLIPV:
        return (ox << Q, (cfg.ih - 1 - oy) << Q)
    if m == MODE_ROT90:
        return (oy << Q, (cfg.ih - 1 - ox) << Q)
    nx = c[0] * ox + c[1] * oy + c[2]
    ny = c[3] * ox + c[4] * oy + c[5]
    if m == MODE_AFFINE:
        return nx, ny
    if m == MODE_PERSP:
        d = c[6] * ox + c[7] * oy + c[8]
        return fdiv(nx, d), fdiv(ny, d)
    # MODE_LENS: mesh node index + Q8 interp weights (LSC-style)
    i = min(ox >> cfg.kx, cfg.lx - 2)
    j = min(oy >> cfg.ky, cfg.ly - 2)
    rx = ox - (i << cfg.kx)
    ry = oy - (j << cfg.ky)
    fx = (rx << 8) >> cfg.kx
    fy = (ry << 8) >> cfg.ky
    n00 = mesh.node(j, i)
    n01 = mesh.node(j, i + 1)
    n10 = mesh.node(j + 1, i)
    n11 = mesh.node(j + 1, i + 1)
    xt = n00[0] + (((n01[0] - n00[0]) * fx) >> 8)
    xb = n10[0] + (((n11[0] - n10[0]) * fx) >> 8)
    sx = xt + (((xb - xt) * fy) >> 8)
    yt = n00[1] + (((n01[1] - n00[1]) * fx) >> 8)
    yb = n10[1] + (((n11[1] - n10[1]) * fx) >> 8)
    sy = yt + (((yb - yt) * fy) >> 8)
    return sx, sy


def sample(img, sx, sy, cfg):
    """Bit-exact bilinear tap gather + weighted sum for one output pixel."""
    iw, ih = cfg.iw, cfg.ih
    rep = cfg.fill == FILL_REPLICATE
    if rep:
        sx = min(max(sx, 0), (iw - 1) << Q)
        sy = min(max(sy, 0), (ih - 1) << Q)
    xo = sx < 0 or sx >= (iw << Q)
    yo = sy < 0 or sy >= (ih << Q)
    x0 = sx >> Q
    y0 = sy >> Q
    ax0 = 0 if sx < 0 else (iw - 1 if xo else x0)
    ay0 = 0 if sy < 0 else (ih - 1 if yo else y0)
    ax1 = iw - 1 if ax0 >= iw - 1 else ax0 + 1
    ay1 = ih - 1 if ay0 >= ih - 1 else ay0 + 1
    xo0 = xo
    xo1 = xo or ax0 == iw - 1
    yo0 = yo
    yo1 = yo or ay0 == ih - 1
    fx = (sx >> 8) & 0xFF
    fy = (sy >> 8) & 0xFF
    wx1, wx0 = fx, 256 - fx
    wy1, wy0 = fy, 256 - fy

    bval = cfg.border & ((1 << cfg.bits) - 1)   # RTL: low BITS bits only

    def tap(ax, ay, oob):
        if oob and not rep:
            return bval if cfg.fill == FILL_BORDER else 0
        return img[ay][ax]

    acc = (tap(ax0, ay0, xo0 or yo0) * wx0 * wy0
           + tap(ax1, ay0, xo1 or yo0) * wx1 * wy0
           + tap(ax0, ay1, xo0 or yo1) * wx0 * wy1
           + tap(ax1, ay1, xo1 or yo1) * wx1 * wy1)
    return (acc + 0x8000) >> 16


def run_frame(frame, cfg, mesh=None):
    """Bit-exact drain image for one already-stored input frame."""
    _check_frame(frame, cfg.iw, cfg.ih)
    errs = cfg.errors(mesh.written if mesh is not None else None)
    if errs:
        raise ValueError('illegal config: %s' % errs)
    if cfg.mode == MODE_LENS and mesh is None:
        raise ValueError('lens mode requires a mesh')
    return [[sample(frame, *src_coord(cfg, x, y, mesh), cfg)
             for x in range(cfg.ow)] for y in range(cfg.oh)]


def float_remap(frame, cfg, mesh=None):
    """Float reference: real-valued coordinates, real bilinear, same
    fill policy.  Not bit-exact -- used to bound the fixed-point error."""
    import math
    _check_frame(frame, cfg.iw, cfg.ih)
    c = cfg.coefs
    S = float(1 << Q)
    out = []
    for y in range(cfg.oh):
        row = []
        for x in range(cfg.ow):
            if cfg.mode == MODE_FLIPH:
                sx, sy = float(cfg.iw - 1 - x), float(y)
            elif cfg.mode == MODE_FLIPV:
                sx, sy = float(x), float(cfg.ih - 1 - y)
            elif cfg.mode == MODE_ROT90:
                sx, sy = float(y), float(cfg.ih - 1 - x)
            elif cfg.mode == MODE_LENS:
                sxq, syq = src_coord(cfg, x, y, mesh)
                sx, sy = sxq / S, syq / S
            else:
                nx = (c[0] * x + c[1] * y + c[2]) / S
                ny = (c[3] * x + c[4] * y + c[5]) / S
                if cfg.mode == MODE_PERSP:
                    d = (c[6] * x + c[7] * y + c[8]) / S
                    nx = nx / d if d else (1e30 if nx >= 0 else -1e30)
                    ny = ny / d if d else (1e30 if ny >= 0 else -1e30)
                sx, sy = nx, ny
            rep = cfg.fill == FILL_REPLICATE
            if rep:
                sx = min(max(sx, 0.0), float(cfg.iw - 1))
                sy = min(max(sy, 0.0), float(cfg.ih - 1))
            xo = sx < 0.0 or sx >= cfg.iw
            yo = sy < 0.0 or sy >= cfg.ih
            x0 = math.floor(sx)
            y0 = math.floor(sy)
            ax0 = min(max(x0, 0), cfg.iw - 1)
            ay0 = min(max(y0, 0), cfg.ih - 1)
            ax1 = min(ax0 + 1, cfg.iw - 1)
            ay1 = min(ay0 + 1, cfg.ih - 1)
            fx = sx - x0
            fy = sy - y0

            def tp(ax, ay, oob):
                if oob and not rep:
                    return float(cfg.border
                                 if cfg.fill == FILL_BORDER else 0)
                return float(frame[ay][ax])

            v = (tp(ax0, ay0, xo or yo) * (1.0 - fx) * (1.0 - fy)
                 + tp(ax1, ay0, xo or ax0 == cfg.iw - 1 or yo)
                 * fx * (1.0 - fy)
                 + tp(ax0, ay1, xo or yo or ay0 == cfg.ih - 1)
                 * (1.0 - fx) * fy
                 + tp(ax1, ay1, xo or ax0 == cfg.iw - 1 or yo
                      or ay0 == cfg.ih - 1) * fx * fy)
            row.append(int(v + 0.5))
        out.append(row)
    return out
