"""Independent references for DSP-07 agc_stream.

- AgcCore: bit-exact sample-domain replica of the RTL algorithm contract
  (energy estimate, level code, gain smoothing, mantissa LUT, saturation).
- CycleModel: cycle-accurate oracle of agc_stream.sv for the RTL testbench;
  mirrors the four-slot globally stalled pipeline, cfg handshake, markers
  and sticky clip flag.
- float_agc: independent floating-point AGC used for behavioural agreement
  bounds only (not bit-exact).

Level code units: 1 code = 1/8 octave ~= 0.7526 dB.  Code 120 == |x| full
scale (0 dBFS).  All integer quantities are exact; pure stdlib.
"""
import math
from dataclasses import dataclass

# mantissa LUT: round(32768 * 2**(f/8)), f=0..7  (dB step per code = 0.7526)
EXP2F = (32768, 35734, 38968, 42495, 46341, 50535, 55109, 60097)

TARGET_MAX = 120            # largest reachable level code
G_LO, G_HI = -256, 255      # gain-code field range (signed9)


def rne(n, d):
    """Round n/d to nearest, ties to even; sign symmetric (floor semantics)."""
    q, r = divmod(n, d)
    q += 2 * r > d or (2 * r == d and q & 1)
    return q


def level_code(e):
    """Octave code of magnitude e in [0,32768]; e==0 -> 0.  Range 0..120."""
    if e < 0 or e > 32768:
        raise ValueError('level magnitude out of range')
    if e == 0:
        return 0
    idx = e.bit_length() - 1
    fr = (e >> (idx - 3)) & 7 if idx >= 3 else (e << (3 - idx)) & 7
    return idx * 8 + fr


def code_to_db(c):
    """Nominal dBFS of a level code: (c-120)*10*log10(2)/8."""
    return (c - 120) * 10.0 * math.log10(2.0) / 8.0


def gain_db(gc):
    """Nominal dB gain of an integer gain code: gc*0.7526 dB."""
    return gc * 10.0 * math.log10(2.0) / 8.0


@dataclass(frozen=True)
class Config:
    target: int = 100        # ~-15 dBFS
    gmin: int = -96          # ~-72 dB
    gmax: int = 32           # ~+24 dB
    attack: int = 3          # gain-decrease TC shift
    release: int = 10        # gain-increase TC shift
    est: int = 6             # energy estimator TC shift
    mode: int = 0            # 0 log smoothing, 1 linear slew
    mute: int = 0
    bypass: int = 0

    def __post_init__(self):
        if not 0 <= self.target <= TARGET_MAX:
            raise ValueError('target must be 0..120')
        if not G_LO <= self.gmin <= G_HI or not G_LO <= self.gmax <= G_HI:
            raise ValueError('gain bounds outside signed9 code range')
        if self.gmin > self.gmax:
            raise ValueError('gmin must be <= gmax')
        for f in (self.attack, self.release, self.est):
            if not 0 <= f <= 15:
                raise ValueError('time-constant shifts are 0..15')
        for f in (self.mode, self.mute, self.bypass):
            if f not in (0, 1):
                raise ValueError('mode/mute/bypass are bits')


DEFAULT_CONFIG = Config()


def legal_fields(target, gmin, gmax, attack, release, est, mode,
                 mute, bypass):
    """Whole-request legality exactly as cfg_bad in RTL."""
    return (gmin <= gmax and target <= TARGET_MAX
            and G_LO <= gmin and G_LO <= gmax and gmin <= G_HI
            and gmax <= G_HI and 0 <= target
            and all(0 <= x <= 15 for x in (attack, release, est))
            and mode in (0, 1) and mute in (0, 1) and bypass in (0, 1))


class AgcCore:
    """Bit-exact sample-domain core: one call per accepted sample."""

    def __init__(self, cfg=DEFAULT_CONFIG):
        self.cfg = cfg
        self.env = 0          # Q23.8 mean |x|
        self.gq = 0           # gain code, 4 fraction bits

    def reset_state(self):
        self.env = 0
        self.gq = 0

    def env_step(self, x):
        ax = abs(x)           # |x| in [0,32768]
        diff = (ax << 8) - self.env
        step = max(1, abs(diff) >> self.cfg.est)
        if diff > 0:
            self.env += step
        elif diff < 0:
            self.env -= step
        return self.env

    def gain_step(self):
        """Update gq from committed env; returns (mantissa, shift, code)."""
        lvl = level_code(self.env >> 8)
        gdes = self.cfg.target - lvl
        gdes = min(max(gdes, self.cfg.gmin), self.cfg.gmax)
        diff = (gdes << 4) - self.gq
        rate = self.cfg.attack if diff < 0 else self.cfg.release
        if self.cfg.mode:                      # linear constant slew
            step = min(abs(diff), 32768 >> rate)
        else:                                  # log: exponential + creep
            step = max(1, abs(diff) >> rate)
        if diff > 0:
            self.gq += step
        elif diff < 0:
            self.gq -= step
        gc = (self.gq + 8) >> 4                # round half up (floor)
        sh = gc >> 3                           # floor
        f = gc & 7                             # floor-mod 8
        return EXP2F[f], sh, gc

    @staticmethod
    def apply(x, mant, sh):
        """y = sat16(RNE(RNE(x*mant/2^15) << sh)).  Returns (y, clip)."""
        scaled = rne(x * mant, 32768)
        yv = scaled << sh if sh >= 0 else rne(scaled, 1 << (-sh))
        clip = yv > 32767 or yv < -32768
        return min(32767, max(-32768, yv)), int(clip)

    def step(self, x):
        """Full per-sample contract; returns (y, clip, env_code, gain_code)."""
        if not isinstance(x, int) or not -32768 <= x <= 32767:
            raise ValueError('signed16 input required')
        self.env_step(x)
        mant, sh, gc = self.gain_step()
        y, clip = self.apply(x, mant, sh)
        if self.cfg.bypass:
            y, clip = x, 0
        elif self.cfg.mute:
            y = 0
        return y, clip, level_code(self.env >> 8), gc


def float_agc(samples, cfg):
    """Independent floating-point AGC for behavioural agreement bounds only.

    Same contract parameters as the bit-exact core, expressed in continuous
    log domain: envelope follower alpha = 2^-est on mean |x|, gain error
    smoothed in continuous code units (0.7526 dB each) with alpha = 2^-rate
    (log mode) or a constant code slew (linear mode).  Not bit-exact.
    """
    env = 0.0
    g = 0.0                                  # continuous gain code
    ea = 2.0 ** -cfg.est
    aa = 2.0 ** -cfg.attack
    ra = 2.0 ** -cfg.release
    slew_a = (32768 >> cfg.attack) / 16.0    # codes per sample, linear mode
    slew_r = (32768 >> cfg.release) / 16.0
    out = []
    for x in samples:
        env += (abs(x) - env) * ea
        lvl = 8.0 * math.log2(max(env, 1.0))  # continuous level code
        gdes = min(max(cfg.target - lvl, cfg.gmin), cfg.gmax)
        d = gdes - g
        if cfg.mode:
            s = slew_a if d < 0 else slew_r
            g += min(abs(d), s) * (1 if d > 0 else -1)
        else:
            g += d * (aa if d < 0 else ra)
        lin = 2.0 ** (g / 8.0)
        y = 0.0 if cfg.mute else (x if cfg.bypass else x * lin)
        out.append(min(32767.0, max(-32768.0, y)))
    return out


# ---------------------------------------------------------------------------
# cycle-accurate oracle
# ---------------------------------------------------------------------------

class CycleModel:
    """Cycle-exact oracle of agc_stream.  tick() is called once per clock
    with the same inputs the TB drives; expected() returns the values the TB
    must observe this cycle (pre-edge), matching the RTL wiring."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.cfg = DEFAULT_CONFIG
        self.v = [None] * 4        # slot payloads (x,u,l) / (x,u,l,mant,sh)
        self.out = None            # (y,u,l) at slot3 == m regs
        self.env = 0
        self.gq = 0
        self.clip_sticky = 0
        self.cfg_done = 0
        self.cfg_error = 0

    # ---- static helpers -------------------------------------------------
    def _lvl(self, env):
        return level_code(env >> 8)

    def _env_next(self, x):
        diff = (abs(x) << 8) - self.env
        step = max(1, abs(diff) >> self.cfg.est)
        return (self.env + step if diff > 0
                else self.env - step if diff < 0 else self.env)

    def _gain_next(self):
        lvl = self._lvl(self.env)
        gdes = self.cfg.target - lvl
        gdes = min(max(gdes, self.cfg.gmin), self.cfg.gmax)
        diff = (gdes << 4) - self.gq
        rate = self.cfg.attack if diff < 0 else self.cfg.release
        if self.cfg.mode:
            step = min(abs(diff), 32768 >> rate)
        else:
            step = max(1, abs(diff) >> rate)
        gq = self.gq + (-step if diff < 0 else (step if diff > 0 else 0))
        gc = (gq + 8) >> 4
        return gq, EXP2F[gc & 7], gc >> 3

    def _apply(self, x, mant, sh):
        scaled = rne(x * mant, 32768)
        yv = scaled << sh if sh >= 0 else rne(scaled, 1 << (-sh))
        clip = int(yv > 32767 or yv < -32768)
        y = min(32767, max(-32768, yv))
        if self.cfg.bypass:
            return x, 0
        if self.cfg.mute:
            return 0, clip
        return y, clip

    # ---- expected outputs for the current cycle (pre-edge) --------------
    def expected(self, rst, cfg_valid):
        return dict(
            s_tready=int(bool(rst) and (self.v[3] is None or self._mr)
                       and not cfg_valid),
            cfg_ready=int(bool(rst) and all(p is None for p in self.v)),
            m_tvalid=int(self.v[3] is not None),
            m_tdata=0 if self.v[3] is None else self.v[3][0],
            m_tuser=0 if self.v[3] is None else self.v[3][1],
            m_tlast=0 if self.v[3] is None else self.v[3][2],
            env_code=self._lvl(self.env),
            gain_code=(self.gq + 8) >> 4,
            clip_sticky=self.clip_sticky,
            cfg_done=self.cfg_done,
            cfg_error=self.cfg_error)

    # ---- advance one clock ----------------------------------------------
    def tick(self, rst=1, cfg=None, sv=0, x=0, su=0, sl=0, mr=1):
        """cfg: None or dict of fields.  Returns (accepted_cfg, cfg_error)."""
        self._mr = mr
        cv = int(cfg is not None)
        f = dict(target=100, gmin=-96, gmax=32, attack=3, release=10,
                 est=6, mode=0, mute=0, bypass=0, clear=0)
        if cfg:
            f.update(cfg)
        exp = self.expected(rst, cv)
        rows_exp = exp
        sr = exp['s_tready']
        cr = exp['cfg_ready']
        self.cfg_done = 0
        self.cfg_error = 0
        if not rst:
            self.reset()
            return rows_exp
        accept = sv and sr
        advance = self.v[3] is None or mr
        if cv and cr:
            self.cfg_done = 1
            if not legal_fields(f['target'], f['gmin'], f['gmax'],
                                f['attack'], f['release'], f['est'],
                                f['mode'], f['mute'], f['bypass']):
                self.cfg_error = 1
            else:
                self.cfg = Config(f['target'], f['gmin'], f['gmax'],
                                  f['attack'], f['release'], f['est'],
                                  f['mode'], f['mute'], f['bypass'])
                self.clip_sticky = 0
                if f['clear']:
                    self.env = 0
                    self.gq = 0
                else:
                    self.gq = min(max(self.gq, f['gmin'] << 4),
                                  f['gmax'] << 4)
        if advance:
            s0, s1, s2 = self.v[0], self.v[1], self.v[2]
            # slot0 -> slot1 edge: energy update uses committed env
            env_new = self._env_next(s0[0]) if s0 is not None else self.env
            # slot1 -> slot2 edge: gain from env (already has s1's update)
            if s1 is not None:
                gq_new, mant, sh = self._gain_next()
            # slot2 -> slot3 edge: apply
            out = None
            if s2 is not None:
                y, cl = self._apply(s2[0], s2[3], s2[4])
                out = (y, s2[1], s2[2])
                if cl and not self.cfg.bypass:
                    self.clip_sticky = 1
            self.env = env_new
            if s1 is not None:
                self.gq = gq_new
                s1 = (s1[0], s1[1], s1[2], mant, sh)
            self.v = [(x, su, sl) if accept else None,
                      s0 and (s0[0], s0[1], s0[2]), s1, out]
        self.out = self.v[3]
        return rows_exp
