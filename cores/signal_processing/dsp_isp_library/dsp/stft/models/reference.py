"""DSP-14 STFT/Welch power spectrum: float and bit-exact references.

Chain contract (see SPEC.md):
  signed16 Q1.15 samples -> frames of N=64, hop H in {8,16,32,64}
  -> window_mult (signed16 Q1.15 out, signed18 Q3.15 coefficients, wshift)
  -> fft64 (bit-exact sigproc golden model; output ~= DFT/64 in Q1.15)
  -> mag_squared (unsigned32 power, RNE right shift pshift)
  -> averager (block A=2**avg or exponential alpha=avg, 42-bit state)
  -> records of K bins (K=33 one-sided, 64 two-sided).

The bit-exact path reuses the accepted DSP-05 model and the sigproc
fft64 golden model read-only; there is no independent re-derivation.
"""
import importlib.util
import math
from pathlib import Path

_HERE = Path(__file__).resolve()


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# DSP-05 spectrum model and sigproc fft64 golden, read-only reuse.  Loaded by
# path because this module itself is also named ``reference``.
SR = _load('dsp05_spectrum_reference',
           _HERE.parents[2] / 'spectrum' / 'models' / 'reference.py')
GM = _load('sigproc_golden_model',
           _HERE.parents[4] / 'sigproc_20k' / 'tools' / 'golden_model.py')

N = 64
LOG2N = 6
HOPS = (8, 16, 32, 64)
ACC_W = 42
EXP_GUARD = 8


class Config:
    __slots__ = ('window', 'hop_sel', 'twosided', 'avgmode', 'avg',
                 'wshift', 'pshift')

    def __init__(self, window=0, hop_sel=3, twosided=0, avgmode=0, avg=0,
                 wshift=0, pshift=0):
        self.window = window
        self.hop_sel = hop_sel
        self.twosided = twosided
        self.avgmode = avgmode
        self.avg = avg
        self.wshift = wshift
        self.pshift = pshift

    def __eq__(self, o):
        return all(getattr(self, f) == getattr(o, f) for f in self.__slots__)

    def __repr__(self):
        return ('Config(w=%d hop=%d two=%d amode=%d avg=%d wsh=%d psh=%d)'
                % (self.window, self.hop_sel, self.twosided, self.avgmode,
                   self.avg, self.wshift, self.pshift))


def valid_cfg(window, hop_sel, twosided, avgmode, avg, wshift, pshift):
    if not (0 <= window <= 4 and 0 <= hop_sel <= 3 and twosided in (0, 1)
            and avgmode in (0, 1) and -8 <= wshift <= 15
            and 0 <= pshift <= 15):
        return False
    if avgmode == 0:
        return 0 <= avg <= 8
    return 1 <= avg <= 8


def hop(cfg):
    return 8 << cfg.hop_sel


def emit_bins(cfg):
    return 64 if cfg.twosided else 33


def frames_of(samples, cfg):
    """Complete frames: frame f = xs[f*H .. f*H+63]."""
    h = hop(cfg)
    return [samples[f * h:f * h + N]
            for f in range(max(0, (len(samples) - N) // h + 1))]


# --- bit-exact chain ---------------------------------------------------

def window_frame(frame, cfg, table=None):
    """Windowed frame, signed16 list, exactly window_mult behaviour."""
    return [SR.window_sample(x, i, LOG2N, cfg.window, cfg.wshift, table)[0]
            for i, x in enumerate(frame)]


def power_frame(frame, cfg, table=None):
    """64 integer power bins for one raw frame (pre-averaging)."""
    xw = window_frame(frame, cfg, table)
    re, im = GM.fft64(xw, [0] * N)
    return [SR.mag_squared(re[k], im[k], cfg.pshift)[0] for k in range(N)]


def sat_u32(v):
    return min(max(v, 0), 0xFFFFFFFF)


class Averager:
    """Bit-exact per-bin 42-bit average state; update(powers)->record|None."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.acc = [0] * N
        self.blk = 0

    def reset(self):
        self.acc = [0] * N
        self.blk = 0

    def update(self, powers):
        cfg = self.cfg
        k = emit_bins(cfg)
        if cfg.avgmode == 0:
            a = 1 << cfg.avg
            self.acc = [s + p for s, p in zip(self.acc, powers)]
            if self.blk == a - 1:
                out = [sat_u32(SR.rne(self.acc[i], a)) for i in range(k)]
                self.acc = [0] * N
                self.blk = 0
                return out
            self.blk += 1
            return None
        alpha = cfg.avg
        self.acc = [s + (((p << EXP_GUARD) - s) >> alpha)
                    for s, p in zip(self.acc, powers)]
        return [sat_u32(SR.rne(self.acc[i], 1 << EXP_GUARD))
                for i in range(k)]


def records(samples, cfg, table=None):
    """All emitted records (list of K-int lists) for a sample stream."""
    avg = Averager(cfg)
    out = []
    for fr in frames_of(samples, cfg):
        r = avg.update(power_frame(fr, cfg, table))
        if r is not None:
            out.append(r)
    return out


def window_table(cfg):
    """Quantized signed18 Q3.15 table matching the internal window path."""
    return SR.gen_window_table(LOG2N, cfg.window)


def window_power_sum(window, table=None):
    """U_q = sum(w_q^2) of the exact internal signed18 Q3.15 coefficients."""
    t = table if table is not None else SR.gen_window_table(LOG2N, window)
    return sum(c * c for c in t)


def coherent_gain(window, table=None):
    t = table if table is not None else SR.gen_window_table(LOG2N, window)
    return SR.coherent_gain(t)


# --- float reference ----------------------------------------------------

def float_fft(x):
    """Iterative radix-2 DFT, natural order, len(x) power of two."""
    n = len(x)
    a = [complex(v) for v in x]
    j = 0
    for i in range(1, n):
        b = n >> 1
        while j & b:
            j ^= b
            b >>= 1
        j |= b
        if i < j:
            a[i], a[j] = a[j], a[i]
    m = 2
    while m <= n:
        wm = complex(math.cos(-2 * math.pi / m), math.sin(-2 * math.pi / m))
        for s in range(0, n, m):
            w = 1 + 0j
            for k in range(m // 2):
                t = w * a[s + k + m // 2]
                u = a[s + k]
                a[s + k] = u + t
                a[s + k + m // 2] = u - t
                w *= wm
        m <<= 1
    return a


def float_window_coeffs(window):
    return [SR.float_window(n, N, window) for n in range(N)]


def float_frame_power(frame, cfg):
    """|DFT(xw)[k]|^2 in real units (unquantized, no /64 scaling)."""
    w = float_window_coeffs(cfg.window)
    spec = float_fft([x / 32768.0 * w[n] for n, x in enumerate(frame)])
    return [abs(v) ** 2 for v in spec]


def float_average(frames_power, cfg):
    """Float averaging of |DFT|^2 lists (block mean / EMA with alpha)."""
    if not frames_power:
        return []
    k = emit_bins(cfg)
    if cfg.avgmode == 0:
        a = 1 << cfg.avg
        return [[sum(fr[i] for fr in frames_power[b * a:(b + 1) * a]) / a
                 for i in range(k)]
                for b in range(len(frames_power) // a)]
    alpha = cfg.avg
    s = [0.0] * N
    out = []
    for p in frames_power:
        s = [si + (pi - si) / (1 << alpha) for si, pi in zip(s, p)]
        out.append(s[:k])
    return out


def int_power_to_dft2(p_out, cfg):
    """Convert averaged integer output to |DFT(xw)|^2 real units."""
    return p_out * (1 << cfg.pshift) / float(1 << 18)


def psd_physical(p_out, cfg, u_q, fs, k):
    """Physical one/two-sided PSD from an integer output value.

    p_out: integer bin value (post pshift). u_q: window_power_sum()."""
    v = int_power_to_dft2(p_out, cfg) * (1 << 30) / (fs * u_q)
    if not cfg.twosided and 0 < k < N // 2:
        v *= 2.0
    return v
