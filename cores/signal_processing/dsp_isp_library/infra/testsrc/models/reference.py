"""Independent bit-exact models for INFRA-07 stream test sources and checkers.

Pure Python stdlib. These functions define the exact output contract of the
RTL in ../rtl and never read DUT outputs. See SPEC.md for the full contract.
"""
import zlib
from dataclasses import dataclass

MASK16 = 0xFFFF
U32 = 0xFFFFFFFF

# --------------------------------------------------------------------------
# PRBS-16 source model.
# Fibonacci right-shift LFSR. Characteristic polynomial
#   p(x) = x^16 + x^5 + x^3 + x^2 + 1  (primitive; verified period 2**16-1)
# which is the reciprocal polynomial of x^16+x^14+x^13+x^11+1.
# Each step: output bit = state[0]; feedback = parity(state & 0x002D);
# state = {feedback, state[15:1]}.
# Each emitted 16-bit word packs 16 consecutive serial bits MSB-first:
# tdata[15] is the first bit in time, tdata[0] the 16th.
# --------------------------------------------------------------------------
PRBS16_TAPS = 0x002D  # state bits 0,2,3,5

def prbs16_step(state):
    fb = bin(state & PRBS16_TAPS).count('1') & 1
    return ((state >> 1) | (fb << 15)) & MASK16

def prbs16_gen16(state):
    """Emit one packed word from `state`; return (next_state, word)."""
    w = 0
    for i in range(16):
        w |= (state & 1) << (15 - i)
        state = prbs16_step(state)
    return state, w

def prbs16_words(seed, n):
    """First n emitted words after arming with `seed` (seed state is used)."""
    state = seed & MASK16
    out = []
    for _ in range(n):
        state, w = prbs16_gen16(state)
        out.append(w)
    return out

def prbs16_period():
    """Return cycle length of the serial bit stream from state 1."""
    s, n = 1, 0
    while True:
        s = prbs16_step(s)
        n += 1
        if s == 1:
            return n

# --------------------------------------------------------------------------
# CRC-32 (IEEE 802.3): reflected polynomial 0xEDB88320 (normal 0x04C11DB7),
# init 0xFFFFFFFF, xorout 0xFFFFFFFF, refin/refout true.
# Each accepted beat consumes its tdata word LSB-first; for DATA_WIDTH=8 that
# is exactly one byte per beat, for DATA_WIDTH=16 two little-endian bytes.
# --------------------------------------------------------------------------
CRC32_POLY = 0xEDB88320
CRC32_INIT = 0xFFFFFFFF
CRC32_XOROUT = 0xFFFFFFFF

def crc32_bit(state, bit):
    return ((state >> 1) ^ CRC32_POLY) if (state ^ bit) & 1 else (state >> 1)

def crc32_word(state, word, width):
    for _ in range(width):
        state = crc32_bit(state, word & 1)
        word >>= 1
    return state

def crc32_words(words, width=16, init=CRC32_INIT, xorout=CRC32_XOROUT):
    st = init
    for w in words:
        st = crc32_word(st, w, width)
    return st ^ xorout

# --------------------------------------------------------------------------
# Tone source model. Phase accumulators are Q0.32 (phase in cycles * 2**32).
# Sine lookup: quarter-wave ROM, 64 entries, midpoint sampled,
#   LUT[i] = round(32767 * sin(pi/2 * (i + 0.5) / 64)), i = 0..63.
# phase[31:30] selects the quadrant, phase[29:24] the index:
#   Q0: +LUT[i]  Q1: +LUT[63-i]  Q2: -LUT[i]  Q3: -LUT[63-i].
# Output mix: acc = sum_i amp_i * sine_i  (Q1.15 * Q1.15 products),
#   y = saturate16((acc + 2**14) >> 15)   (round half up, arithmetic shift).
# Sample k uses phase = init + k*inc; phases advance after each transfer.
# --------------------------------------------------------------------------
def _build_lut():
    import math
    return tuple(round(32767 * math.sin(math.pi / 2 * (i + 0.5) / 64))
                 for i in range(64))

SINE_LUT = _build_lut()

def sine_q15(phase):
    q = (phase >> 30) & 3
    i = (phase >> 24) & 0x3F
    v = SINE_LUT[i if q in (0, 2) else 63 - i]
    return -v if q >= 2 else v

def sat16(v):
    return max(-32768, min(32767, v))

def mix_sample(phases, amps):
    acc = sum(a * sine_q15(p) for a, p in zip(amps, phases))
    return sat16((acc + 0x4000) >> 15)

@dataclass(frozen=True)
class ToneCfg:
    mode: int = 0            # 0 multitone, 1 sweep
    ntone: int = 1           # 1..4 (multitone); sweep uses tone 0 only
    inc: tuple = (0x01000000,) * 4    # Q0.32 phase step per emitted sample
    phase: tuple = (0,) * 4           # Q0.32 initial phase of sample 0
    amp: tuple = (16384,) * 4         # signed Q1.15 per tone
    sw_step: int = 0                  # signed increment applied to inc
    sw_stop: int = 0                  # wrap threshold (unsigned compare domain)
    sw_dwell: int = 1                 # emitted samples per sweep step, >=1

def _s32(v):
    v &= U32
    return v - 0x100000000 if v & 0x80000000 else v

def tone_samples(cfg, n):
    """Return (samples, wrap_indices). wrap_indices lists the transfer index
    whose post-transfer update wrapped the sweep increment back to inc[0]."""
    if cfg.mode not in (0, 1):
        raise ValueError('mode')
    if cfg.mode == 0 and not 1 <= cfg.ntone <= 4:
        raise ValueError('ntone')
    if cfg.mode == 1 and cfg.sw_dwell < 1:
        raise ValueError('dwell')
    nt = cfg.ntone if cfg.mode == 0 else 1
    phases = [p & U32 for p in cfg.phase[:nt]]
    amps = [a if -32768 <= a <= 32767 else (_ for _ in ()).throw(ValueError('amp'))
            for a in cfg.amp[:nt]]
    incs = [i & U32 for i in cfg.inc[:nt]]
    inc_cur = incs[0]
    step = cfg.sw_step & U32
    stop = cfg.sw_stop & U32
    dwell = 0
    out, wraps = [], []
    for k in range(n):
        out.append(mix_sample(phases, amps))
        for t in range(nt):
            phases[t] = (phases[t] + (inc_cur if cfg.mode == 1 else incs[t])) & U32
        if cfg.mode == 1:
            dwell += 1
            if dwell == cfg.sw_dwell:
                dwell = 0
                inc_cur = (inc_cur + _s32(step)) & U32
                wrapped = (step & 0x80000000 and inc_cur < stop) or \
                          (not step & 0x80000000 and step != 0 and inc_cur > stop)
                if wrapped:
                    inc_cur = incs[0]
                    wraps.append(k)
    return out, wraps

# --------------------------------------------------------------------------
# Image pattern source model. Beat = one pixel, DATA_WIDTH bits unsigned.
# tuser(SOF) marks pixel (0,0) of every frame; tlast(EOL) marks x == W-1.
# Pixel (0,0) always carries the frame sequence number (frame mod 2**W_bits);
# every other pixel follows the configured pattern.
# Patterns: 0 HGRAD v=x&M; 1 VGRAD v=y&M; 2 DIAG v=(x+y)&M;
#   3 CHECKER1 v=((x+y)&1)?M:0; 4 CHECKER8 v=(((x>>3)+(y>>3))&1)?M:0;
#   5 COLORBAR v=floor(8x/W)*(M//7), requires W>=8;
#   6 SOLID v=(frame*37)&M.
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class ImgCfg:
    w: int = 4
    h: int = 3
    pattern: int = 0
    nframes: int = 0        # 0 = unlimited
    bits: int = 8           # DATA_WIDTH
    def __post_init__(self):
        if not 1 <= self.w <= 4096 or not 1 <= self.h <= 4096:
            raise ValueError('W/H 1..4096')
        if not 0 <= self.pattern <= 6:
            raise ValueError('pattern 0..6')
        if self.pattern == 5 and self.w < 8:
            raise ValueError('COLORBAR needs W>=8')
        if not 1 <= self.bits <= 16:
            raise ValueError('bits 1..16')

def image_pixel(cfg, frame, x, y):
    M = (1 << cfg.bits) - 1
    if x == 0 and y == 0:
        return frame & M                       # frame sequence number
    p = cfg.pattern
    if p == 0:
        return x & M
    if p == 1:
        return y & M
    if p == 2:
        return (x + y) & M
    if p == 3:
        return M if (x + y) & 1 else 0
    if p == 4:
        return M if ((x >> 3) + (y >> 3)) & 1 else 0
    if p == 5:
        return (8 * x // cfg.w) * (M // 7)
    return (37 * frame) & M                    # pattern 6 SOLID

def image_beats(cfg, nframes=None):
    """Return [(pix, sof, eol, frame)] for nframes frames (or cfg.nframes)."""
    nf = cfg.nframes if nframes is None else nframes
    if nf == 0:
        raise ValueError('unbounded stream')
    out = []
    for f in range(nf):
        for y in range(cfg.h):
            for x in range(cfg.w):
                out.append((image_pixel(cfg, f, x, y),
                            int(x == 0 and y == 0), int(x == cfg.w - 1), f))
    return out

# --------------------------------------------------------------------------
# Backpressure sink model. The ready pattern is a free-running function of
# the clock, advanced once per clock while armed (independent of transfers).
#   mode 0: ready = 1
#   mode 1: ready = (lfsr[7:0] >= threshold); lfsr uses the PRBS-16 step above
#   mode 2: cyclic run/stall: ready for `run` clocks then stalled `stall`
#           clocks, repeated; run+stall must be >= 1. run==0 stalls forever.
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class BpCfg:
    mode: int = 0
    seed: int = 1
    threshold: int = 0
    run: int = 1
    stall: int = 0
    def __post_init__(self):
        if not 0 <= self.mode <= 2:
            raise ValueError('mode')
        if not 0 <= self.seed <= MASK16 or not 0 <= self.threshold <= 0xFF:
            raise ValueError('seed/threshold')
        if self.mode == 2 and self.run + self.stall < 1:
            raise ValueError('run+stall')

class BpModel:
    """Cycle-level ready pattern; call ready() then tick() per clock."""
    def __init__(self, cfg):
        self.cfg = cfg
        self.lfsr = cfg.seed & MASK16
        self.pos = 0
    def ready(self):
        c = self.cfg
        if c.mode == 0:
            return 1
        if c.mode == 1:
            return int((self.lfsr & 0xFF) >= c.threshold)
        return int(self.pos < c.run)
    def tick(self):
        c = self.cfg
        self.lfsr = prbs16_step(self.lfsr)
        if c.mode == 2:
            self.pos = (self.pos + 1) % (c.run + c.stall)

def bp_ready_seq(cfg, cycles):
    m = BpModel(cfg)
    out = []
    for _ in range(cycles):
        out.append(m.ready())
        m.tick()
    return out

# --------------------------------------------------------------------------
# Stream sink checker model. Checks per accepted beat:
#   count  : total beats; done asserts when count reaches cfg.expected;
#            further beats set err_extra.
#   crc    : when cfg.crc_en, at the done beat compare
#            crc32_words(all_beats)^0xFFFFFFFF vs cfg.crc -> err_crc.
#   seq    : when cfg.seq_en, tdata must equal seq_exp; seq_exp += step
#            (mod 2**bits) after each beat -> err_seq.
#   image  : when cfg.img_en, expected tuser=(x==0&&y==0), tlast=(x==W-1);
#            mismatch sets err_sof/err_eol; frames counts tuser beats.
# first_error records the 0-based index of the first flagging beat
# (0xFFFFFFFF = none).
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class ChkCfg:
    expected: int = 1
    crc_en: int = 0
    crc: int = 0
    seq_en: int = 0
    seq_start: int = 0
    seq_step: int = 1
    img_en: int = 0
    img_w: int = 1
    img_h: int = 1
    bits: int = 8
    trig_mode: int = 0      # 0 off, 1 first-error, 2 done, 3 every period beats
    trig_period: int = 0
    def __post_init__(self):
        if self.expected < 1:
            raise ValueError('expected>=1')
        if self.img_en and (self.img_w < 1 or self.img_h < 1):
            raise ValueError('img W/H')
        if not 0 <= self.trig_mode <= 3:
            raise ValueError('trig_mode')
        if self.trig_mode == 3 and self.trig_period < 1:
            raise ValueError('trig_period')
        if not 1 <= self.bits <= 16:
            raise ValueError('bits')

class ChkModel:
    """feed()/edge() process one clock edge. Both return the value `trigger`
    must show during the cycle AFTER that edge (flags update on the same
    visibility rule: a flag registered at edge E is readable in row E+1)."""
    def __init__(self, cfg):
        self.cfg = cfg
        self.count = 0
        self.frames = 0
        self.done = 0
        self.err_crc = self.err_seq = self.err_sof = self.err_eol = self.err_extra = 0
        self.first_error = U32
        self.crc_state = CRC32_INIT
        self.seq_exp = cfg.seq_start & ((1 << cfg.bits) - 1)
        self.x = self.y = 0
        self.crc_pending = False
        self._crc_idx = 0
        self._trig_cnt = 0
        self._trig_fired_err = False
        self._trig_fired_done = False
    def _flag(self, name, index=None):
        trig = 0
        setattr(self, name, 1)
        if self.first_error == U32:
            self.first_error = self.count if index is None else index
        if self.cfg.trig_mode == 1 and not self._trig_fired_err:
            self._trig_fired_err = True
            trig = 1
        return trig
    def _crc_compare(self):
        trig = 0
        if self.crc_pending:
            self.crc_pending = False
            if (self.crc_state ^ CRC32_XOROUT) != (self.cfg.crc & U32):
                trig |= self._flag('err_crc', index=self._crc_idx)
        return trig
    def feed(self, data, user, last):
        """Process the edge that accepts one beat; returns next-row trigger."""
        c = self.cfg
        trig = self._crc_compare()
        if self.done:
            trig |= self._flag('err_extra')
        if c.seq_en:
            if data != self.seq_exp:
                trig |= self._flag('err_seq')
            self.seq_exp = (self.seq_exp + c.seq_step) & ((1 << c.bits) - 1)
        if c.img_en:
            if user != int(self.x == 0 and self.y == 0):
                trig |= self._flag('err_sof')
            if last != int(self.x == c.img_w - 1):
                trig |= self._flag('err_eol')
            if self.x == c.img_w - 1:
                self.x = 0
                self.y = 0 if self.y == c.img_h - 1 else self.y + 1
            else:
                self.x += 1
        if user:
            self.frames += 1
        self.crc_state = crc32_word(self.crc_state, data, c.bits)
        self.count += 1
        if self.count == c.expected:
            self.done = 1
            if c.trig_mode == 2 and not self._trig_fired_done:
                self._trig_fired_done = True
                trig = 1
            if c.crc_en:
                self.crc_pending = True
                self._crc_idx = self.count - 1
        if c.trig_mode == 3:
            self._trig_cnt += 1
            if self._trig_cnt == c.trig_period:
                self._trig_cnt = 0
                trig = 1
        return trig
    def edge(self):
        """Idle-clock edge (CRC compare fires one edge after the done beat)."""
        return self._crc_compare()
    def verdict(self):
        return dict(done=self.done, count=self.count, frames=self.frames,
                    err_crc=self.err_crc, err_seq=self.err_seq,
                    err_sof=self.err_sof, err_eol=self.err_eol,
                    err_extra=self.err_extra, first_error=self.first_error)
