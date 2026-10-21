"""Independent algorithm references; no DUT data or RTL imports.

Integers represent signed Q1.15 samples. State has 16 extra fractional bits.
Float functions retain infinite precision; integer functions quantize only at
state feedback and output boundaries using nearest, ties to even.
"""
from dataclasses import dataclass
import math


def rne(n, d):
    if d <= 0:
        raise ValueError('positive divisor required')
    q, r = divmod(abs(n), d)
    q += (2*r > d) or (2*r == d and q % 2 == 1)
    return -q if n < 0 else q


def sat16(x):
    return min(32767, max(-32768, x))


@dataclass(frozen=True)
class Config:
    mode: str = 'blocker'
    pole: int = 65024
    window_log2: int = 4

    def __post_init__(self):
        if self.mode not in ('blocker', 'mean', 'baseline'):
            raise ValueError('unsupported mode')
        if not 0 <= self.pole <= 65535:
            raise ValueError('pole must represent 0 <= r < 1 in UQ0.16')
        if not 0 <= self.window_log2 <= 8:
            raise ValueError('window must be 1..256 power of two')


def float_reference(samples, cfg):
    """Outputs (residual, baseline) in normalized full-scale units.

    Mean has zero prehistory and always divides by the full window length.
    Baseline output uses the newly updated baseline, not its preceding value.
    Blocker baseline is x-y (may exceed input range during transients).
    """
    r = cfg.pole / 65536.0
    nwin = 1 << cfg.window_log2
    history, result = [], []
    previous_x = previous_y = baseline = 0.0
    for value in samples:
        x = value / 32768.0
        if cfg.mode == 'blocker':
            y = x - previous_x + r * previous_y
            previous_x, previous_y = x, y
            b = x - y
        elif cfg.mode == 'baseline':
            baseline = r * baseline + (1-r) * x
            b, y = baseline, x-baseline
        else:
            history.append(x)
            b = math.fsum(history[-nwin:]) / nwin
            y = x-b
        result.append((y, b))
    return result


class FixedReference:
    """Accepted-transaction model; caller drives no step during stalls.

    reset/configure discard algorithm state. A hardware wrapper must separately
    clear valid on reset and wait for outstanding output before config commit.
    """
    def __init__(self, cfg=Config()):
        self.configure(cfg)

    def configure(self, cfg):
        if not isinstance(cfg, Config):
            raise ValueError('atomic Config required')
        self.cfg = cfg
        self.reset()

    def reset(self):
        self.prev_x = self.state = self.total = self.index = 0
        self.ring = [0] * (1 << self.cfg.window_log2)

    def step(self, x):
        if not isinstance(x, int) or not -32768 <= x <= 32767:
            raise ValueError('signed 16-bit input required')
        cfg, scale = self.cfg, 65536
        if cfg.mode == 'blocker':
            self.state = (x-self.prev_x)*scale + rne(cfg.pole*self.state, scale)
            self.prev_x = x
            y = rne(self.state, scale)
            b = rne(x*scale-self.state, scale)
        elif cfg.mode == 'baseline':
            self.state = rne(cfg.pole*self.state + (scale-cfg.pole)*x*scale, scale)
            b = rne(self.state, scale)
            y = rne(x*scale-self.state, scale)
        else:
            self.total += x-self.ring[self.index]
            self.ring[self.index] = x
            self.index = (self.index+1) % len(self.ring)
            b = rne(self.total, len(self.ring))
            y = rne(x*len(self.ring)-self.total, len(self.ring))
        return sat16(y), sat16(b)


def cutoff_hz(pole, fs):
    """-3dB relative to Nyquist gain for DC blocker transfer function."""
    if not 0 <= pole <= 65535 or fs <= 0:
        raise ValueError('invalid pole or sample rate')
    r = pole/65536.0
    return fs*math.acos(2*r/(1+r*r))/(2*math.pi)
