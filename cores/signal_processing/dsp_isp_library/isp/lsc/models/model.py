"""Independent LSC reference models; no RTL/DUT imports.

Fixed-point contract (mirrors rtl/lsc_stream.sv exactly):
  gains        unsigned Q4.12 in 16-bit words (0..15.9998 x)
  node spacing 2^kx horizontally, 2^ky vertically in the *interpolation
               domain*: pixel units in flat mode, 2x2-phase units in
               Bayer mode (u=x>>1, v=y>>1).
  node index   i = min(u >> kx, gw-2); remx = u - (i << kx)
               fx = (remx << 8) >> kx          (weight Q8, range 0..256)
               same for j/fy via ky.
  interp       a = g00 + ((g01-g00)*fx >> 8)   (floor shift on signed diff)
               b = g10 + ((g11-g10)*fx >> 8)
               g = a  + ((b - a  )*fy >> 8), clamped to cfg gmax
  apply        out = min((pix*g + 2048) >> 12, 2^BITS-1)
  unwritten    gain forced to unity 0x1000 until a written buffer is active.
"""
from dataclasses import dataclass

GW_MAX = 17
GH_MAX = 13
GFRAC = 12          # gain fractional bits (Q4.12)
FFRAC = 8           # interpolation weight fractional bits
UNITY = 1 << GFRAC

# Bayer phase tables, indexed [order][y&1][x&1] -> phase 0..3.
# Phases are abstract channel slots; RGGB order maps p0..p3 = R,Gr,Gb,B.
PHASE_TABLE = {
    0: ((0, 1), (2, 3)),   # RGGB
    1: ((3, 2), (1, 0)),   # BGGR
    2: ((1, 0), (3, 2)),   # GRBG
    3: ((2, 3), (0, 1)),   # GBRG
}


def phase_of(order, y, x):
    return PHASE_TABLE[order][y & 1][x & 1]


def kexp(span, nodes):
    """Minimal node-spacing exponent: (nodes-1)<<e must cover span-1."""
    if nodes < 2 or span < 1:
        raise ValueError('bad span/nodes')
    e = 0
    while ((nodes - 1) << e) < span - 1:
        e += 1
        if e > 15:
            raise ValueError('spacing exponent exceeds 4-bit field')
    return e


@dataclass(frozen=True)
class Config:
    width: int
    height: int
    gw: int          # grid columns 2..GW_MAX
    gh: int          # grid rows    2..GH_MAX
    kx: int          # horizontal node spacing exponent 0..15
    ky: int          # vertical node spacing exponent   0..15
    bayer: int = 0   # 1: per-2x2-phase grids in phase domain
    order: int = 0   # Bayer order 0..3 (RGGB/BGGR/GRBG/GBRG)
    gswap: int = 1   # swap gain buffers at commit (transport field)
    gmax: int = 0xffff   # interpolated-gain clamp, Q4.12
    bits: int = 8

    def __post_init__(self):
        w_eff = (self.width + 1) >> 1 if self.bayer else self.width
        h_eff = (self.height + 1) >> 1 if self.bayer else self.height
        if not 2 <= self.width <= 8191 or not 2 <= self.height <= 8191:
            raise ValueError('frame dims out of range')
        if not 2 <= self.gw <= GW_MAX or not 2 <= self.gh <= GH_MAX:
            raise ValueError('grid dims out of range')
        if not 0 <= self.kx <= 15 or not 0 <= self.ky <= 15:
            raise ValueError('spacing exponent out of range')
        if ((self.gw - 1) << self.kx) < w_eff - 1:
            raise ValueError('grid does not cover frame width')
        if ((self.gh - 1) << self.ky) < h_eff - 1:
            raise ValueError('grid does not cover frame height')
        if self.bayer and not 0 <= self.order <= 3:
            raise ValueError('Bayer order out of range')
        if not 0 <= self.gmax <= 0xffff:
            raise ValueError('gmax out of range')
        if self.bits not in (8, 10):
            raise ValueError('unsupported pixel width')

    @property
    def eff_width(self):
        return (self.width + 1) >> 1 if self.bayer else self.width

    @property
    def eff_height(self):
        return (self.height + 1) >> 1 if self.bayer else self.height

    def pack(self):
        """63-bit config word, layout shared with tests/tb_lsc.sv:
        [12:0]w [25:13]h [30:26]gw [34:31]gh [38:35]kx [42:39]ky
        [43]bayer [45:44]order [46]gswap [62:47]gmax."""
        return (self.width | (self.height << 13) | (self.gw << 26)
                | (self.gh << 31) | (self.kx << 35) | (self.ky << 39)
                | ((self.bayer & 1) << 43) | ((self.order & 3) << 44)
                | ((self.gswap & 1) << 46) | ((self.gmax & 0xffff) << 47))


def _weights(pos, nodes, ke):
    """(index, rem, fraction Q8) for interpolation-domain coordinate pos."""
    i = pos >> ke
    imax = nodes - 2
    if i > imax:
        i = imax
    rem = pos - (i << ke)          # 0 .. 2^ke
    f = (rem << FFRAC) >> ke       # 0 .. 256
    return i, rem, f


def _node(gains, p, j, i):
    return gains[p][j][i]


def fixed_pixel(pix, x, y, cfg, gains):
    """Bit-exact output for one pixel. gains=None -> unity buffer."""
    p = phase_of(cfg.order, y, x) if cfg.bayer else 0
    u = x >> 1 if cfg.bayer else x
    v = y >> 1 if cfg.bayer else y
    i, _rx, fx = _weights(u, cfg.gw, cfg.kx)
    j, _ry, fy = _weights(v, cfg.gh, cfg.ky)
    if gains is None:
        g = UNITY
    else:
        g00 = _node(gains, p, j, i)
        g01 = _node(gains, p, j, i + 1)
        g10 = _node(gains, p, j + 1, i)
        g11 = _node(gains, p, j + 1, i + 1)
        a = g00 + (((g01 - g00) * fx) >> FFRAC)
        b = g10 + (((g11 - g10) * fx) >> FFRAC)
        g = a + (((b - a) * fy) >> FFRAC)
        g = min(g, cfg.gmax)
    out = (pix * g + (1 << (GFRAC - 1))) >> GFRAC
    return min(out, (1 << cfg.bits) - 1)


def fixed_frame(pix2d, cfg, gains):
    return [[fixed_pixel(pix2d[y][x], x, y, cfg, gains)
             for x in range(cfg.width)] for y in range(cfg.height)]


def float_pixel(pix, x, y, cfg, gains_f):
    """Float reference: same node geometry, real-valued interpolation."""
    p = phase_of(cfg.order, y, x) if cfg.bayer else 0
    u = x >> 1 if cfg.bayer else x
    v = y >> 1 if cfg.bayer else y
    i, remx, _ = _weights(u, cfg.gw, cfg.kx)
    j, remy, _ = _weights(v, cfg.gh, cfg.ky)
    if gains_f is None:
        g = 1.0
    else:
        wx = remx / (1 << cfg.kx)
        wy = remy / (1 << cfg.ky)
        g00 = gains_f[p][j][i]
        g01 = gains_f[p][j][i + 1]
        g10 = gains_f[p][j + 1][i]
        g11 = gains_f[p][j + 1][i + 1]
        g = ((g00 * (1 - wx) + g01 * wx) * (1 - wy)
             + (g10 * (1 - wx) + g11 * wx) * wy)
        g = min(g, cfg.gmax / float(UNITY))
    return pix * g


def float_frame(pix2d, cfg, gains_f):
    return [[float_pixel(pix2d[y][x], x, y, cfg, gains_f)
             for x in range(cfg.width)] for y in range(cfg.height)]
