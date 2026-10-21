"""Independent references for the Hilbert analytic-signal core.

Floating model: ideal antisymmetric windowed Hilbert FIR, real-path group
delay CENTER=2*PAIRS-1, math.atan2 phase, math.hypot envelope and an
unwrapped first-difference frequency. Bit-exact model: integer pair
differences, signed18xsigned17 products, RNE/saturated Q, first-octant
17-step restoring divider, 257-entry atan LUT plus delta interpolation,
sigma=+/-1 CORDIC x-path envelope scaled by ENV_C, and wrapped brad
frequency. All arithmetic below is integer and mirrors the RTL exactly.
"""
import math, cmath
from dataclasses import dataclass

PAIRS = 16
TAPS = 4 * PAIRS - 1            # 63 for the default configuration
CENTER = 2 * PAIRS - 1          # group delay in samples (31)
DIV_BITS = 17                   # restoring-division iterations
ATAN_RES = 256                  # atan table segments over r in [0,1]
ENV_SHIFT = 19

def rne(v, b):
    """Round-half-to-even of v / 2**b; v is a signed integer."""
    q = v >> b
    r = v & ((1 << b) - 1)
    return q + (r > (1 << (b - 1)) or (r == (1 << (b - 1)) and q & 1))

def sat16(v):
    return min(32767, max(-32768, v))

def design(pairs=PAIRS):
    """Blackman-windowed ideal Hilbert transformer.

    Unique signed18 Q15 coefficients c_j = h[CENTER-(2j+1)] (negative-half
    tap of each antisymmetric pair). Returns (coeff_int tuple, float taps).
    """
    if not 1 <= pairs <= 32:
        raise ValueError('pairs')
    taps = 4 * pairs - 1
    center = 2 * pairs - 1
    h = [0.0] * taps
    for j in range(pairs):
        d = 2 * j + 1
        w = 0.42 - 0.5 * math.cos(2 * math.pi * (center + d) / (taps - 1)) \
            + 0.08 * math.cos(4 * math.pi * (center + d) / (taps - 1))
        h[center + d] = 2.0 * w / (math.pi * d)
        h[center - d] = -h[center + d]
    coeffs = tuple(round(h[center - (2 * j + 1)] * 32768) for j in range(pairs))
    return coeffs, h

DEFAULT_COEFFS, DEFAULT_FLOAT = design(PAIRS)

# ---------------------------------------------------------------- tables
ATAN_P = [round(math.atan(i / ATAN_RES) * 65536 / (2 * math.pi))
          for i in range(ATAN_RES + 1)]          # 14-bit, brads
ATAN_D = [ATAN_P[i + 1] - ATAN_P[i] for i in range(ATAN_RES)]  # 6-bit

_K = 1.0
for _i in range(16):
    _K *= math.sqrt(1 + 2.0 ** (-2 * _i))
ENV_C = round((1.0 / (16 * _K)) * (1 << ENV_SHIFT))  # 19898

# ------------------------------------------------------ bit-exact pieces
def divider17(a, b):
    """floor(a * 2**17 / b), identical to 17 pipelined restoring steps."""
    if not (0 <= a <= b and b > 0):
        raise ValueError('divider operands')
    rem = a
    q = 0
    for _ in range(DIV_BITS):
        rem <<= 1
        if rem >= b:
            rem -= b
            q = q * 2 + 1
        else:
            q = q * 2
    return q

def cordic_magnitude(i16, q16):
    """x-path of a vectoring CORDIC, sigma=+1 for y>=0 else -1, inputs <<4."""
    ai, aq = abs(i16), abs(q16)
    x = max(ai, aq) << 4
    y = min(ai, aq) << 4
    for k in range(16):
        if y >= 0:
            x, y = x + (y >> k), y - (x >> k)
        else:
            x, y = x - (y >> k), y + (x >> k)
    return x

def envelope(i16, q16):
    env = rne(cordic_magnitude(i16, q16) * ENV_C, ENV_SHIFT)
    return min(65535, env)

def phase_octant(i16, q16):
    """First-octant angle in brads plus the remapping flags."""
    ai, aq = abs(i16), abs(q16)
    b = max(ai, aq)
    a = min(ai, aq)
    if b == 0:
        return 0, False
    r = (divider17(a, b) + 1) >> 1              # 0..65536
    idx = 256 if r >= 65536 else r >> 8
    frac = 0 if r >= 65536 else r & 255
    theta = ATAN_P[idx] + (rne(ATAN_D[idx] * frac, 8) if idx < 256 else 0)
    return theta, aq > ai

def phase(i16, q16):
    """Full-circle phase in brads: 0..65535 maps to [0, 2*pi)."""
    if i16 == 0 and q16 == 0:
        return 0
    theta_oct, octant = phase_octant(i16, q16)
    theta1 = 16384 - theta_oct if octant else theta_oct
    si, sq = i16 < 0, q16 < 0
    if si and not sq:
        p = 32768 - theta1
    elif si and sq:
        p = 32768 + theta1
    elif not si and sq:
        p = (65536 - theta1) & 0xffff
    else:
        p = theta1
    return p & 0xffff

def wrap16(d):
    d &= 0xffff
    return d - 65536 if d >= 32768 else d

class HilbertModel:
    """Bit-exact stream model; one output tuple per accepted sample."""
    def __init__(self, pairs=PAIRS):
        if not 1 <= pairs <= 32:
            raise ValueError('pairs')
        self.pairs = pairs
        self.taps = 4 * pairs - 1
        self.center = 2 * pairs - 1
        self.coeffs = list(DEFAULT_COEFFS[:pairs]) if pairs == PAIRS else \
            list(design(pairs)[0])
        self.active = pairs
        self.clear()

    def clear(self):
        self.hist = []
        self.have_prev = False
        self.prev_phase = 0

    def config(self, pairs, coeffs, clear):
        """Atomic config; returns False for illegal requests (no change)."""
        if not 1 <= pairs <= self.pairs:
            return False
        coeffs = list(coeffs)
        if len(coeffs) != self.pairs or \
                any(not -131072 <= c <= 131071 for c in coeffs):
            return False
        self.coeffs = coeffs
        self.active = pairs
        if clear:
            self.clear()
        return True

    def _tap(self, k):
        return self.hist[k] if k < len(self.hist) else 0

    def analytic(self, x):
        """(i16, q16, clip) for one accepted sample."""
        self.hist.insert(0, int(x))
        self.hist = self.hist[:self.taps]
        acc = 0
        for j in range(self.active):
            d = 2 * j + 1
            diff = self._tap(self.center - d) - self._tap(self.center + d)
            acc += self.coeffs[j] * diff
        wide = rne(acc, 15)
        clip = not -32768 <= wide <= 32767
        return self._tap(self.center), sat16(wide), clip

    def sample(self, x):
        i16, q16, clip = self.analytic(x)
        env = envelope(i16, q16)
        zero = i16 == 0 and q16 == 0
        ph = 0 if zero else phase(i16, q16)
        if zero or not self.have_prev:
            fq = 0
        else:
            fq = wrap16(ph - self.prev_phase)
        self.prev_phase = ph
        self.have_prev = True
        return {'i': i16, 'q': q16, 'env': env, 'phase': ph, 'freq': fq,
                'clip': int(clip), 'zero': int(zero)}

# ------------------------------------------------------------ float path
def float_iq(samples, pairs=PAIRS):
    """(I, Q) float lists using the unquantized taps; zero-padded start."""
    _, h = design(pairs)
    center = 2 * pairs - 1
    xs = [float(s) for s in samples]
    q = [math.fsum(h[k] * xs[n - k] for k in range(len(h)) if 0 <= n - k < len(xs))
         for n in range(len(xs))]
    i = [xs[n - center] if n >= center else 0.0 for n in range(len(xs))]
    return i, q

def float_phase_freq(i_list, q_list):
    ph = [math.atan2(q, i) for i, q in zip(i_list, q_list)]
    unwrapped = []
    prev = 0.0
    acc = 0.0
    for n, p in enumerate(ph):
        if n == 0:
            acc = p
        else:
            d = p - ph[n - 1]
            d -= round(d / (2 * math.pi)) * 2 * math.pi
            acc += d
        unwrapped.append(acc)
    fq = [0.0] + [(unwrapped[n] - unwrapped[n - 1]) / (2 * math.pi)
                  for n in range(1, len(ph))]
    env = [math.hypot(i, q) for i, q in zip(i_list, q_list)]
    return env, ph, unwrapped, fq

def response(coeffs, f, pairs=PAIRS):
    """Quantized FIR frequency response H(f), f in cycles/sample."""
    taps = 4 * pairs - 1
    center = 2 * pairs - 1
    h = [0] * taps
    for j in range(len(coeffs)):
        d = 2 * j + 1
        h[center - d] = coeffs[j]
        h[center + d] = -coeffs[j]
    return sum(h[k] / 32768 * cmath.exp(-2j * math.pi * f * k)
               for k in range(taps))

def spectrum_metrics(coeffs, pairs=PAIRS, band=(0.05, 0.45)):
    """Magnitude ripple across the qualified band (dB) and edge rolloff."""
    lo, hi = band
    gains = [abs(response(coeffs, lo + (hi - lo) * i / 512, pairs))
             for i in range(513)]
    ripple = max(abs(20 * math.log10(max(g, 1e-15))) for g in gains)
    edges = {f: 20 * math.log10(max(abs(response(coeffs, f, pairs)), 1e-15))
             for f in (0.01, 0.02, 0.03, 0.04, lo, hi, 0.46, 0.47, 0.48, 0.49)}
    return {'band': list(band), 'passband_max_abs_db': ripple,
            'edge_db': {str(k): v for k, v in edges.items()}}
