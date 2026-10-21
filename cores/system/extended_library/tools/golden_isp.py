#!/usr/bin/env python3
# ============================================================================
# golden_isp.py -- independent golden model for wave2 group A (ISP) units.
#
# Pure-Python functional model (no RTL output harvested; trap T1 compliance).
# Replicates the w2_img_stim pixel formula bit-exactly -- INCLUDING the fact
# that `pix` is a registered (correct) pixel while `pix24` is COMBINATIONAL
# on the x/y/fidx counters, which have already advanced during each
# pix_valid beat.  Hence the pix24 byte stream equals the raster sequence
# ROTATED LEFT BY ONE PIXEL: beat i of a frame carries pixel i+1, and the
# last beat of frame f carries pixel (0,0) of frame f+1 (of the same frame
# for the last frame).  RGB units below consume pix24_seq(); DPC/DEM consume
# the true `pix` raster (win3x3_gen taps follow `pix`).
#
# Units (TAG):
#   DPC  isp_dpc      : 3x3, |c - med8| > THR -> med8 else c
#   DEM  isp_demosaic : Bayer RGGB -> RGB888 bilinear
#   AWB  isp_awb      : gray-world AWB, gains from frame0 applied to frame1
#   GAM  isp_gamma    : 256-entry gamma LUT applied per channel
#   CSC  isp_csc      : RGB<->YCbCr fixed point (frame0 fwd, frame1 inv)
#   GRY  isp_rgb2gray : Y = (77R + 150G + 29B) >> 8
#
# Usage:
#   python tools/golden_isp.py
#     -> prints "<TAG> DIGEST=XXXXXXXX" lines (the ONLY source of EXP_*)
#     -> writes sim/golden_isp_<unit>.txt (one hex byte per line, fold order)
#     -> writes sim/gamma_lut.mem  (readmemh image loaded by st_isp_gamma)
# ============================================================================
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W = 32
H = 32
NP = W * H
DPC_THR = 32          # isp_dpc THR parameter
FNV_SEED = 0x811C9DC5


# ---------------------------------------------------------------------------
# w2_img_stim replica (src/w2_img_stim.v header formula, verbatim)
# ---------------------------------------------------------------------------
def stim_pix(x, y, fidx):
    base = ((x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^ ((x & y) << 3)) & 0xFF
    sx0 = 6 + 2 * fidx
    sy0 = 5 + fidx
    if sx0 <= x <= sx0 + 3 and sy0 <= y <= sy0 + 5:
        base = (base + 0x50) & 0xFF
    return base


def frame(fidx):
    return [[stim_pix(x, y, fidx) for x in range(W)] for y in range(H)]


def pix24(p):
    """w2_img_stim pseudo-colour mapping: r=p, g=p^0x5A, b=p+0x3C (mod 256)."""
    return (p, p ^ 0x5A, (p + 0x3C) & 0xFF)


def pix24_seq(nf):
    """(src_fidx, r, g, b) per pix_valid beat across nf frames, with the
    one-pixel lead of the combinational pix24/fidx bus (see header): beat i
    of a frame carries pixel i+1, and the last beat of frame f carries pixel
    (0,0) of frame f+1 (of frame f itself for the last frame) -- and fidx
    has already advanced, so mode-selects keyed on fidx follow src_fidx."""
    frames = [frame(f) for f in range(nf)]
    seq = []
    for f in range(nf):
        flat = [frames[f][y][x] for y in range(H) for x in range(W)]
        for i in range(NP):
            if i < NP - 1:
                seq.append((f,) + pix24(flat[i + 1]))
            else:
                sf = f + 1 if f < nf - 1 else f
                seq.append((sf,) + pix24(frames[sf][0][0]))
    return seq   # len = nf*NP; segment f = beats [f*NP, (f+1)*NP)


def clamp(v, hi):
    return 0 if v < 0 else (hi if v > hi else v)


def window(img, y, x):
    """9 taps, i = r*3+c row-major, edge replication (win3x3_gen/w2_win_rd)."""
    return [img[clamp(y + r - 1, H - 1)][clamp(x + c - 1, W - 1)]
            for r in range(3) for c in range(3)]


def fnv(h, b):
    h ^= b & 0xFF
    return (h * 0x01000193) & 0xFFFFFFFF


def fold(h, seq):
    for b in seq:
        h = fnv(h, b)
    return h


def write_stream(name, stream):
    path = os.path.join(ROOT, "sim", name)
    with open(path, "w") as f:
        for b in stream:
            f.write("%02x\n" % (b & 0xFF))
    return path


# ---------------------------------------------------------------------------
# DPC: median of the 8 neighbours via the RTL Batcher-8 network.
#   taps: 0 1 2 / 3 4 5 / 6 7 8 ; neighbours = taps except index 4.
#   med8 = (s[3] + s[4]) >> 1 of the sorted neighbours; |c - med8| > THR swaps.
# ---------------------------------------------------------------------------
def _ce(lst, i, j):
    if lst[i] > lst[j]:
        lst[i], lst[j] = lst[j], lst[i]


def sort8_net(v):
    """Batcher odd-even mergesort for n=8 (19 comparators) -- mirrors RTL."""
    a = list(v)
    for (i, j) in [(0, 1), (2, 3), (4, 5), (6, 7),
                   (0, 2), (1, 3), (4, 6), (5, 7),
                   (1, 2), (5, 6),
                   (0, 4), (1, 5), (2, 6), (3, 7),
                   (2, 4), (3, 5),
                   (1, 2), (3, 4), (5, 6)]:
        _ce(a, i, j)
    return a


def med8(w):
    nb = [w[i] for i in (0, 1, 2, 3, 5, 6, 7, 8)]
    s = sort8_net(nb)
    return (s[3] + s[4]) >> 1


def dpc_stream(img):
    out = []
    for y in range(H):
        for x in range(W):
            w = window(img, y, x)
            c = w[4]
            m = med8(w)
            d = c - m if c > m else m - c
            out.append(m if d > DPC_THR else c)
    return out


# ---------------------------------------------------------------------------
# DEM: Bayer RGGB bilinear.  Phase by (y&1, x&1):
#   00 R site : R=c,            G=avg4(cross), B=avg4(diag)
#   01 G (R row): R=avg2(l,r),  G=c,           B=avg2(u,d)
#   10 G (B row): R=avg2(u,d),  G=c,           B=avg2(l,r)
#   11 B site : R=avg4(diag),   G=avg4(cross), B=c
# taps: tl up tr / lf c rt / bl dn br -> w[0..8]
# ---------------------------------------------------------------------------
def dem_stream(img):
    out = []
    for y in range(H):
        for x in range(W):
            w = window(img, y, x)
            tl, up, tr, lf, c, rt, bl, dn, br = w
            g4 = (up + dn + lf + rt) >> 2
            d4 = (tl + tr + bl + br) >> 2
            h2 = (lf + rt) >> 1
            v2 = (up + dn) >> 1
            ph = ((y & 1) << 1) | (x & 1)
            if ph == 0:
                r, g, b = c, g4, d4
            elif ph == 1:
                r, g, b = h2, c, v2
            elif ph == 2:
                r, g, b = v2, c, h2
            else:
                r, g, b = d4, g4, c
            out += [r, g, b]
    return out


# ---------------------------------------------------------------------------
# AWB: gray-world.  Each frame segment (NP beats of the pix24 stream)
# accumulates sums; means = sum >> 10 (1024 px).  Gains latch one beat after
# the last pixel of a frame and apply from the NEXT frame's first pixel:
#   gain_x = clamp( (mean_g << 8) / mean_x , 0x3FF ), den==0 -> 0x3FF
#   out    = min(255, (v*gain)>>8)    applied to R and B; G passes.
#   Frame 0 runs at the reset gain 0x100 (identity).
# ---------------------------------------------------------------------------
def div_gain(num, den):
    if den == 0:
        return 0x3FF
    q = (num << 8) // den
    return 0x3FF if q > 0x3FF else q


def apply_gain(v, g):
    return min(255, (v * g) >> 8)


def awb_stream(seq):
    out = []
    gain_r = gain_b = 0x100
    nf = len(seq) // NP
    for f in range(nf):
        seg = seq[f * NP:(f + 1) * NP]
        sr = sum(p[1] for p in seg)
        sg = sum(p[2] for p in seg)
        sb = sum(p[3] for p in seg)
        new_gr = div_gain(sg >> 10, sr >> 10)
        new_gb = div_gain(sg >> 10, sb >> 10)
        for (_, r, g, b) in seg:
            out += [apply_gain(r, gain_r), g, apply_gain(b, gain_b)]
        gain_r, gain_b = new_gr, new_gb
    return out


# ---------------------------------------------------------------------------
# GAM: 256-entry LUT, gamma encode ~1/2.2: lut[i]=round(255*(i/255)^(1/2.2)).
# Applied per channel (three identical LUT banks in RTL).
# ---------------------------------------------------------------------------
def gamma_lut():
    lut = []
    for i in range(256):
        v = int(255.0 * ((i / 255.0) ** (1.0 / 2.2)) + 0.5)
        lut.append(min(255, v))
    return lut


def gam_stream(seq, lut):
    out = []
    for (_, r, g, b) in seq:
        out += [lut[r], lut[g], lut[b]]
    return out


# ---------------------------------------------------------------------------
# CSC: BT.601 full-range fixed point, shift-add coefficients (no multipliers).
#   fwd: Y  = (77R + 150G + 29B) >> 8                      (never clips)
#        Cb = (128B - 43R - 85G + 32768) >> 8              (range [0,255])
#        Cr = (128R - 107G - 21B + 32768) >> 8             (range [0,255])
#   inv: R = clip( Y + ((359*cri + 128) >> 8) )            (>> = floor)
#        G = clip( Y - ((88*cbi + 183*cri + 128) >> 8) )
#        B = clip( Y + ((454*cbi + 128) >> 8) )
#   cbi = Cb - 128, cri = Cr - 128.  Input byte order {ch0,ch1,ch2} =
#   {R,G,B} forward, {Y,Cb,Cr} inverse.
# ---------------------------------------------------------------------------
def clip8(v):
    return 0 if v < 0 else (255 if v > 255 else v)


def csc_fwd(r, g, b):
    y = (77 * r + 150 * g + 29 * b) >> 8
    cb = (128 * b - 43 * r - 85 * g + 32768) >> 8
    cr = (128 * r - 107 * g - 21 * b + 32768) >> 8
    return y, cb, cr


def csc_inv(y, cb, cr):
    cbi = cb - 128
    cri = cr - 128
    r = clip8(y + ((359 * cri + 128) >> 8))
    g = clip8(y - ((88 * cbi + 183 * cri + 128) >> 8))
    b = clip8(y + ((454 * cbi + 128) >> 8))
    return r, g, b


def csc_stream(seq):
    """Selftest: mode = fidx[0] per beat; fidx has already advanced on the
    wrap beat, so mode follows the SOURCE frame of the rotated pixel."""
    out = []
    for (src_f, c0, c1, c2) in seq:
        inv = src_f & 1
        out += list(csc_inv(c0, c1, c2) if inv else csc_fwd(c0, c1, c2))
    return out


# ---------------------------------------------------------------------------
# GRY: Y = (77R + 150G + 29B) >> 8  (coefficients sum to 256, never clips)
# ---------------------------------------------------------------------------
def gry_stream(seq):
    return [(77 * r + 150 * g + 29 * b) >> 8 for (_, r, g, b) in seq]


# ---------------------------------------------------------------------------
# self-checks (network correctness must be proven inside the golden, not in
# RTL; mirrors imgwin golden_model.py verify_median_network)
# ---------------------------------------------------------------------------
def selfcheck():
    import itertools, random
    for t in itertools.product(range(4), repeat=8):
        if sort8_net(list(t)) != sorted(t):
            return "sort8 mismatch on %r" % (t,)
    random.seed(7)
    for _ in range(50000):
        v = [random.randrange(256) for _ in range(8)]
        if sort8_net(v) != sorted(v):
            return "sort8 mismatch on %r" % (v,)
    lut = gamma_lut()
    if lut[0] != 0 or lut[255] != 255 or any(lut[i] > lut[i + 1] for i in range(255)):
        return "gamma LUT not monotonic"
    # CSC forward range check over randoms
    for _ in range(20000):
        r, g, b = (random.randrange(256) for _ in range(3))
        y, cb, cr = csc_fwd(r, g, b)
        if not (0 <= y <= 255 and 0 <= cb <= 255 and 0 <= cr <= 255):
            return "csc_fwd out of range"
    # rotation sanity: first pix24 beat = colour of pixel (1,0,f0);
    # wrap beat carries (0,0) of same frame for nf=1
    s = pix24_seq(1)
    if s[0] != (0,) + pix24(stim_pix(1, 0, 0)) or \
       s[NP - 1] != (0,) + pix24(stim_pix(0, 0, 0)):
        return "pix24_seq rotation wrong"
    s2 = pix24_seq(2)
    if s2[NP - 1] != (1,) + pix24(stim_pix(0, 0, 1)):
        return "pix24_seq cross-frame wrap wrong"
    return None


if __name__ == "__main__":
    err = selfcheck()
    if err:
        print("SELFCHECK FAIL: %s" % err)
        sys.exit(1)
    print("selfcheck: PASS (sort8 net, gamma LUT, csc range, pix24 rotation)")

    img0 = frame(0)
    seq1 = pix24_seq(1)     # 1 frame, rotated
    seq2 = pix24_seq(2)     # 2 frames, rotated w/ cross-frame wrap
    lut = gamma_lut()

    streams = {
        "DPC": (dpc_stream(img0), "golden_isp_dpc.txt"),
        "DEM": (dem_stream(img0), "golden_isp_demosaic.txt"),
        "AWB": (awb_stream(seq2), "golden_isp_awb.txt"),
        "GAM": (gam_stream(seq1, lut), "golden_isp_gamma.txt"),
        "CSC": (csc_stream(seq2), "golden_isp_csc.txt"),
        "GRY": (gry_stream(seq1), "golden_isp_rgb2gray.txt"),
    }
    for tag, (stream, fname) in streams.items():
        write_stream(fname, stream)
        print("%s DIGEST=%08X  bytes=%d" % (tag, fold(FNV_SEED, stream), len(stream)))

    memp = os.path.join(ROOT, "sim", "gamma_lut.mem")
    with open(memp, "w") as f:
        for v in lut:
            f.write("%02x\n" % v)
    print("wrote sim/gamma_lut.mem + sim/golden_isp_*.txt")
