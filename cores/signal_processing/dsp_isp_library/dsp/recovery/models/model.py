"""Independent references for DSP-08 carrier & timing recovery.

- CarrierFloat / TimingFloat: floating-point algorithm models used to
  derive loop gains and acquisition bounds (algorithm evidence, NOT
  bit-exact).
- CarrierCycle / TimingCycle: bit-exact cycle-accurate replicas of
  rtl/carrier_loop.sv and rtl/timing_loop.sv (pipeline, saturation,
  modular phase, cfg handshake, lock detector) used to generate the
  iverilog fixture vectors.
- gen_bpsk_iq / gen_bpsk_real: test-signal generators (BPSK with carrier
  offset / timing offset / rate offset), quantized to signed16.

Reference configuration (SPEC.md): BPSK, complex baseband I/Q for the
carrier loop, real baseband for the timing loop; SPS in {4,8}; Fs = SPS *
Fsym.  Pure stdlib.
"""
import math, random
from dataclasses import dataclass

# ----------------------------------------------------------------------------
# sine LUT shared with rtl/nco.sv
# ----------------------------------------------------------------------------
QLUT = [round(2047 * math.sin(2 * math.pi * i / 256)) for i in range(64)]


def sine8(a):
    """a in 0..255 -> Q1.11 sine, identical to rtl/nco.sv sine8()."""
    q, i = a >> 6, a & 63
    m = QLUT[i] if q in (0, 2) else QLUT[63 - i]
    return -m if q >= 2 else m


def sincos(phase):
    """phase u32 -> (cos, sin) Q1.11 exactly as nco.sv."""
    a = (phase >> 24) & 0xFF
    return sine8((a + 64) & 0xFF), sine8(a)


# ----------------------------------------------------------------------------
# fixed-point helpers (mirror Verilog exactly)
# ----------------------------------------------------------------------------
def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v >= 0x80000000 else v


def u32(v):
    return v & 0xFFFFFFFF


def sat18(v):
    return 131071 if v > 131071 else (-131072 if v < -131072 else v)


def sat16(v):
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)


def wrap18(v):
    v &= 0x3FFFF
    return v - 0x40000 if v >= 0x20000 else v


def abs18(v):
    """|e18| as in RTL: unary minus wraps mod 2^18."""
    return (-v) & 0x3FFFF if v < 0 else v


def sat32(v):
    return 2147483647 if v > 2147483647 else (-2147483648 if v < -2147483648 else v)


IMAX = 268435455   # 2^28 - 1


def clamp(v, lim):
    return lim if v > lim else (-lim if v < -lim else v)


# ----------------------------------------------------------------------------
# signal generators (quantize to signed16)
# ----------------------------------------------------------------------------
def q16(x):
    return sat16(int(round(x)))


def gen_bpsk_iq(nsym, sps, df, A=0.7, tau=0.0, ppm=0.0, noise=0.0,
                seed=1, shape=(0.25, 0.5, 0.25), n0=0):
    """Complex baseband BPSK with carrier offset df (cycles/sample).

    a[k] in {+1,-1} NRZ symbols, optional mild pulse shaping FIR `shape`,
    carrier x[n] = A * bb[n] * exp(j*2*pi*df*n'), n'=(n-n0)*(1+ppm) - tau*sps.
    Returns (I[], Q[], bits[]) quantized to signed16.
    """
    rng = random.Random(seed)
    bits = [1 if rng.random() < 0.5 else -1 for _ in range(nsym)]
    nrz = [bits[min(nsym - 1, i // sps)] for i in range(nsym * sps)]
    n = len(nrz)
    bb = [sum(shape[j] * (nrz[i + 1 - j] if 0 <= i + 1 - j < n else nrz[0])
              for j in range(len(shape))) for i in range(n)]
    I, Q = [], []
    for i, b in enumerate(bb):
        t = (i - n0) * (1.0 + ppm) - tau * sps
        ph = 2 * math.pi * df * t
        ii = A * 32768 * b * math.cos(ph)
        qq = A * 32768 * b * math.sin(ph)
        if noise:
            ii += rng.gauss(0, noise)
            qq += rng.gauss(0, noise)
        I.append(q16(ii))
        Q.append(q16(qq))
    return I, Q, bits


def gen_bpsk_real(nsym, sps, tau, A=0.7, ppm=0.0, noise=0.0, seed=1,
                  shape=(0.25, 0.5, 0.25)):
    """Real baseband BPSK with timing offset tau (symbol units) and relative
    sample-rate offset ppm.  Sample i observes symbol time
    t = i*(1+ppm)/sps - tau ... implemented by placing samples on a
    stretched grid: the symbol index of sample i is floor(t).
    Returns (y[], bits[], sym_of_sample[]) quantized to signed16."""
    rng = random.Random(seed)
    bits = [1 if rng.random() < 0.5 else -1 for _ in range(nsym)]
    n = int(nsym * sps / (1.0 + ppm)) + 2
    # piecewise-linear-ish NRZ shaped by `shape` on the *symbol domain*
    sym = []          # symbol index observed by sample i (pre-offset)
    nrz = []
    for i in range(n):
        t = i / sps * (1.0 + ppm) + tau
        k = int(math.floor(t))
        k = max(0, min(nsym - 1, k))
        sym.append(k)
        nrz.append(bits[k])
    # shape over sample domain (approximates bandlimited edges)
    sm = [sum(shape[j] * (nrz[i + 1 - j] if 0 <= i + 1 - j < n else nrz[0])
              for j in range(len(shape))) for i in range(n)]
    y = [q16(A * 32768 * b + (rng.gauss(0, noise) if noise else 0.0))
         for b in sm]
    return y, bits, sym


# ----------------------------------------------------------------------------
# floating-point loop models (algorithm evidence)
# ----------------------------------------------------------------------------
def carrier_float(I, Q, kp, ki, fcw=0.0):
    """Float Costas-style BPSK loop; fcw/inc in cycles/sample.
    Returns dict of traces: Qr, Ir, e, integ, lock-ish residual."""
    ph = 0.0
    integ = 0.0
    tr = {'Ir': [], 'Qr': [], 'e': [], 'integ': [], 'ph': []}
    for i, q in zip(I, Q):
        c = math.cos(2 * math.pi * ph)
        s = math.sin(2 * math.pi * ph)
        ir = i * c + q * s
        qr = q * c - i * s
        e = qr if ir >= 0 else -qr
        ph += fcw + kp * e + integ
        integ += ki * e
        tr['Ir'].append(ir); tr['Qr'].append(qr); tr['e'].append(e)
        tr['integ'].append(integ); tr['ph'].append(ph)
    return tr


def timing_float(y, sps, kp, ki, corr_sat=0.25):
    """Float Gardner loop; acc in symbol units, corr clamp +-corr_sat*step0.
    Returns picks list [(sample_idx, value)] and trace dict."""
    acc = 0.0
    integ = 0.0
    prop = 0.0
    sprev = 0.0
    m = 0.0
    have = False
    step0 = 1.0 / sps
    picks = []
    es = []
    for n, x in enumerate(y):
        corr = clamp(prop + integ, corr_sat * step0)
        nxt = acc + step0 + corr
        half = acc < 0.5 <= nxt and nxt < 1.0
        if half:
            m = x
            have = True
        if nxt >= 1.0:
            picks.append((n, x))
            d = x - sprev
            e = (m if d > 0 else (-m if d < 0 else 0.0)) if have else 0.0
            sprev = x
            have = False
            prop = kp * e
            integ += ki * e
            es.append(e)
            nxt -= 1.0
        acc = nxt
    return picks, es, integ


# ----------------------------------------------------------------------------
# bit-exact cycle models
# ----------------------------------------------------------------------------
@dataclass
class CarrierCfg:
    fcw: int = 0
    kp: int = 4
    ki: int = 8
    lthr: int = 2500
    ln: int = 64
    clear: int = 0

    def bad(self):
        return (self.ki <= self.kp or
                self.fcw > 1073741824 or self.fcw < -1073741824 or
                self.lthr < 8 or self.ln < 4)


class Pi:
    """pi_loop.sv replica."""
    def __init__(self):
        self.prop = 0
        self.integ = 0

    def tick(self, upd, clear, err32, kp, ki):
        if clear:
            self.prop = 0
            self.integ = 0
        elif upd:
            self.prop = err32 >> kp
            s = self.integ + (err32 >> ki)
            # exact RTL bounds: [-2^28, 2^28-1]
            self.integ = min(IMAX, max(-268435456, s))

    @property
    def corr(self):
        return s32(self.prop + self.integ)


class LockDet:
    """lock_det.sv replica; lavg arms at max on reset/clear."""
    def __init__(self):
        self.lavg = 0xFFFFFF
        self.cnt = 0
        self.lock = 0

    @property
    def level(self):
        return self.lavg >> 6

    def tick(self, en, clear, mag, thr, nreq):
        if clear:
            self.lavg = 0xFFFFFF
            self.cnt = 0
            self.lock = 0
        elif en:
            lvl = self.level          # RTL compares the PRE-update value
            diff = (mag << 6) - self.lavg
            self.lavg = (self.lavg + (diff >> 6)) & 0xFFFFFF
            if lvl < thr:
                self.lock = 1 if (self.cnt + 1) >= nreq else 0
                self.cnt = min(255, self.cnt + 1)
            else:
                self.cnt = 0
                self.lock = 0


class CarrierCycle:
    """Cycle-exact replica of carrier_loop.sv."""
    def __init__(self):
        self.av = 0
        self.ia = 0
        self.qa = 0
        self.ca = 2046
        self.sa = 0
        self.m_tvalid = 0
        self.m_tdata = 0
        self.freq_est = 0
        self.phase = 0
        self.pi = Pi()
        self.lk = LockDet()
        self.fcw = 0
        self.kp = 4
        self.ki = 8
        self.lthr = 2500
        self.ln = 64
        self.cfg_pend = 0
        self.cfg_err = 0
        self.clr = 0
        self.cfg_done = 0
        self.cfg_error = 0
        self.q = dict(fcw=0, kp=0, ki=0, lthr=0, ln=0, clear=0)

    # combinational helpers --------------------------------------------------
    def comb(self):
        c, s = sincos(self.phase)
        isum = self.ia * self.ca + self.qa * self.sa
        qsum = self.qa * self.ca - self.ia * self.sa
        ir18 = sat18(isum >> 11)
        qr18 = sat18(qsum >> 11)
        e18 = wrap18(-qr18) if ir18 < 0 else qr18
        err32 = s32(e18 << 13)
        emag = abs18(e18)
        corr = self.pi.corr
        inc = sat32(self.fcw + corr)
        return dict(c=c, s=s, ir=ir18, qr=qr18, e=e18, err32=err32,
                    emag=emag, corr=corr, inc=inc)

    def tick(self, rst=1, sv=0, sd=0, mr=1, cfg=None):
        """Advance one edge; returns dict of outputs valid during the cycle
        *before* the edge (combinational outputs from pre-edge state)."""
        cb = self.comb()
        adv = 1 if (not self.m_tvalid or mr) else 0
        accept = sv and adv
        upd = self.av and adv
        out = dict(s_tready=adv if rst else 0, m_tvalid=self.m_tvalid,
                   m_tdata=self.m_tdata & 0xFFFFFFFF,
                   lock=self.lk.lock, level=self.lk.level,
                   freq_est=self.freq_est & 0xFFFFFFFF,
                   phase=self.phase,
                   cfg_ready=(1 - self.cfg_pend) if rst else 0,
                   cfg_done=self.cfg_done, cfg_error=self.cfg_error)
        if not rst:
            self.__init__()
            return out
        # config handshake
        self.cfg_done = 0
        self.cfg_error = 0
        clr_next = 0
        if self.cfg_pend:
            self.cfg_pend = 0
            self.cfg_done = 1
            self.cfg_error = self.cfg_err
            if not self.cfg_err:
                self.fcw = s32(self.q['fcw'])
                self.kp = self.q['kp']
                self.ki = self.q['ki']
                self.lthr = self.q['lthr']
                self.ln = self.q['ln']
                if self.q['clear']:
                    clr_next = 1
        elif cfg is not None:
            self.cfg_pend = 1
            self.cfg_err = 1 if cfg.bad() else 0
            self.q = dict(fcw=cfg.fcw, kp=cfg.kp, ki=cfg.ki,
                          lthr=cfg.lthr, ln=cfg.ln, clear=cfg.clear)
        # pipeline / datapath
        if adv:
            av_old = self.av            # RTL nonblocking: old av decides
            self.av = 1 if accept else 0
            if accept:
                self.ia = s16(sd & 0xFFFF)
                self.qa = s16((sd >> 16) & 0xFFFF)
                self.ca = cb['c']
                self.sa = cb['s']
            if av_old:
                self.m_tvalid = 1
                self.m_tdata = ((sat16(cb['qr']) & 0xFFFF) << 16) | \
                               (sat16(cb['ir']) & 0xFFFF)
                self.freq_est = cb['inc']
            else:
                self.m_tvalid = 0
        # loop state (clear priority, then update strobe)
        self.pi.tick(upd, self.clr, cb['err32'], self.kp, self.ki)
        self.lk.tick(upd, self.clr, cb['emag'], self.lthr, self.ln)
        if upd:
            self.phase = u32(self.phase + cb['inc'])
        self.clr = clr_next
        return out


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


@dataclass
class TimingCfg:
    sps: int = 0          # code: 0 -> SPS=4, 1 -> SPS=8 (2,3 illegal)
    kp: int = 19
    ki: int = 22
    lthr: int = 10000
    ln: int = 64
    clear: int = 0

    def bad(self):
        return (self.sps > 1 or self.ki <= self.kp or
                self.lthr < 8 or self.ln < 4)


class TimingCycle:
    """Cycle-exact replica of timing_loop.sv."""
    def __init__(self):
        self.acc = 0
        self.s_prev = 0
        self.m_s = 0
        self.have_mid = 0
        self.pick = 0
        self.pick_data = 0
        self.pick_bit = 0
        self.rate_est = 0
        self.sps8 = 0
        self.kp = 19
        self.ki = 22
        self.lthr = 10000
        self.ln = 64
        self.cfg_pend = 0
        self.cfg_err = 0
        self.clr = 0
        self.cfg_done = 0
        self.cfg_error = 0
        self.pi = Pi()
        self.lk = LockDet()
        self.q = dict(sps=0, kp=0, ki=0, lthr=0, ln=0, clear=0)

    def comb(self):
        step0 = 8192 if self.sps8 else 16384
        clim = step0 >> 2
        corr_c = clamp(self.pi.corr, clim)
        step = (step0 + (corr_c & 0x3FFFF)) & 0x3FFFF
        nxt = self.acc + (step & 0x1FFFF)
        nxt &= 0x1FFFF
        wrap = 1 if nxt >= 0x10000 else 0
        half = 1 if (self.acc < 0x8000 and (nxt & 0x8000)) else 0
        return dict(step0=step0, clim=clim, corr_c=corr_c, step=step,
                    nxt=nxt, wrap=wrap, half=half)

    def tick(self, rst=1, sv=0, sd=0, cfg=None):
        cb = self.comb()
        accept = sv and rst          # s_tready = rst_n
        x = s16(sd)
        # TED error for this edge (comb, applied only when accept && wrap)
        diff = x - self.s_prev
        e17 = self.m_s if diff > 0 else (-self.m_s if diff < 0 else 0)
        e17 = e17 if self.have_mid else 0
        err32 = s32(e17 << 13)
        emag = abs18(e17)
        upd = 1 if (accept and cb['wrap']) else 0
        out = dict(s_tready=1 if rst else 0, pick=self.pick,
                   pick_data=self.pick_data & 0xFFFF,
                   pick_bit=self.pick_bit, lock=self.lk.lock,
                   level=self.lk.level, rate_est=self.rate_est & 0xFFFFFFFF,
                   phase=self.acc,
                   cfg_ready=(1 - self.cfg_pend) if rst else 0,
                   cfg_done=self.cfg_done, cfg_error=self.cfg_error)
        if not rst:
            self.__init__()
            return out
        # config handshake
        self.cfg_done = 0
        self.cfg_error = 0
        clr_next = 0
        if self.cfg_pend:
            self.cfg_pend = 0
            self.cfg_done = 1
            self.cfg_error = self.cfg_err
            if not self.cfg_err:
                self.sps8 = self.q['sps']
                self.kp = self.q['kp']
                self.ki = self.q['ki']
                self.lthr = self.q['lthr']
                self.ln = self.q['ln']
                if self.q['clear']:
                    clr_next = 1
        elif cfg is not None:
            self.cfg_pend = 1
            self.cfg_err = 1 if cfg.bad() else 0
            self.q = dict(sps=cfg.sps, kp=cfg.kp, ki=cfg.ki,
                          lthr=cfg.lthr, ln=cfg.ln, clear=cfg.clear)
        # loop state
        if self.clr:
            self.acc = 0
            self.s_prev = 0
            self.m_s = 0
            self.have_mid = 0
            self.pick = 0
        elif accept:
            self.acc = cb['nxt'] & 0xFFFF
            if cb['half']:
                self.m_s = x
                self.have_mid = 1
            if cb['wrap']:
                self.pick = 1
                self.pick_data = x
                self.pick_bit = 1 if x >= 0 else 0
                self.s_prev = x
                self.rate_est = cb['corr_c']
                self.have_mid = 0
            else:
                self.pick = 0
        else:
            self.pick = 0
        # sub-loops
        self.pi.tick(upd, self.clr, err32, self.kp, self.ki)
        self.lk.tick(upd, self.clr, emag, self.lthr, self.ln)
        self.clr = clr_next
        return out


# ----------------------------------------------------------------------------
# float-vs-fixed agreement self check (used by tests)
# ----------------------------------------------------------------------------
def self_check():
    """Float carrier loop must agree with the fixed model within the LUT /
    quantization envelope on a mid-range acquisition."""
    I, Q, _ = gen_bpsk_iq(300, 4, 1 / 64, A=0.7, seed=7)
    tr = carrier_float([i / 32768 for i in I], [q / 32768 for q in Q],
                       kp=1 / 256, ki=1 / 4096)
    qr_tail = sum(abs(v) for v in tr['Qr'][-200:]) / 200
    ok = qr_tail < 0.05 and abs(tr['integ'][-1] - 1 / 64) < 0.002
    return ok, qr_tail, tr['integ'][-1]


if __name__ == '__main__':
    ok, res, integ = self_check()
    print('self_check', ok, 'residual|Qr|=%.4f' % res, 'integ=%.6f' % integ)
