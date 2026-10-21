"""Independent correlation/matched-filter references for DSP-06.

Four independently expressed computations:
- float_correlate: floating-point sliding dot product, algorithm correctness
  reference. No quantization is involved; the datapath itself is exact
  integer arithmetic.
- fft_convolve: radix-2 FFT linear convolution used only by the model test
  as an independent algorithm cross-check (never by the RTL oracle).
- frame_results: bit-exact functional replica of the RTL per-frame output
  contract (per-position values, markers and the argmax summary).
- StreamModel: cycle-accurate oracle of correlation_stream.sv for the RTL
  testbench.

Pure stdlib. Samples and template taps are (re, im) integer pairs, signed DW;
correlation accumulators are exact signed ACCW integers, never rounded or
saturated (documented bound |re|,|im| <= 2*ntaps*2^(2*DW-2) < 2^(2*DW+8)).
The argmax proxy is |re|+|im|, earliest position wins ties.
"""
import math, cmath
from dataclasses import dataclass

DW, MAX_TAPS, ACCW, POSW = 16, 64, 48, 16
SMIN, SMAX = -(1 << (DW - 1)), (1 << (DW - 1)) - 1
AMIN, AMAX = -(1 << (ACCW - 1)), (1 << (ACCW - 1)) - 1
POS_MAX = (1 << POSW) - 1

@dataclass(frozen=True)
class Config:
    """ntaps: 1..MAX_TAPS. cplx: complex datapath. dir: 0=correlation order
    (w[k]=tap[ntaps-1-k]), 1=convolution order (w[k]=tap[k]). conj: conjugate
    the effective taps, legal only when cplx. tail: 0=VALID (positions
    ntaps-1..N-1; frame needs N>=ntaps), 1=FULL (positions 0..N+ntaps-2,
    zero-padded partials). taps: MAX_TAPS (re,im) pairs; slots >= ntaps are
    ignored."""
    ntaps: int = 1
    cplx: bool = False
    dir: bool = False
    conj: bool = False
    tail: int = 0
    taps: tuple = ((32767, 0),) + ((0, 0),) * (MAX_TAPS - 1)
    def __post_init__(self):
        if not 1 <= self.ntaps <= MAX_TAPS:
            raise ValueError('ntaps must be 1..%d' % MAX_TAPS)
        if self.tail not in (0, 1):
            raise ValueError('tail must be 0 (VALID) or 1 (FULL)')
        if self.conj and not self.cplx:
            raise ValueError('conj requires complex mode')
        if len(self.taps) != MAX_TAPS:
            raise ValueError('taps must carry %d (re,im) pairs' % MAX_TAPS)
        for re, im in self.taps[:self.ntaps]:
            if not SMIN <= re <= SMAX or not SMIN <= im <= SMAX:
                raise ValueError('tap component outside signed%d' % DW)

def effective_taps(cfg):
    """w[k] applied to the history sample k positions back, k=0..ntaps-1."""
    out = []
    for k in range(cfg.ntaps):
        re, im = cfg.taps[k if cfg.dir else cfg.ntaps - 1 - k]
        if cfg.conj:
            im = -im
        if not cfg.cplx:
            im = 0  # imaginary template part is unused in real mode
        out.append((re, im))
    return out

def frame_positions(n, cfg):
    """Emitted lag indices for a frame of n samples."""
    if cfg.tail == 1:
        return range(0, n + cfg.ntaps - 1)
    return range(cfg.ntaps - 1, n) if n >= cfg.ntaps else range(0)

def frame_results(xs, cfg):
    """Bit-exact per-frame contract. xs: list of (re,im) int pairs (im is
    ignored/zero in real mode). Returns (outputs, peak):
    outputs: [{'pos','re','im','user','last'}] in emission order;
    peak: {'pos','re','im','mag','error'}."""
    n = len(xs)
    w = effective_taps(cfg)
    outs = []
    for pos in frame_positions(n, cfg):
        re = im = 0
        for k in range(cfg.ntaps):
            i = pos - k
            if 0 <= i < n:
                xr, xi = xs[i]
                if not cfg.cplx:
                    xi = 0  # s_tdata[2*DW-1:DW] is ignored in real mode
                wr, wi = w[k]
                re += xr * wr - xi * wi
                im += xr * wi + xi * wr
        assert AMIN <= re <= AMAX and AMIN <= im <= AMAX
        outs.append({'pos': pos, 're': re, 'im': im})
    for i, o in enumerate(outs):
        o['user'] = int(i == 0)
        o['last'] = int(i == len(outs) - 1)
    if outs:
        best = outs[0]; bmag = abs(best['re']) + abs(best['im'])
        for o in outs[1:]:
            mg = abs(o['re']) + abs(o['im'])
            if mg > bmag:
                bmag = mg; best = o
        peak = {'pos': best['pos'], 're': best['re'], 'im': best['im'],
                'mag': bmag, 'error': 0}
    else:
        peak = {'pos': POS_MAX, 're': 0, 'im': 0, 'mag': 0, 'error': 1}
    return outs, peak

def float_correlate(xs, cfg):
    """Floating-point reference over complex values. Returns
    {pos: complex} for every emitted position."""
    w = [complex(re, im) for re, im in effective_taps(cfg)]
    out = {}
    for pos in frame_positions(len(xs), cfg):
        acc = 0j
        for k in range(cfg.ntaps):
            i = pos - k
            if 0 <= i < len(xs):
                acc += xs[i] * w[k]
        out[pos] = acc
    return out

# ---- independent FFT convolution for model cross-checking ------------------
def fft(a):
    n = len(a)
    if n == 1:
        return list(a)
    ev = fft(a[0::2]); od = fft(a[1::2])
    out = [0j] * n
    for k in range(n // 2):
        t = cmath.exp(-2j * math.pi * k / n) * od[k]
        out[k] = ev[k] + t
        out[k + n // 2] = ev[k] - t
    return out

def ifft(a):
    n = len(a)
    return [x.conjugate() / n for x in fft([x.conjugate() for x in a])]

def fft_convolve(x, h):
    """Linear convolution via FFT, an independent algorithm path."""
    n = len(x) + len(h) - 1
    L = 1
    while L < n:
        L <<= 1
    X = fft(list(x) + [0j] * (L - len(x)))
    H = fft(list(h) + [0j] * (L - len(h)))
    return ifft([a * b for a, b in zip(X, H)])[:n]

def acc_bound(cfg):
    """Documented |re|,|im| bound: each of ntaps steps adds <=2^(2*DW-1)."""
    return cfg.ntaps * (1 << (2 * DW - 1))

def pack_taps(taps):
    """Packing of cfg_taps: tap k at bits [32k +: 32] = {im[15:0], re[15:0]}."""
    v = 0
    for i, (re, im) in enumerate(taps):
        v |= (((im & 0xFFFF) << 16) | (re & 0xFFFF)) << (32 * i)
    return v

def pack_sample(re, im):
    return ((im & 0xFFFF) << 16) | (re & 0xFFFF)

def pack_acc(re, im):
    return ((im & ((1 << ACCW) - 1)) << ACCW) | (re & ((1 << ACCW) - 1))

# ---- cycle-accurate oracle --------------------------------------------------
IDLE, MAC, EMIT, PK = 0, 1, 2, 3

class StreamModel:
    """Cycle-accurate replica of correlation_stream. Drive once per clock
    with the same inputs the TB applies; outputs() exposes the values the TB
    compares during the current cycle before edge() advances state."""
    def __init__(self):
        self.reset()
    def reset(self):
        self.state = IDLE
        self.ntaps = 1; self.cplx = 0; self.dir = 0; self.conj = 0; self.tail = 0
        self.hist_re = [0] * MAX_TAPS; self.hist_im = [0] * MAX_TAPS
        self.tap_re = [0] * MAX_TAPS; self.tap_im = [0] * MAX_TAPS
        self.tap_re[0] = SMAX
        self.acc_re = 0; self.acc_im = 0; self.j = 0
        self.idx = 0; self.flen = 0; self.n_out = 0
        self.in_frame = 0; self.frame_done = 0; self.group_started = 0
        self.tail_cnt = 0
        self.b_pos = 0; self.b_re = 0; self.b_im = 0; self.b_mag = 0
        self.b_valid = 0
        self.m_re = 0; self.m_im = 0; self.m_pos = 0
        self.m_tuser = 0; self.m_tlast = 0; self.m_valid = 0
        self.p_pos = 0; self.p_re = 0; self.p_im = 0; self.p_mag = 0
        self.p_error = 0; self.p_valid = 0
        self.cfg_done = 0; self.cfg_error = 0; self.marker_error = 0
    def outputs(self, rst_n, cfg_valid):
        idle = self.state == IDLE
        return {
            's_tready': int(bool(rst_n) and idle and
                            not (cfg_valid and not self.in_frame)),
            'cfg_ready': int(bool(rst_n) and idle and not self.in_frame),
            'cfg_done': self.cfg_done, 'cfg_error': self.cfg_error,
            'marker_error': self.marker_error,
            'm_valid': self.m_valid, 'm_re': self.m_re, 'm_im': self.m_im,
            'm_pos': self.m_pos, 'm_tuser': self.m_tuser, 'm_tlast': self.m_tlast,
            'p_valid': self.p_valid, 'p_pos': self.p_pos,
            'p_re': self.p_re, 'p_im': self.p_im, 'p_mag': self.p_mag,
            'p_error': self.p_error}
    def edge(self, rst_n, cfg_valid, cfg_ntaps, cfg_mode, cfg_tail, cfg_taps,
             s_valid, s_re, s_im, s_user, s_last, m_ready, p_ready):
        """Advance one clock. cfg_taps is the raw request list of MAX_TAPS
        (re,im) pairs; s_re/s_im are the raw sample components."""
        outs = self.outputs(rst_n, cfg_valid)
        if not rst_n:
            self.reset(); return
        self.cfg_done = 0; self.cfg_error = 0
        bad = bool(cfg_ntaps < 1 or cfg_ntaps > MAX_TAPS or cfg_tail > 1 or
                   (cfg_mode & 8) or ((cfg_mode & 4) and not (cfg_mode & 1)))
        if cfg_valid and outs['cfg_ready']:
            self.cfg_done = 1; self.cfg_error = int(bad)
            if not bad:
                self.ntaps = cfg_ntaps; self.cplx = cfg_mode & 1
                self.dir = (cfg_mode >> 1) & 1; self.conj = (cfg_mode >> 2) & 1
                self.tail = cfg_tail
                for t in range(MAX_TAPS):
                    self.tap_re[t], self.tap_im[t] = cfg_taps[t]
            return
        st = self.state
        if st == IDLE:
            accept = s_valid and outs['s_tready']
            if accept:
                starting = s_user or not self.in_frame
                if ((s_user and self.in_frame) or
                        (not s_user and not self.in_frame) or
                        (not starting and self.idx == POS_MAX)):
                    self.marker_error = 1
                idx_next = 0 if starting else self.idx + 1
                self.flen = 1 if starting else min(self.flen + 1, POS_MAX)
                self.idx = idx_next
                self.in_frame = int(not s_last); self.frame_done = s_last
                self.tail_cnt = 0
                for t in range(MAX_TAPS - 1, 0, -1):
                    self.hist_re[t] = 0 if starting else self.hist_re[t - 1]
                    self.hist_im[t] = (0 if starting or not self.cplx
                                       else self.hist_im[t - 1])
                self.hist_re[0] = s_re
                self.hist_im[0] = s_im if self.cplx else 0
                self.acc_re = 0; self.acc_im = 0; self.j = 0
                if starting:
                    self.group_started = 0; self.b_valid = 0
                    self.b_pos = 0; self.b_re = 0; self.b_im = 0; self.b_mag = 0
                emit = self.tail or idx_next + 1 >= self.ntaps
                if emit:
                    self.n_out = idx_next; self.state = MAC
                elif s_last:
                    self.p_pos = POS_MAX; self.p_re = 0; self.p_im = 0
                    self.p_mag = 0; self.p_error = 1; self.p_valid = 1
                    self.state = PK
        elif st == MAC:
            k = self.j >> 1 if self.cplx else self.j
            tk = k if self.dir else self.ntaps - 1 - k
            ph = self.cplx and (self.j & 1)
            d_re = d_im = 0
            if self.cplx:
                p0 = self.hist_re[k] * (self.tap_im[tk] if ph else self.tap_re[tk])
                p1 = self.hist_im[k] * (self.tap_re[tk] if ph else self.tap_im[tk])
                if ph:
                    d_im = p1 - p0 if self.conj else p0 + p1
                else:
                    d_re = p0 + p1 if self.conj else p0 - p1
            else:
                d_re = self.hist_re[k] * self.tap_re[tk]
            self.acc_re += d_re; self.acc_im += d_im
            if self.j == (2 * self.ntaps if self.cplx else self.ntaps) - 1:
                self.m_re = self.acc_re; self.m_im = self.acc_im
                self.m_pos = self.n_out
                self.m_tuser = int(not self.group_started)
                if self.tail_cnt == 0:
                    self.m_tlast = int(self.frame_done and
                                       (not self.tail or self.ntaps == 1))
                else:
                    self.m_tlast = int(self.frame_done and
                                       self.tail_cnt == self.ntaps - 1)
                self.m_valid = 1
                self.group_started = 1
                mag = abs(self.acc_re) + abs(self.acc_im)
                if not self.b_valid or mag > self.b_mag:
                    self.b_valid = 1; self.b_pos = self.n_out
                    self.b_re = self.acc_re; self.b_im = self.acc_im
                    self.b_mag = mag
                self.state = EMIT
            else:
                self.j += 1
        elif st == EMIT:
            if m_ready:
                self.m_valid = 0
                if self.frame_done and self.tail and self.tail_cnt < self.ntaps - 1:
                    for t in range(MAX_TAPS - 1, 0, -1):
                        self.hist_re[t] = self.hist_re[t - 1]
                        self.hist_im[t] = self.hist_im[t - 1]
                    self.hist_re[0] = 0; self.hist_im[0] = 0
                    if self.n_out == POS_MAX:
                        self.marker_error = 1
                    self.tail_cnt += 1; self.n_out = (self.n_out + 1) & POS_MAX
                    self.acc_re = 0; self.acc_im = 0; self.j = 0
                    self.state = MAC
                elif self.frame_done:
                    self.p_pos = self.b_pos; self.p_re = self.b_re
                    self.p_im = self.b_im; self.p_mag = self.b_mag
                    self.p_error = 0; self.p_valid = 1; self.state = PK
                else:
                    self.state = IDLE
        elif st == PK:
            if p_ready:
                self.p_valid = 0; self.p_error = 0; self.state = IDLE
                self.in_frame = 0; self.frame_done = 0; self.group_started = 0
                self.tail_cnt = 0; self.idx = 0; self.flen = 0; self.b_valid = 0
