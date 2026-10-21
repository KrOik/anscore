"""Independent references for DSP-15 adaptive LMS/NLMS (lms_stream).

Pure standard library. Integers are the wire values; no DUT imports.

Numeric contract (identical for both RTL implementation variants):
  data    x,d : signed 16-bit Q1.15, integer range [-32768, 32767]
  coef    c   : signed 24-bit Q4.20, range [-8, 8)
  step    mu  : unsigned UQ0.16 integer 0..65535  (mu_real = mu/65536)
  energy  e2  : sum of squares of the active tap vector (raw integer squares)

Per accepted sample (x[n], d[n]):
  hist = [x[n], x[n-1], ..., x[n-taps+1]]      (zero prehistory)
  acc  = sum_k c[k]*x[n-k]                     (exact integer, wide)
  y    = sat16( rne(acc / 2^20) )              (acc holds Q(5).35 worth of bits)
  e    = sat16( d - y )
  t2   = sat18( rne(mu*e / 2^15) )             (mu*e in Q1.31 -> t2 Q1.16 units)
  LMS  : g = t2,            delta[k] = rne(g*x[n-k] / 2^11)
  NLMS : E_den = min(e2 >> 16, 2^20-1)         (e2/2^30 = real energy)
         floor_eff = max(cfg_floor, 1)
         bypass  = E_den < floor_eff           (energy floor: update skipped)
         g = sat20( RNE(t2 * 2^8 / E_den) )    when not bypassed else 0
         delta[k] = rne(g*x[n-k] / 2^5)
  update: c[k] <- sat24(c[k] + delta[k]) for k < taps

  update is committed VIS samples later (delayed-LMS visibility):
    serial MAC core: VIS=1 (update visible to the next accepted sample)
    parallel core  : VIS=NL+31, NL=ceil(log2(NTAPS)) (pipeline depth to the
                     commit edge; the cycle-accurate RTL oracle in
                     tests/test_lms.py is authoritative for non-dense input)
  update_en=0 forces every delta to zero.  NLMS bypass forces delta zero and
  raises tuser[1].  RNE is round-half-to-even on the magnitude (symmetric for
  negatives, identical to infra/fixedpoint).

Stability note (float bound): LMS needs 0 < mu < 2/(taps*Px) with Px the mean
input power; NLMS is normalized by the tap energy so 0 < mu < 2 is the classic
bound.  The integer model quantizes mu to UQ0.16 so mu_real < 1 always.
"""
from dataclasses import dataclass

# ---------------------------------------------------------------- helpers
def rne(v, s):
    """Round v / 2**s to nearest integer, ties to even. Correct for v < 0."""
    if s <= 0:
        return v
    q, r = divmod(v, 1 << s)          # floor division: r in [0, 2**s)
    h = 1 << (s - 1)
    if r > h or (r == h and q & 1):
        q += 1
    return q


def sat(v, w):
    """Saturate to signed w bits -> (value, clipped)."""
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    return (min(hi, max(lo, v)), int(not lo <= v <= hi))


def fpdiv_q(a, b, fb=8, out_w=20):
    """Bit-exact replica of infra/fixedpoint fp_div_*:
    q = sat_outw(RNE(a * 2**fb / b)) for signed a,b.
    b == 0 -> a<0 ? MIN : MAX, flags (div0=1, clip=1)."""
    lo, hi = -(1 << (out_w - 1)), (1 << (out_w - 1)) - 1
    if b == 0:
        return (lo if a < 0 else hi), (1, 1)
    ua, ub = abs(a), abs(b)
    q, r = divmod(ua << fb, ub)
    if 2 * r > ub or (2 * r == ub and q & 1):
        q += 1
    if (a < 0) != (b < 0):
        q = -q
    out, clip = sat(q, out_w)
    return out, (0, clip)


def ceil_log2(n):
    l = 0
    while (1 << l) < n:
        l += 1
    return l


# ---------------------------------------------------------------- config
@dataclass(frozen=True)
class Config:
    """Runtime configuration fields of lms_stream."""
    taps: int = 8            # active taps, 1..ntaps
    mu: int = 8192           # UQ0.16 step size (8192 -> 0.125)
    nlms: int = 0            # 0=LMS, 1=NLMS
    update_en: int = 1       # 0 freezes coefficients
    floor: int = 64          # NLMS energy floor in E_den units (E_den>=floor or bypass)
    ntaps_max: int = 8       # structural parameter, part of legality check

    def check(self):
        """Returns None if legal, else an error string (mirrors cfg_error)."""
        if not isinstance(self.taps, int) or self.taps < 1 or self.taps > self.ntaps_max:
            return 'cfg_taps must be in 1..NTAPS'
        if not 0 <= self.mu <= 0xFFFF:
            return 'cfg_mu must be UQ0.16'
        if self.nlms not in (0, 1):
            return 'cfg_nlms must be 0/1'
        if self.update_en not in (0, 1):
            return 'cfg_update_en must be 0/1'
        if not 0 <= self.floor <= 0xFFFFF:
            return 'cfg_floor must be 20-bit'
        return None


# ------------------------------------------------- fixed-point model
class FixedLMS:
    """Per-sample bit-exact model.  Step n computes y/e from the coefficient
    state *after* all commits whose commit index <= n, and schedules its own
    coefficient deltas at commit index n+vis.

    vis=1 reproduces the serial core (update committed before the next
    sample).  vis=NL+31 reproduces the parallel core for dense (II=1) input;
    the cycle oracle in the testbench models the exact pipeline when input has
    bubbles, so this class assumes an accept-dense stream for vis>1.
    """
    CW, CF = 24, 20                      # coefficient Q4.20

    def __init__(self, ntaps=8, vis=1):
        self.ntaps = ntaps
        self.vis = vis
        self.reset()

    def reset(self, coefs=None):
        self.coef = list(coefs) if coefs is not None else [0] * self.ntaps
        assert len(self.coef) == self.ntaps
        self.hist = [0] * self.ntaps     # x[n-k] for k>=0; prehistory zero
        self.pending = []                # list of [commit_index, deltas]
        self.n = 0
        self.commit_log = {}             # commit_index -> clip flag (commit edge)

    def _commit_due(self):
        """Apply all pending updates with commit_index <= self.n."""
        keep = []
        for idx, deltas in self.pending:
            if idx <= self.n:
                clip = 0
                for k, dv in enumerate(deltas):
                    nv, cl = sat(self.coef[k] + dv, self.CW)
                    self.coef[k] = nv
                    clip |= cl
                self.commit_log[idx] = clip
            else:
                keep.append([idx, deltas])
        self.pending = keep

    def load_coef(self, k, v):
        nv, _ = sat(v, self.CW)
        self.coef[k] = nv                # cw_data is already 24-bit; saturate defensively

    def step(self, x, d, cfg: Config):
        """One accepted sample.  Returns dict(y, e, clip, bypass, g)."""
        assert -32768 <= x <= 32767 and -32768 <= d <= 32767
        self._commit_due()
        # shift history (accept-shifted): hist[k] = x[n-k]
        self.hist = [x] + self.hist[:-1]
        taps = cfg.taps
        acc = 0
        for k in range(taps):
            acc += self.coef[k] * self.hist[k]
        y, clipy = sat(rne(acc, self.CF), 16)
        e, clipe = sat(d - y, 16)
        t2, clipt = sat(rne(cfg.mu * e, 15), 18)
        clip = clipy | clipe | clipt
        # energy of the active window (raw x^2 units)
        e2 = sum(h * h for h in self.hist[:taps])
        eden = min(e2 >> 16, (1 << 20) - 1)
        bypass = 0
        g = t2
        if cfg.nlms:
            floor_eff = max(cfg.floor, 1)
            if eden < floor_eff:
                bypass, g = 1, 0
            else:
                g, (d0, clg) = fpdiv_q(t2, eden, fb=8, out_w=20)
                clip |= clg | d0
                if not cfg.update_en:
                    g = 0
        else:
            if not cfg.update_en:
                g = 0
        sh = 5 if cfg.nlms else 11
        deltas = [rne(g * self.hist[k], sh) if k < taps else 0
                  for k in range(self.ntaps)]
        self.pending.append([self.n + self.vis, deltas])
        out = {'y': y, 'e': e, 'clip': clip, 'bypass': bypass,
               'g': g, 'eden': eden, 't2': t2}
        self.n += 1
        return out

    def drain(self, count):
        """Advance sample index without new inputs (commits still land)."""
        for _ in range(count):
            self.n += 1
            self._commit_due()

    def read_coef(self, k):
        return self.coef[k]


# ------------------------------------------------- float reference
def float_lms(xs, ds, ntaps, mu, nlms=0, floor=0.0, vis=1, update_en=1,
              coefs=None):
    """Floating-point LMS/NLMS with the same delayed-update visibility.

    mu, floor are real-valued.  floor compares against real tap-vector energy
    (sum of squared floats).  Returns (outputs, coefs): outputs is a list of
    (y, e) per sample.
    """
    c = list(coefs) if coefs is not None else [0.0] * ntaps
    hist = [0.0] * ntaps
    pending = []
    out = []
    for n, (x, d) in enumerate(zip(xs, ds)):
        for idx, deltas in [p for p in pending if p[0] <= n]:
            for k, dv in enumerate(deltas):
                c[k] += dv
        pending = [p for p in pending if p[0] > n]
        hist = [x] + hist[:-1]
        y = sum(c[k] * hist[k] for k in range(ntaps))
        e = d - y
        g = mu * e
        if nlms:
            e2 = sum(h * h for h in hist[:ntaps])
            if e2 < max(floor, 1e-30):
                g = 0.0
            else:
                g = mu * e / e2
        if not update_en:
            g = 0.0
        pending.append([n + vis, [g * hist[k] for k in range(ntaps)]])
        out.append((y, e))
    return out, c
