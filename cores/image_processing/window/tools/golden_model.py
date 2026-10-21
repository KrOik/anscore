#!/usr/bin/env python3
# ============================================================================
# golden_model.py -- independent golden model for imgwin_20k selftest units.
#
# Pure-Python functional model (no RTL output harvested; trap T1 compliance).
# Computes the 16x16 formula test image, the win3x3_gen output window stream
# under EDGE-REPLICATION border policy, every filter's output stream, and the
# FNV-1a digests folded the same way as src/imgwin_selftest.v.
#
# Usage:
#   python tools/golden_model.py           -> prints EXP_* digests + writes
#                                             sim/golden_*.txt stream files
#   python tools/golden_model.py --report  -> also writes sim/expected_report.mem
#
# Border policy (must match win3x3_gen.v): output pixel (y,x), y=0..H-1,
# x=0..W-1 emitted row-major; tap(r,c) = I[clamp(y+r-1)][clamp(x+c-1)].
# ============================================================================
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W = 16
H = 16
THR = 128          # threshold_bin THRESH
SOB_TH = 96        # sobel_edge THRESH


def pix(x, y):
    base = ((x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^ ((x & y) << 3)) & 0xFF
    if 6 <= x <= 9 and 5 <= y <= 10:
        base = (base + 0x50) & 0xFF
    return base


IMG = [[pix(x, y) for x in range(W)] for y in range(H)]


def clamp(v, hi):
    return 0 if v < 0 else (hi if v > hi else v)


def window(img, y, x):
    """9 taps, i = r*3+c row-major, edge replication."""
    return [img[clamp(y + r - 1, H - 1)][clamp(x + c - 1, W - 1)]
            for r in range(3) for c in range(3)]


def fnv(h, b):
    h ^= b & 0xFF
    return (h * 0x01000193) & 0xFFFFFFFF


FNV_SEED = 0x811C9DC5


def fold(h, seq):
    for b in seq:
        h = fnv(h, b)
    return h


# ---------------------------------------------------------------------------
# filter models (each returns the byte(s) folded per emitted window)
# ---------------------------------------------------------------------------
def gaussian(w):
    s = (w[0] + w[2] + w[6] + w[8]
         + 2 * (w[1] + w[3] + w[5] + w[7]) + 4 * w[4])
    return s >> 4


def sobel(w):
    gx = (w[2] + 2 * w[5] + w[8]) - (w[0] + 2 * w[3] + w[6])
    gy = (w[6] + 2 * w[7] + w[8]) - (w[0] + 2 * w[1] + w[2])
    mag = min(abs(gx) + abs(gy), 255)
    return mag, (0xFF if mag >= SOB_TH else 0x00)


def median(w):
    return sorted(w)[4]


def median_network(w):
    """RTL-equivalent network: sort rows, sort cols, sort anti-diagonal."""
    def s3(a, b, c):
        return sorted((a, b, c))          # (lo,mid,hi)
    r0 = s3(w[0], w[1], w[2]); r1 = s3(w[3], w[4], w[5]); r2 = s3(w[6], w[7], w[8])
    c0 = s3(r0[0], r1[0], r2[0]); c1 = s3(r0[1], r1[1], r2[1]); c2 = s3(r0[2], r1[2], r2[2])
    dg = s3(c0[2], c1[1], c2[0])
    return dg[1]


def morph_bits(w):
    return [1 if t != 0 else 0 for t in w]


def morph(w):
    b = morph_bits(w)
    er = 0xFF if all(b) else 0x00
    di = 0xFF if any(b) else 0x00
    return er, di


def binimg():
    return [[0xFF if IMG[y][x] >= THR else 0x00 for x in range(W)]
            for y in range(H)]


# ---------------------------------------------------------------------------
# digest computation -- fold order must match imgwin_selftest.v exactly
# ---------------------------------------------------------------------------
def digests():
    d = {}
    h = FNV_SEED
    # U0 WIN: fold taps 0..8 per emitted window
    for y in range(H):
        for x in range(W):
            h = fold(h, window(IMG, y, x))
    d["WIN"] = h

    # U1 GAUS
    h = FNV_SEED
    for y in range(H):
        for x in range(W):
            h = fnv(h, gaussian(window(IMG, y, x)))
    d["GAUS"] = h

    # U2 SOB: fold mag then bin per window
    h = FNV_SEED
    for y in range(H):
        for x in range(W):
            m, b = sobel(window(IMG, y, x))
            h = fnv(fnv(h, m), b)
    d["SOB"] = h

    # U3 MED
    h = FNV_SEED
    for y in range(H):
        for x in range(W):
            h = fnv(h, median(window(IMG, y, x)))
    d["MED"] = h

    # U4 MRP: input = thresholded image; fold erode, dilate, pix_out(mode)
    # mode = output-row parity (y odd -> dilate), matching selftest mrp_y[0].
    bi = binimg()
    h = FNV_SEED
    for y in range(H):
        for x in range(W):
            er, di = morph(window(bi, y, x))
            sel = di if (y & 1) else er
            h = fnv(fnv(fnv(h, er), di), sel)
    d["MRP"] = h

    # U5 THR: fold binarized byte per input pixel
    h = FNV_SEED
    for y in range(H):
        for x in range(W):
            h = fnv(h, bi[y][x])
    d["THR"] = h
    return d


# ---------------------------------------------------------------------------
# golden stream dumps (same format as the iverilog TB dump files)
# ---------------------------------------------------------------------------
def write_dumps():
    simdir = os.path.join(ROOT, "sim")
    bi = binimg()
    with open(os.path.join(simdir, "golden_win.txt"), "w") as f:
        for y in range(H):
            for x in range(W):
                taps = window(IMG, y, x)
                f.write("".join("%02x" % t for t in taps)
                        + " %d\n" % (1 if x == 0 else 0))
    with open(os.path.join(simdir, "golden_gau.txt"), "w") as f:
        for y in range(H):
            for x in range(W):
                f.write("%02x %d\n" % (gaussian(window(IMG, y, x)),
                                       1 if x == 0 else 0))
    with open(os.path.join(simdir, "golden_sob.txt"), "w") as f:
        for y in range(H):
            for x in range(W):
                m, b = sobel(window(IMG, y, x))
                f.write("%02x%02x %d\n" % (m, b, 1 if x == 0 else 0))
    with open(os.path.join(simdir, "golden_med.txt"), "w") as f:
        for y in range(H):
            for x in range(W):
                f.write("%02x %d\n" % (median(window(IMG, y, x)),
                                       1 if x == 0 else 0))
    with open(os.path.join(simdir, "golden_mrp.txt"), "w") as f:
        for y in range(H):
            for x in range(W):
                er, di = morph(window(bi, y, x))
                sel = di if (y & 1) else er
                f.write("%02x%02x%02x %d\n" % (er, di, sel,
                                              1 if x == 0 else 0))
    with open(os.path.join(simdir, "golden_thr.txt"), "w") as f:
        for y in range(H):
            for x in range(W):
                f.write("%02x\n" % bi[y][x])


def verify_median_network():
    """Exhaustively check the row/col/diagonal network against a true sort
    over all ternary inputs plus random 8-bit windows."""
    import itertools, random
    for t in itertools.product(range(3), repeat=9):
        if median_network(list(t)) != sorted(t)[4]:
            return False
    random.seed(1)
    for _ in range(20000):
        w = [random.randrange(256) for _ in range(9)]
        if median_network(w) != sorted(w)[4]:
            return False
    return True


NAMES = ["WIN", "GAUS", "SOB", "MED", "MRP", "THR"]

if __name__ == "__main__":
    ok = verify_median_network()
    print("median network check: %s" % ("PASS" if ok else "FAIL"))
    if not ok:
        sys.exit(1)
    d = digests()
    for n in NAMES:
        print("EXP_%s = 32'h%08x;" % (n, d[n]))
    write_dumps()
    print("wrote sim/golden_{win,gau,sob,med,mrp,thr}.txt")
    if "--report" in sys.argv:
        msg = "IMG6 M=%02X P=%02X" % (0x3F, 0x3F)
        for i, n in enumerate(NAMES):
            msg += "U%d %-4s P D=%08X" % (i, n, d[n])
        # pad each line to 32 chars with CRLF like top.v does (30 chars + CRLF)
        lines = ["IMG6 M=%02X P=%02X" % (0x3F, 0x3F)]
        for i, n in enumerate(NAMES):
            lines.append("U%d %-4s P D=%08X" % (i, n, d[n]))
        out = os.path.join(ROOT, "sim", "expected_report.mem")
        with open(out, "w") as f:
            for ln in lines:
                ln = (ln + " " * 30)[:30] + "\r\n"
                for ch in ln:
                    f.write("%02x\n" % ord(ch))
        print("wrote %s" % out)
