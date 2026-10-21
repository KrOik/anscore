"""ISP-14 CCM + tone mapping references for ``rtl/ccm_stream.sv``.

Two independent oracles; neither consumes RTL output:

* ``float_pixel`` / ``float_frame`` -- real-valued matrix/bias/tone semantics
  used for documentation and error bounds.
* ``pixel`` / ``frame`` -- the bit-exact integer contract the RTL implements
  (Q2.13 coefficients, round-half-away quantize, monotone 33-node PWL).

Pixel word: ``3*BITS`` bits, channel ``c`` in slice ``[c*BITS +: BITS]``
(c0=B LSB, c1=G, c2=R), matching ``isp/csc_stream.v`` packing.

Config image (the shadow bank written through the 16-bit port):

* ``ctrl``: bit0-2 ``tone_en[c]``, bit3 ``domain`` (0 = lin bank,
  1 = enc bank), bits15:4 must be zero.
* ``matrix[9]``: signed Q2.13 coefficients, row-major (row c = entries
  3c..3c+2 against input channels 0..2).  Legal range: every row obeys
  ``sum |M[c][j]| <= ROW_GAIN_MAX = 7<<13`` (7.0).
* ``bias[3]``: signed pixel-unit offsets added in the Q2.13 domain.
* ``lin``/``enc``: per-channel 33-node PWL tables (flat index c*33+i),
  each node <= MPX, each channel's sequence non-decreasing.  ``lin`` is the
  linear-light-intent bank, ``enc`` the encoded-domain bank; ``domain``
  selects which is read.  Nodes are stored BITS bits wide, so an
  out-of-range node write is rejected on the write beat (cfg_error, store
  dropped); monotonicity is validated at commit for all tables, even for
  channels with tone_en = 0.

``simulate`` reproduces the shadow-write / commit / SOF-boundary-apply
semantics so expected frames can be generated for a full transaction script.
"""
from dataclasses import dataclass, field

FRAC = 13                    # Q2.13
ROW_GAIN_MAX = 7 << FRAC     # per-row sum|c| bound
NODES = 33                   # PWL nodes per channel per bank
CTRL_ADDR = 0x00
COEF_BASE = 0x01             # ..0x09
BIAS_BASE = 0x0A             # ..0x0C
LIN_BASE = 0x10              # ..0x72, flat n = c*33+i
ENC_BASE = 0x80              # ..0xE2
ADDR_HI_LIN = LIN_BASE + 3 * NODES - 1   # 0x72
ADDR_HI_ENC = ENC_BASE + 3 * NODES - 1   # 0xE2


def mpx(bits):
    return (1 << bits) - 1


def chan(px, c, bits):
    return (px >> (c * bits)) & mpx(bits)


def packpix(vals, bits):
    w = 0
    for c, v in enumerate(vals):
        w |= (v & mpx(bits)) << (c * bits)
    return w


def identity_nodes(bits):
    """node[i] = min(i*STEP, MPX); legal in either bank."""
    step = 1 << (bits - 5)
    return [min(i * step, mpx(bits)) for i in range(NODES)]


@dataclass
class Config:
    """One complete shadow image; always written/read as a whole."""
    matrix: tuple = (8192, 0, 0, 0, 8192, 0, 0, 0, 8192)
    bias: tuple = (0, 0, 0)
    tone_en: tuple = (0, 0, 0)
    domain: int = 0
    lin: tuple = ()            # 99 entries c*33+i, else identity
    enc: tuple = ()
    bits: int = 8

    def __post_init__(self):
        object.__setattr__(self, 'matrix', tuple(self.matrix))
        object.__setattr__(self, 'bias', tuple(self.bias))
        object.__setattr__(self, 'tone_en', tuple(self.tone_en))
        if not self.lin:
            object.__setattr__(self, 'lin', tuple(identity_nodes(self.bits) * 3))
        if not self.enc:
            object.__setattr__(self, 'enc', tuple(identity_nodes(self.bits) * 3))
        if self.bits not in (8, 10):
            raise ValueError('bits must be 8 or 10')
        if len(self.matrix) != 9 or len(self.bias) != 3 or \
                len(self.tone_en) != 3:
            raise ValueError('matrix/bias/tone_en field count')
        if len(self.lin) != 99 or len(self.enc) != 99:
            raise ValueError('LUT banks need 3*33 nodes')
        for v in self.matrix + self.bias:
            if not -(1 << 15) <= v < (1 << 15):
                raise ValueError('signed 16-bit field overflow')
        if self.domain not in (0, 1):
            raise ValueError('domain must be 0 or 1')

    def legal(self):
        """The exact cfg_illegal() predicate of the RTL."""
        if self.domain not in (0, 1):
            return False
        for r in range(3):
            if sum(abs(self.matrix[3 * r + j]) for j in range(3)) \
                    > ROW_GAIN_MAX:
                return False
        mx = mpx(self.bits)
        for bank in (self.lin, self.enc):
            for n in bank:
                if n > mx or n < 0:
                    return False
            for i in range(98):
                if (i % 33) != 32 and bank[i] > bank[i + 1]:
                    return False
        return True


# ---------------------------------------------------------------------------
# Bit-exact datapath (the RTL contract)
# ---------------------------------------------------------------------------

def quantize(acc, bits):
    """Round-half-away-from-zero of acc/2^13, clamped to [0, MPX]."""
    half = 1 << (FRAC - 1)
    if acc < 0:
        q = -((-acc + half) >> FRAC)
    else:
        q = (acc + half) >> FRAC
    return max(0, min(mpx(bits), q))


def matrix_channels(vals, cfg):
    """acc_c = sum_j M[c][j] * v_j + (bias_c << 13), then quantize."""
    out = []
    for c in range(3):
        acc = sum(cfg.matrix[3 * c + j] * vals[j] for j in range(3)) + \
            (cfg.bias[c] << FRAC)
        out.append(quantize(acc, cfg.bits))
    return out


def tone_chan(v, c, cfg):
    """32-segment PWL on the bank selected by domain; disabled -> passthrough.
    Interp = y0 + ((y1-y0)*frac + STEP/2) >> FB, round-half-up."""
    if not cfg.tone_en[c]:
        return v
    bank = cfg.enc if cfg.domain else cfg.lin
    fb = cfg.bits - 5
    idx = v >> fb
    frac = v & ((1 << fb) - 1)
    y0 = bank[c * NODES + idx]
    y1 = bank[c * NODES + idx + 1]
    return y0 + (((y1 - y0) * frac + (1 << (fb - 1))) >> fb)


def pixel(px, cfg):
    """Bit-exact whole-pixel transform."""
    vals = [chan(px, c, cfg.bits) for c in range(3)]
    q = matrix_channels(vals, cfg)
    return packpix([tone_chan(q[c], c, cfg) for c in range(3)], cfg.bits)


def frame(pixels, cfg):
    return [pixel(p, cfg) for p in pixels]


# ---------------------------------------------------------------------------
# Float reference (independent real-valued semantics)
# ---------------------------------------------------------------------------

def float_pixel(px, cfg):
    """Real Q2.13 matrix + real bias, then real PWL interpolation on the same
    integer node tables (monotone by legality).  Rounded half-up at the end.
    The bit-exact model differs by <= ~1.5 LSB at the quantize boundary plus
    <= 0.5 LSB of interpolation rounding."""
    mx = mpx(cfg.bits)
    vals = [chan(px, c, cfg.bits) for c in range(3)]
    out = []
    for c in range(3):
        acc = sum(cfg.matrix[3 * c + j] * vals[j] for j in range(3))
        acc = acc / (1 << FRAC) + cfg.bias[c]
        v = max(0.0, min(float(mx), acc))
        if cfg.tone_en[c]:
            bank = cfg.enc if cfg.domain else cfg.lin
            fb = cfg.bits - 5
            step = float(1 << fb)
            idx = int(v // step)
            idx = min(idx, 31)
            frac = v - idx * step
            y0 = bank[c * NODES + idx]
            y1 = bank[c * NODES + idx + 1]
            v = y0 + (y1 - y0) * frac / step
        out.append(int(max(0.0, min(float(mx), v)) + 0.5))
    return packpix(out, cfg.bits)


# ---------------------------------------------------------------------------
# Config write-stream packing and shadow/commit simulation
# ---------------------------------------------------------------------------

def ctrl_word(cfg):
    return (cfg.tone_en[0] | (cfg.tone_en[1] << 1) | (cfg.tone_en[2] << 2)
            | (cfg.domain << 3)) & 0xFFFF


def writes_for(cfg):
    """Ordered (addr, wdata) list covering the whole shadow image."""
    out = [(CTRL_ADDR, ctrl_word(cfg))]
    for i, v in enumerate(cfg.matrix):
        out.append((COEF_BASE + i, v & 0xFFFF))
    for i, v in enumerate(cfg.bias):
        out.append((BIAS_BASE + i, v & 0xFFFF))
    for i, v in enumerate(cfg.lin):
        out.append((LIN_BASE + i, v & 0xFFFF))
    for i, v in enumerate(cfg.enc):
        out.append((ENC_BASE + i, v & 0xFFFF))
    return out


class Shadow:
    """Model of the shadow bank: write-any-while-idle, frozen while a commit
    is pending; legality re-evaluated on every commit request."""

    def __init__(self, bits):
        self.bits = bits
        self.ctrl = 0
        self.matrix = [8192, 0, 0, 0, 8192, 0, 0, 0, 8192]
        self.bias = [0, 0, 0]
        self.lin = identity_nodes(bits) * 3
        self.enc = identity_nodes(bits) * 3

    def write(self, addr, data):
        data &= 0xFFFF
        if addr == CTRL_ADDR:
            self.ctrl = data
        elif COEF_BASE <= addr <= COEF_BASE + 8:
            v = data - (1 << 16) if data & 0x8000 else data
            self.matrix[addr - COEF_BASE] = v
        elif BIAS_BASE <= addr <= BIAS_BASE + 2:
            v = data - (1 << 16) if data & 0x8000 else data
            self.bias[addr - BIAS_BASE] = v
        elif LIN_BASE <= addr <= ADDR_HI_LIN:
            if data > mpx(self.bits):       # node range -> cfg_error
                return False
            self.lin[addr - LIN_BASE] = data
        elif ENC_BASE <= addr <= ADDR_HI_ENC:
            if data > mpx(self.bits):
                return False
            self.enc[addr - ENC_BASE] = data
        else:
            return False          # unmapped write -> cfg_error
        return True

    def image(self):
        return Config(matrix=tuple(self.matrix), bias=tuple(self.bias),
                      tone_en=tuple((self.ctrl >> c) & 1 for c in range(3)),
                      domain=(self.ctrl >> 3) & 1,
                      lin=tuple(self.lin), enc=tuple(self.enc),
                      bits=self.bits)

    def commit_legal(self):
        if self.ctrl >> 4:
            return False
        return self.image().legal()


def simulate(events, sof_indices, bits):
    """Replay the config script against SOF positions; return the active
    Config per frame plus the expected commit outcomes.

    ``events``: ordered list of ('w', pos, addr, data) writes and
    ('c', pos) commit requests; ``pos`` = count of pixels already accepted
    when the event fires.  A legal commit arms pending_apply and applies
    (shadow -> active) at the first SOF index >= pos: that SOF is deferred
    until the pipe drains, then the whole frame uses the new image.
    ``sof_indices``: sorted input indices that carry tuser.

    Returns ``(frame_cfg, outcomes)`` where ``frame_cfg`` maps each SOF index
    to the Config in force for that whole frame and ``outcomes`` is a list
    of ('done'|'error', domain) per commit event, plus ('error', None) for
    each unmapped write, in script order."""
    sh = Shadow(bits)
    initial = sh.image()
    pending = None               # (image, apply_sof_index)
    bounds = sorted(sof_indices)
    applied = []                 # (sof_index, image) in apply order
    outcomes = []

    for ev in events:
        pos = ev[1]
        # A pending commit whose boundary index is strictly before this
        # event's position has already applied (the SOF was presented and
        # deferred, drained, applied, then accepted).
        if pending is not None and pending[1] < pos:
            applied.append((pending[1], pending[0]))
            pending = None
        if ev[0] == 'w':
            _, _, addr, data = ev
            # writes stall behind pending_apply until the apply edge; they
            # land on the shadow afterwards (order preserved).
            if not sh.write(addr, data):
                outcomes.append(('error', None))
        else:
            if pending is not None or not sh.commit_legal():
                outcomes.append(('error', None))
                continue
            b = next((s for s in bounds if s >= pos), None)
            pending = (sh.image(), b)
            outcomes.append(('done', pending[0].domain))
    if pending is not None and pending[1] is not None:
        applied.append((pending[1], pending[0]))
        pending = None
    # frames: every SOF index gets the last image applied at or before it.
    frame_cfg = {}
    for s in bounds:
        cur = initial
        for b, img in applied:
            if b <= s:
                cur = img
        frame_cfg[s] = cur
    # 'done' outcomes whose boundary never arrives are impossible in a sane
    # script; the driver asserts every legal commit has a following SOF.
    return frame_cfg, outcomes
