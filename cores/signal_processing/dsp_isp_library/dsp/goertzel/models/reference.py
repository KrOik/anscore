"""Independent Goertzel references for DSP13.

Four independently expressed computations:
- float_goertzel: floating-point recurrence, algorithm correctness reference.
- bitexact_block: integer replica of the RTL per-block arithmetic contract.
- direct_dft_power: direct DFT sum |sum wx e^-2*pi*i*f*n|^2, the independent
  comparison the requirement asks for.
- BankModel: cycle-accurate oracle of goertzel_bank.sv for the RTL testbench.

Pure stdlib. All integer quantities are sample-LSB units (signed16 inputs,
unsigned16 Q1.15 window, signed19 Q3.16 coefficients, unsigned80 power).
"""
import math, cmath
from dataclasses import dataclass

def rne(n, d=65536):
    """Round the integer ratio n/d to nearest, ties to even. Sign symmetric;
    identical to the RTL round15/round16 functions including negative halves."""
    q, r = divmod(abs(n), d)
    q += 2 * r > d or (2 * r == d and q & 1)
    return -q if n < 0 else q

def rne_real(x):
    """Round a real value to the nearest integer, ties to even."""
    f = math.floor(x); r = x - f
    if r > .5 or (r == .5 and int(f) & 1):
        f += 1
    return int(f)

S40_MIN, S40_MAX = -(1 << 39), (1 << 39) - 1
U80_MAX = (1 << 80) - 1

@dataclass(frozen=True)
class Config:
    """n: block length 1..256. bins: 1..4 signed19 Q3.16 coefficients.
    window: n unsigned16 Q1.15 weights. thresholds: unsigned80 per bin."""
    n: int = 1
    bins: tuple = (131072,)
    window: tuple = (32768,)
    thresholds: tuple = (0,)
    def __post_init__(self):
        if not 1 <= self.n <= 256:
            raise ValueError('n must be 1..256')
        if not 1 <= len(self.bins) <= 4:
            raise ValueError('1..4 frequency bins required')
        for c in self.bins:
            if not -131072 <= c <= 131072:
                raise ValueError('coefficient outside signed19 Q3.16 +-2')
        if len(self.window) != self.n:
            raise ValueError('window length must equal n')
        for w in self.window:
            if not 0 <= w <= 32768:
                raise ValueError('window weights are unsigned16 Q1.15 <= 1.0')
        if len(self.thresholds) != len(self.bins):
            raise ValueError('one threshold per bin')
        for t in self.thresholds:
            if not 0 <= t <= U80_MAX:
                raise ValueError('thresholds are unsigned80')

def coefficient(f):
    """Host-side signed19 Q3.16 Goertzel coefficient for f cycles/input.
    The quantized coefficient defines the actual recurrence frequency."""
    c = rne_real(2 * math.cos(2 * math.pi * f) * 65536)
    if not -131072 <= c <= 131072:
        raise ValueError('frequency coefficient out of range')
    return c

def coefficient_frequency(c):
    """Effective cycles/input frequency represented by a quantized coefficient."""
    return math.acos(max(-2.0, min(2.0, c / 65536)) / 2) / (2 * math.pi)

# Window generators (SPEC: rectangular, symmetric Hann/Hamming; N=1 unity).
def window_rectangular(n):
    if not 1 <= n <= 256:
        raise ValueError('n must be 1..256')
    return (32768,) * n

def window_hann(n):
    if n == 1:
        return (32768,)
    return tuple(min(32768, max(0, rne_real(32768 * .5 * (1 - math.cos(2 * math.pi * k / (n - 1)))))) for k in range(n))

def window_hamming(n):
    if n == 1:
        return (32768,)
    return tuple(min(32768, max(0, rne_real(32768 * (.54 - .46 * math.cos(2 * math.pi * k / (n - 1)))))) for k in range(n))

def window_custom(values):
    if not 1 <= len(values) <= 256 or any(not 0 <= w <= 32768 for w in values):
        raise ValueError('custom window must be 1..256 entries in [0,32768]')
    return tuple(values)

def float_goertzel(samples, f, window=None):
    """Floating-point Goertzel power; samples are real floats (any scale).
    window: optional per-sample real weights (defaults to rectangular 1.0)."""
    c = 2 * math.cos(2 * math.pi * f); s1 = s2 = 0.0
    for i, x in enumerate(samples):
        s = x * (window[i] if window is not None else 1.0) + c * s1 - s2
        s2 = s1; s1 = s
    return s1 * s1 + s2 * s2 - c * s1 * s2

def direct_dft_power(samples, f):
    """Independent direct DFT: |sum_n x[n] e^-2j*pi*f*n|^2. No Goertzel
    recurrence is used; this is the cross-check demanded by the requirement."""
    return abs(sum(x * cmath.exp(-2j * math.pi * f * k) for k, x in enumerate(samples))) ** 2

def state_bound(n):
    """Conservative |s1|,|s2| bound including half-LSB recurrence rounding,
    from SPEC: (32768+0.5)*n*(n+1)/2 < 2^31; signed40 has ample guard bits."""
    return (32768.5 * n * (n + 1)) / 2

def dft_agreement_bound(n):
    """Documented conservative |P_goertzel - P_direct_dft| bound in LSB^2.

    Each recurrence step adds <=0.5 LSB of RNE error. The homogeneous
    response of s=c*s1-s2 for c=2cos(t) is sin((k+1)t)/sin(t), bounded by k+1,
    so |s_error| <= n(n+1)/4 at block end. With |s|<=B=state_bound(n):
      |dP| <= 8*B*delta + 2*delta^2 + 0.5*B
    where the last term covers RNE(c*s1/65536) replacing c*s1 in the terminal
    power (<=0.5 LSB error times |s2|). Loose but unconditional."""
    delta = n * (n + 1) / 4.0; b = state_bound(n)
    return 8 * b * delta + 2 * delta * delta + 0.5 * b

def bitexact_block(samples, cfg):
    """Bit-exact per-block result of the RTL contract. Returns one dict per
    configured bin in emission order: power (unsigned80 clipped), bin index,
    last flag, detect=(power>=threshold) and the sticky in-block error flag.
    State saturation / terminal clip mark error and are repeated on the
    remaining bin outputs; both are unreachable with legal parameters."""
    if len(samples) != cfg.n:
        raise ValueError('block length mismatch')
    wx = [rne(x * w, 32768) for x, w in zip(samples, cfg.window)]
    out = []; block_error = False
    for b, (c, th) in enumerate(zip(cfg.bins, cfg.thresholds)):
        s1 = s2 = 0
        for w in wx:
            s = w + rne(c * s1, 65536) - s2
            s2 = s1
            if s > S40_MAX:
                s1 = S40_MAX; block_error = True
            elif s < S40_MIN:
                s1 = S40_MIN; block_error = True
            else:
                s1 = s
        terminal_c = rne(c * s1, 65536)
        p = s1 * s1 + s2 * s2 - terminal_c * s2
        if p < 0:
            power = 0; block_error = True
        elif p > U80_MAX:
            power = U80_MAX; block_error = True
        else:
            power = p
        out.append({'power': power, 'bin': b, 'last': int(b == len(cfg.bins) - 1),
                    'detect': int(power >= th), 'error': int(block_error)})
    return out

# Packing helpers for the RTL configuration port.
def pack_coeffs(coeffs4):
    return sum((c & ((1 << 19) - 1)) << (19 * i) for i, c in enumerate(coeffs4))

def pack_window(window256):
    return sum((w & 0xFFFF) << (16 * i) for i, w in enumerate(window256))

def pack_thresholds(thresholds4):
    return sum((t & U80_MAX) << (80 * i) for i, t in enumerate(thresholds4))

WAIT, WS, WW, RS, RW, AS, AW, BS, BW, CS, CW, DS, DW, OUT = range(14)

class Mul48:
    """Cycle-accurate replica of goertzel_mul48: signed 48x48 shift-add,
    start -> done 49 clocks later, result held until the next start."""
    def __init__(self):
        self.busy = False; self.done = False; self.result = 0
        self.negative = False; self.count = 0
        self.multiplicand = 0; self.multiplier = 0; self.acc = 0
    def edge(self, start, a, b):
        self.done = False
        if start and not self.busy:
            self.busy = True; self.negative = (a < 0) != (b < 0)
            self.count = 0; self.acc = 0
            self.multiplicand = abs(a); self.multiplier = abs(b)
        elif self.busy:
            na = self.acc + (self.multiplicand if self.multiplier & 1 else 0)
            self.acc = na
            self.multiplicand = (self.multiplicand << 1) & ((1 << 96) - 1)
            self.multiplier >>= 1; self.count += 1
            if self.count == 48:
                self.result = -na if self.negative else na
                self.done = True; self.busy = False

class BankModel:
    """Cycle-accurate oracle of goertzel_bank. Drive once per clock with the
    same inputs the TB applies; outputs() exposes the expected values for the
    current cycle before edge() advances state."""
    def __init__(self):
        self.mul = Mul48(); self.reset()
    def reset(self):
        self.state = WAIT; self.n = 1; self.index = 0; self.nbins = 1; self.bin_i = 0
        self.coeff = [131072] * 4; self.window = [32768] * 256
        self.threshold = [0] * 4; self.s1 = [0] * 4; self.s2 = [0] * 4
        self.sample = 0; self.wx = 0; self.terminal_c = 0; self.power_sum = 0
        self.block_error = False
        self.m_power = 0; self.m_bin = 0; self.m_last = 0
        self.m_detect = 0; self.m_error = 0; self.m_valid = False
        self.cfg_done = 0; self.cfg_error = 0
        self.mul = Mul48()
    def outputs(self, rst_n, cfg_valid):
        """Combinational ready outputs plus current registered outputs, i.e.
        everything the TB compares during this cycle."""
        rst = bool(rst_n)
        return {
            's_tready': int(rst and self.state == WAIT and not (cfg_valid and self.index == 0)),
            'cfg_ready': int(rst and self.state == WAIT and self.index == 0 and not self.m_valid),
            'm_valid': int(self.m_valid), 'm_power': self.m_power, 'm_bin': self.m_bin,
            'm_last': self.m_last, 'm_detect': self.m_detect, 'm_error': self.m_error,
            'cfg_done': self.cfg_done, 'cfg_error': self.cfg_error}
    def edge(self, rst_n, s_tdata, s_tvalid, m_ready,
             cfg_valid, cfg_n, cfg_bins, cfg_coeffs, cfg_window, cfg_thresholds):
        """Advance one clock. cfg_* are the raw request fields (list of 4
        coeffs, list of 256 window words, list of 4 thresholds)."""
        # Combinational helpers on pre-edge state, matching RTL wires.
        bad = cfg_n < 1 or cfg_n > 256 or cfg_bins < 1 or cfg_bins > 4
        if not bad:
            for k in range(4):
                if k < cfg_bins and not -131072 <= cfg_coeffs[k] <= 131072:
                    bad = True
            for k in range(256):
                if k < cfg_n and cfg_window[k] > 32768:
                    bad = True
        st = self.state; ma = mb = 0
        if st == WS:
            ma, mb = self.sample, self.window[self.index]
        elif st in (RS, CS):
            ma, mb = self.coeff[self.bin_i], self.s1[self.bin_i]
        elif st == AS:
            ma, mb = self.s1[self.bin_i], self.s1[self.bin_i]
        elif st == BS:
            ma, mb = self.s2[self.bin_i], self.s2[self.bin_i]
        elif st == DS:
            ma, mb = self.terminal_c, self.s2[self.bin_i]
        start = st in (WS, RS, AS, BS, CS, DS)
        mdone = self.mul.done; product = self.mul.result
        recur = rne(product, 65536) + self.wx - self.s2[self.bin_i]
        terminal = self.power_sum - product
        clipped = 0 if terminal < 0 else (U80_MAX if terminal >= (1 << 80) else terminal)
        s_tready = bool(rst_n) and st == WAIT and not (cfg_valid and self.index == 0)
        cfg_ready = bool(rst_n) and st == WAIT and self.index == 0 and not self.m_valid
        if not rst_n:
            self.reset(); return
        self.cfg_done = 0; self.cfg_error = 0
        if cfg_valid and cfg_ready:
            self.cfg_done = 1; self.cfg_error = int(bad)
            if not bad:
                self.n = cfg_n; self.nbins = cfg_bins; self.block_error = False
                for i in range(4):
                    self.coeff[i] = cfg_coeffs[i]; self.threshold[i] = cfg_thresholds[i]
                    self.s1[i] = 0; self.s2[i] = 0
                self.window = list(cfg_window)
        elif st == WAIT:
            if s_tvalid and s_tready:
                self.sample = s_tdata; self.bin_i = 0; self.state = WS
        elif st == WS:
            self.state = WW
        elif st == WW:
            if mdone:
                self.wx = rne(product, 32768); self.state = RS
        elif st == RS:
            self.state = RW
        elif st == RW:
            if mdone:
                self.s2[self.bin_i] = self.s1[self.bin_i]
                if recur > S40_MAX:
                    self.s1[self.bin_i] = S40_MAX; self.block_error = True
                elif recur < S40_MIN:
                    self.s1[self.bin_i] = S40_MIN; self.block_error = True
                else:
                    self.s1[self.bin_i] = recur
                if self.bin_i + 1 < self.nbins:
                    self.bin_i += 1; self.state = RS
                elif self.index + 1 < self.n:
                    self.index += 1; self.state = WAIT
                else:
                    self.bin_i = 0; self.state = AS
        elif st == AS:
            self.state = AW
        elif st == AW:
            if mdone:
                self.power_sum = product; self.state = BS
        elif st == BS:
            self.state = BW
        elif st == BW:
            if mdone:
                self.power_sum += product; self.state = CS
        elif st == CS:
            self.state = CW
        elif st == CW:
            if mdone:
                self.terminal_c = rne(product, 65536); self.state = DS
        elif st == DS:
            self.state = DW
        elif st == DW:
            if mdone:
                self.m_power = clipped; self.m_bin = self.bin_i
                self.m_last = int(self.bin_i + 1 == self.nbins)
                self.m_detect = int(clipped >= self.threshold[self.bin_i])
                self.m_error = int(self.block_error or terminal < 0 or terminal >= (1 << 80))
                if terminal < 0 or terminal >= (1 << 80):
                    self.block_error = True
                self.m_valid = True; self.state = OUT
        elif st == OUT:
            if m_ready:
                self.m_valid = False
                if self.bin_i + 1 < self.nbins:
                    self.bin_i += 1; self.state = AS
                else:
                    self.state = WAIT; self.index = 0; self.bin_i = 0
                    self.block_error = False; self.s1 = [0] * 4; self.s2 = [0] * 4
        # Multiplier registers update in parallel with the parent FSM; its
        # operands and the parent's view of done/result are pre-edge values.
        self.mul.edge(start, ma, mb)
