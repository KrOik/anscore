"""Independent ISP-17 frame-difference / background-model references.

Two references live here; neither imports RTL or DUT data.

* ``float_run_frame`` -- real-valued running-mean background
  (bg += (cur - bg) / 2**alpha).  Used to state ideal convergence.
* ``run_frame`` -- the bit-exact contract implemented by
  ``rtl/framediff_stream.sv``.  ``>>`` below is Python's floor shift on
  the signed difference, matching the RTL ``>>>`` arithmetic shift.

Modes (``cfg_mode``):
    0 DIFF   : mask = |cur - ref| > thresh ; ref' = cur
    1 BG     : out  = ref' = ref + ((cur - ref) >> alpha_eff)
    2 MOTION : mask = |cur - ref| > thresh ; ref' like mode 1

The reference store ``state.ref`` is a flat array of ``max_w*max_h``
entries indexed by the current raster offset ``y*W + x`` -- it models the
physical frame RAM, so entries persist across frames and across geometry
reconfigurations exactly like the hardware array.

Seeding (``state.valid`` false): the whole frame writes ref' = cur, diffs
are forced to 0 (masks all-zero, mode-1 output = cur).  ``valid`` sets at
the end of a completely streamed frame.

Scene change (evaluated at frame end, ``chg`` = number of pixels with a
real diff > thresh, always 0 while seeding):
    event = (chg << 7) > W*H*scn          (scn in 0..128; 128 disables)
    scpol = 0 RESET      -> valid=False   (next frame re-seeds)
    scpol = 1 FAST_ADAPT -> fa=True       (next frame uses alpha_eff = 0:
                                           ref' = cur, real diffs emitted)
Committing a different W/H clears ``valid`` (the new-geometry frame
re-seeds) and also consumes/clears any pending fast-adapt flag.

Update-equation convergence (documented in ../SPEC.md):
  from below (cur > bg): the step floor((cur-bg)/2^a) is 0 once the
  residual is < 2^a, so the background parks at most ``2^alpha - 1``
  below the target -- ``residual_bound(alpha)``.
  from above (cur < bg): the floor shift is <= -1 while cur < bg, so the
  background descends to the exact target.
"""
from dataclasses import dataclass

MODE_DIFF = 0
MODE_BG = 1
MODE_MOTION = 2
SCN_DISABLE = 128          # scene-change threshold "never"


def mpx(bits):
    return (1 << bits) - 1


def residual_bound(alpha):
    """Worst-case parked residual of the running mean: 2^alpha - 1 LSB."""
    return (1 << alpha) - 1


def frames_to_bound(err0, alpha, eps=1.0):
    """Sufficient frame count for |bg - c| <= 2**alpha-1 + eps.

    While the residual e >= 2^a the update removes floor(e/2^a) >=
    (e - 2^a + 1)/2^a, giving e_n <= (e0 - (2^a - 1)) * r^n + (2^a - 1)
    with r = 1 - 2^-a.  Solve for the bound + eps.
    """
    r = 1.0 - 2.0 ** (-alpha)
    bound = float(residual_bound(alpha))
    head = max(0.0, err0 - bound)
    if head <= eps:
        return 0
    if r <= 0.0:
        return 1            # alpha = 0 adopts cur in a single frame
    import math
    return int(math.ceil(math.log(head / eps) / -math.log(r)))


@dataclass(frozen=True)
class Config:
    """Atomic runtime configuration; every field committed or rejected whole."""
    width: int
    height: int
    mode: int = MODE_DIFF   # 0 DIFF, 1 BG, 2 MOTION
    thresh: int = 0         # difference > thresh marks a changed pixel
    alpha: int = 4          # running-mean step 2^-alpha, 0..15
    scn: int = SCN_DISABLE  # changed fraction in 1/128 units, 0..128
    scpol: int = 0          # 0 RESET, 1 FAST_ADAPT
    bits: int = 8

    def __post_init__(self):
        if not 1 <= self.width <= 8191 or not 1 <= self.height <= 8191:
            raise ValueError('frame dims out of range')
        if self.mode not in (0, 1, 2):
            raise ValueError('mode out of range')
        if not 0 <= self.thresh <= mpx(self.bits):
            raise ValueError('thresh out of range')
        if not 0 <= self.alpha <= 15:
            raise ValueError('alpha out of range')
        if not 0 <= self.scn <= SCN_DISABLE:
            raise ValueError('scn out of range')
        if self.scpol not in (0, 1):
            raise ValueError('scpol out of range')
        if self.bits not in (8, 10):
            raise ValueError('unsupported pixel width')

    def pack(self):
        """51-bit config word, layout shared with tests/tb_framediff.sv:
        [12:0]w [25:13]h [27:26]mode [37:28]thresh [41:38]alpha
        [49:42]scn [50]scpol."""
        return (self.width | (self.height << 13) | (self.mode << 26)
                | (self.thresh << 28) | (self.alpha << 38)
                | (self.scn << 42) | (self.scpol << 50))


class State:
    """Bit-exact cross-frame state of the core (the reference RAM plus the
    valid / fast-adapt flags and the committed geometry)."""

    def __init__(self, max_w, max_h):
        self.ref = [0] * (max_w * max_h)
        self.valid = False
        self.fa = False
        self.w = 0
        self.h = 0


def _check_frame(frame, w, h):
    if len(frame) != h or any(len(r) != w for r in frame):
        raise ValueError('frame shape does not match config')
    for row in frame:
        for v in row:
            if not isinstance(v, int) or v < 0:
                raise ValueError('pixels must be unsigned integers')


def run_frame(frame, cfg, state):
    """Bit-exact per-pixel contract.  Returns (out2d, event): the output
    image and whether the frame ends with a scene-change event."""
    w, h = cfg.width, cfg.height
    _check_frame(frame, w, h)
    if (state.w, state.h) != (w, h):
        # geometry commit clears validity; the fast-adapt flag is *not*
        # cleared here (hardware only clears it at a frame end), but it is
        # inert while seeding: ref' = cur regardless of alpha_eff.
        state.valid = False
        state.w, state.h = w, h
    v = state.valid
    aeff = 0 if state.fa else cfg.alpha
    mp = mpx(cfg.bits)
    chg = 0
    out = []
    for y in range(h):
        orow = []
        for x in range(w):
            a = y * w + x
            cur = frame[y][x]
            ref = state.ref[a]
            diff = abs(cur - ref)
            moved = v and diff > cfg.thresh
            chg += moved
            if (not v) or cfg.mode == MODE_DIFF:
                nref = cur
            else:
                nref = ref + ((cur - ref) >> aeff)
            if cfg.mode == MODE_BG:
                o = nref
            else:
                o = mp if moved else 0
            state.ref[a] = nref
            orow.append(o)
        out.append(orow)
    event = bool(v) and (chg << 7) > w * h * cfg.scn
    if event:
        state.valid = bool(cfg.scpol)
        state.fa = bool(cfg.scpol)
    else:
        state.valid = True
        state.fa = False
    return out, event


class FloatState:
    """Real-valued background for the float reference (same policies)."""

    def __init__(self, max_w, max_h):
        self.bg = [0.0] * (max_w * max_h)
        self.valid = False
        self.fa = False
        self.w = 0
        self.h = 0


def float_run_frame(frame, cfg, state):
    """Float reference: bg += (cur - bg) * 2^-alpha_eff; same seeding,
    scene-change detection (integer diff threshold) and policies."""
    w, h = cfg.width, cfg.height
    _check_frame(frame, w, h)
    if (state.w, state.h) != (w, h):
        state.valid = False
        state.w, state.h = w, h
    v = state.valid
    beta = 1.0 if state.fa else 2.0 ** (-cfg.alpha)
    mp = mpx(cfg.bits)
    chg = 0
    out = []
    for y in range(h):
        orow = []
        for x in range(w):
            a = y * w + x
            cur = float(frame[y][x])
            ref = state.bg[a]
            moved = v and abs(cur - ref) > cfg.thresh
            chg += moved
            nref = cur if (not v) or cfg.mode == MODE_DIFF \
                else ref + (cur - ref) * beta
            orow.append(nref if cfg.mode == MODE_BG
                        else float(mp) if moved else 0.0)
            state.bg[a] = nref
        out.append(orow)
    event = bool(v) and (chg << 7) > w * h * cfg.scn
    if event:
        state.valid = bool(cfg.scpol)
        state.fa = bool(cfg.scpol)
    else:
        state.valid = True
        state.fa = False
    return out, event
