#!/usr/bin/env python3
# ============================================================================
# Independent golden model for cores/signal_processing/transforms (T1: no sim back-fill).
# Models, bit-exact, the RTL arithmetic of:
#   U0 fft64     - 64-pt radix-2 DIT FFT, Q1.15, /2 per stage, exact 16x16
#                  shift-add twiddle multiply, wrapping 16-bit butterflies.
#   U1 cic_dec8  - CIC decimator N=3 R=8 M=1, 17-bit wrapping datapath.
#   U2 hist256   - 256-bin histogram, 16-bit counts, 24-bit total.
#   U3 otsu_thresh - Otsu argmax over score = (num^2 >> 32) // den, sat 32.
# Emits (project root / sim):
#   fft64_cos.mem, fft64_sin.mem   - Q1.15 twiddle ROMs (cos[0]=32767, sat)
#   otsu_hist.mem                  - 512x16 test histograms (2 vectors)
#   sim/expected_report_{f,3,c}.mem- UART golden byte streams per UNIT_EN mask
# Prints the EXP_* digests to embed in src/sig_selftest.v.
# ============================================================================
import math
import os

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fnv(h, b):
    """FNV-1a 32-bit via the RTL shift-add form x*0x01000193."""
    x = (h ^ (b & 0xFF)) & 0xFFFFFFFF
    return (x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24)) & 0xFFFFFFFF


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def s8(v):
    v &= 0xFF
    return v - 0x100 if v >= 0x80 else v


def s17(v):
    v &= 0x1FFFF
    return v - 0x20000 if v >= 0x10000 else v


def bitrev6(n):
    return int('{:06b}'.format(n)[::-1], 2)


# ---------------------------------------------------------------------------
# Twiddle tables W64^k = cos(2 pi k / 64) - j sin(2 pi k / 64), k=0..31, Q1.15.
# cos(0)=sin(16)=1.0 are unrepresentable -> saturated to 32767 (documented;
# golden and RTL share the same table so behaviour is still bit-exact).
# ---------------------------------------------------------------------------
COS = [min(32767, int(round(math.cos(2.0 * math.pi * k / 64.0) * 32768.0)))
       for k in range(32)]
SIN = [min(32767, int(round(math.sin(2.0 * math.pi * k / 64.0) * 32768.0)))
       for k in range(32)]


def cos64(i):
    """cos(2 pi i / 64) in Q1.15 for i in 0..63 via the 32-entry table."""
    i &= 63
    return COS[i] if i < 32 else -COS[i - 32]


# ---------------------------------------------------------------------------
# U0 FFT model (mirrors src/fft64.v exactly)
# ---------------------------------------------------------------------------
def fft64(xre, xim):
    """In-place radix-2 DIT FFT, identical integer sequence to RTL."""
    re = [0] * 64
    im = [0] * 64
    for n in range(64):
        re[bitrev6(n)] = s16(xre[n])
        im[bitrev6(n)] = s16(xim[n])
    for stage in range(1, 7):
        half = 1 << (stage - 1)
        for bf in range(32):
            i = ((bf >> (stage - 1)) << stage) | (bf & (half - 1))
            j = i + half
            tw = (bf & (half - 1)) << (6 - stage)
            c, s = COS[tw], SIN[tw]
            bre, bim = re[j], im[j]
            ure, uim = re[i], im[i]
            tre = (bre * c + bim * s + 0x4000) >> 15
            tim = (bim * c - bre * s + 0x4000) >> 15
            re[i] = s16((ure + tre) >> 1)
            im[i] = s16((uim + tim) >> 1)
            re[j] = s16((ure - tre) >> 1)
            im[j] = s16((uim - tim) >> 1)
    return re, im


# Stimulus vectors (real input, im = 0), matching stim_fft() in sig_selftest.v
def fft_stim(v):
    x = []
    for n in range(64):
        if v == 0:      # impulse x[0]=0.5
            x.append(16384 if n == 0 else 0)
        elif v == 1:    # constant 0.125
            x.append(4096)
        elif v == 2:    # single tone k=4, amplitude 0.25
            x.append(cos64((4 * n) & 63) >> 2)
        else:           # alternating +/-0.25 (tone k=32)
            x.append(-8192 if (n & 1) else 8192)
    return x


def fft_digest():
    h = 0x811C9DC5
    detail = []
    for v in range(4):
        re, im = fft64(fft_stim(v), [0] * 64)
        mags = []
        for k in range(64):
            m = (re[k] * re[k] + im[k] * im[k]) & 0xFFFFFFFF
            mags.append(m)
            for b in range(4):
                h = fnv(h, (m >> (8 * b)) & 0xFF)
        detail.append(mags)
    return h, detail


# ---------------------------------------------------------------------------
# U1 CIC model: din_i = i*5 + (i>>3)*7 - 100 (mod 256, signed)
# ---------------------------------------------------------------------------
def cic_stim():
    return [s8(i * 5 + (i >> 3) * 7 - 100) for i in range(128)]


def cic_model(samples):
    i1 = i2 = i3 = c1d = c2d = c3d = 0
    cnt = 0
    out = []
    for x in samples:
        i1 = s17(i1 + x)
        i2 = s17(i2 + i1)
        i3 = s17(i3 + i2)
        if cnt == 7:
            c1 = s17(i3 - c1d); c1d = i3
            c2 = s17(c1 - c2d); c2d = c1
            c3 = s17(c2 - c3d); c3d = c2
            out.append(c3)
            cnt = 0
        else:
            cnt += 1
    return out


def cic_digest():
    h = 0x811C9DC5
    outs = cic_model(cic_stim())
    for d in outs:
        u = d & 0x1FFFF
        h = fnv(h, u & 0xFF)
        h = fnv(h, (u >> 8) & 0xFF)
        h = fnv(h, (u >> 16) & 0xFF)
    return h, outs


# ---------------------------------------------------------------------------
# U2 HIST model
#   phase A: 512 samples, bin = i>>1 (each bin twice, back-to-back)
#   readout A: 256 bins (fold lo,hi), then total (3 bytes)
#   phase B: 96 samples, bin = (3i)&0xFF (accumulate on existing counts)
#   readout B + total again
# ---------------------------------------------------------------------------
def hist_digest():
    h = 0x811C9DC5
    hist = [0] * 256
    total = 0
    for i in range(512):
        hist[(i >> 1) & 0xFF] += 1
        total += 1
    for a in range(256):
        h = fnv(h, hist[a] & 0xFF)
        h = fnv(h, (hist[a] >> 8) & 0xFF)
    for b in range(3):
        h = fnv(h, (total >> (8 * b)) & 0xFF)
    for i in range(96):
        hist[(i + (i << 1)) & 0xFF] += 1
        total += 1
    for a in range(256):
        h = fnv(h, hist[a] & 0xFF)
        h = fnv(h, (hist[a] >> 8) & 0xFF)
    for b in range(3):
        h = fnv(h, (total >> (8 * b)) & 0xFF)
    return h, hist


# ---------------------------------------------------------------------------
# U3 Otsu model (mirrors src/otsu_thresh.v integer datapath exactly)
#   score(t) = ((num^2) >> 32) // den, saturated to 32 bits; den==0 or num==0
#   -> score 0.  argmax = first strictly-greater score.
# ---------------------------------------------------------------------------
OTSU_HISTS = []


def build_otsu_hists():
    v0 = []
    for i in range(256):
        g1 = int(round(600.0 * math.exp(-((i - 60) / 14.0) ** 2)))
        g2 = int(round(900.0 * math.exp(-((i - 185) / 18.0) ** 2)))
        v0.append(max(0, g1) + max(0, g2) + 2)
    v1 = []
    for i in range(256):
        base = (i * 5 + (i >> 3) * 11 + 7) & 0x3FF
        v1.append(base + (400 if 140 <= i < 170 else 0))
    return [v0, v1]


def otsu_model(hist):
    N = sum(hist)
    sumT = sum(i * h for i, h in enumerate(hist))
    w0 = 0
    s0 = 0
    best = -1
    thr = 0
    for t in range(256):
        w0 += hist[t]
        s0 += t * hist[t]
        w1 = N - w0
        den = w0 * w1
        num = abs(s0 * N - sumT * w0)
        if den == 0 or num == 0:
            score = 0
        else:
            score = (num * num) >> 32
            score //= den
            if score > 0xFFFFFFFF:
                score = 0xFFFFFFFF
        if score > best:
            best = score
            thr = t
    return thr, best & 0xFFFFFFFF


def otsu_digest():
    h = 0x811C9DC5
    res = []
    for hist in OTSU_HISTS:
        thr, score = otsu_model(hist)
        res.append((thr, score))
        h = fnv(h, thr & 0xFF)
        for b in range(4):
            h = fnv(h, (score >> (8 * b)) & 0xFF)
    return h, res


# ---------------------------------------------------------------------------
# UART expected-report generation (mirrors report_char in src/top.v)
# ---------------------------------------------------------------------------
def report_bytes(mask, digests):
    """digests: dict unit->32-bit digest (actual, i.e. seed for masked-off).
    Header assumes the successful case (all done, all pass)."""
    done = 0xF
    ps = 0xF
    names = ["FFT ", "CIC ", "HST ", "OTSU"]
    out = []
    hdr = "SIG4 M=%X P=%X" % (done, ps)
    hdr = hdr.ljust(30) + "\r\n"
    out.extend(hdr.encode('ascii'))
    for u in range(4):
        en = (mask >> u) & 1
        status = 'S' if not en else 'P'
        line = "U%d %s %s D=%08X" % (u, names[u], status, digests[u])
        line = line.ljust(30) + "\r\n"
        out.extend(line.encode('ascii'))
    assert len(out) == 160
    return out


def write_mem(path, values, width):
    with open(path, 'w') as f:
        for v in values:
            f.write(('%0*x' % (width, v & ((1 << (width * 4)) - 1))) + '\n')


def main():
    global OTSU_HISTS
    OTSU_HISTS = build_otsu_hists()

    # mem files at project root ($readmemh relative path contract)
    write_mem(os.path.join(PROJ, 'fft64_cos.mem'), COS, 4)
    write_mem(os.path.join(PROJ, 'fft64_sin.mem'), SIN, 4)
    flat = OTSU_HISTS[0] + OTSU_HISTS[1]
    write_mem(os.path.join(PROJ, 'otsu_hist.mem'), flat, 4)

    exp_fft, fft_mags = fft_digest()
    exp_cic, cic_outs = cic_digest()
    exp_hist, hist_bins = hist_digest()
    exp_otsu, otsu_res = otsu_digest()

    digests = {0: exp_fft, 1: exp_cic, 2: exp_hist, 3: exp_otsu}
    for mask, tag in ((0xF, 'f'), (0x3, '3'), (0xC, 'c')):
        d = {u: (digests[u] if (mask >> u) & 1 else 0x811C9DC5)
             for u in range(4)}
        rb = report_bytes(mask, d)
        write_mem(os.path.join(PROJ, 'sim', 'expected_report_%s.mem' % tag),
                  rb, 2)

    print("EXP_FFT  = 32'h%08x;" % exp_fft)
    print("EXP_CIC  = 32'h%08x;" % exp_cic)
    print("EXP_HIST = 32'h%08x;" % exp_hist)
    print("EXP_OTSU = 32'h%08x;" % exp_otsu)
    print()
    print("fft outputs (re,im) per vector:")
    for v in range(4):
        re, im = fft64(fft_stim(v), [0] * 64)
        nz = [(k, re[k], im[k]) for k in range(64)
              if re[k] != 0 or im[k] != 0]
        print("  vec%d nonzero bins: %s" % (v, nz[:12]))
    print("cic outputs:", cic_outs)
    print("otsu (thr,score):", otsu_res)
    h, hb = hist_digest()
    nz = {i: c for i, c in enumerate(hb) if c}
    print("hist nonzero bins (post phase B):", nz)


if __name__ == '__main__':
    main()
