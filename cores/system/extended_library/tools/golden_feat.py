#!/usr/bin/env python3
# ============================================================================
# golden_feat.py -- independent golden model for wave2 group C units
#   (idx10 HAR feat_harris, idx11 FST feat_fast, idx12 LBP feat_lbp,
#    idx13 HOG feat_hog, idx14 INT img_integral)
#
# Pure-Python functional model -- no RTL output harvested (trap T1).
# Replicates w2_img_stim.v pixel formula bit-exactly (32x32, frame 0),
# win3x3_gen edge-replication border policy, and w2_win_rd clamp taps.
#
# Usage:  python tools/golden_feat.py
#   writes sim/golden_{feat_lbp,feat_hog,feat_harris,feat_fast,img_integral}.txt
#   (one hex byte per line = the exact byte stream the st_ cell folds)
#   prints  "<TAG> DIGEST=XXXXXXXX"  for each unit (FNV-1a, seed 0x811C9DC5)
#   plus tuning statistics for the FAST/HARRIS thresholds.
# ============================================================================
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W = 32
H = 32

# ---- tunable constants (must match RTL localparams) -------------------------
FAST_N = 9          # contiguous-arc length
FAST_T = 24         # intensity threshold
HAR_QSH = 7         # gradient quantization shift: qx = gx >> HAR_QSH
HAR_THR = 500       # score flag threshold (signed score > THR)
# -----------------------------------------------------------------------------


def pix(x, y, fidx=0):
    base = ((x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^ ((x & y) << 3)) & 0xFF
    sx0 = 6 + 2 * fidx
    sy0 = 5 + fidx
    if sx0 <= x <= sx0 + 3 and sy0 <= y <= sy0 + 5:
        base = (base + 0x50) & 0xFF
    return base


IMG = [[pix(x, y) for x in range(W)] for y in range(H)]


def clamp(v, hi):
    return 0 if v < 0 else (hi if v > hi else v)


def win3(y, x):
    """win3x3_gen taps, i = r*3+c row-major, edge replication."""
    return [IMG[clamp(y + r - 1, H - 1)][clamp(x + c - 1, W - 1)]
            for r in range(3) for c in range(3)]


def win7(y, x):
    """w2_win_rd K=7 taps, i = r*7+c row-major, per-tap clamp."""
    return [IMG[clamp(y + r - 3, H - 1)][clamp(x + c - 3, W - 1)]
            for r in range(7) for c in range(7)]


FNV_SEED = 0x811C9DC5


def fnv(h, b):
    h ^= b & 0xFF
    return (h * 0x01000193) & 0xFFFFFFFF


def fold(h, seq):
    for b in seq:
        h = fnv(h, b)
    return h


# ---------------------------------------------------------------------------
# idx12 LBP -- feat_lbp
#   ring order (clockwise from top-left): w0 w1 w2 w5 w8 w7 w6 w3
#   code bit i = (ring_i >= centre w4); uniform = (bit transitions <= 2)
#   emits per pixel: [code, 0x01/0x00]
# ---------------------------------------------------------------------------
def lbp_stream():
    out = []
    for y in range(H):
        for x in range(W):
            w = win3(y, x)
            c = w[4]
            ring = [w[0], w[1], w[2], w[5], w[8], w[7], w[6], w[3]]
            code = 0
            for i, v in enumerate(ring):
                if v >= c:
                    code |= 1 << i
            trans = 0
            for i in range(8):
                if ((code >> i) ^ (code >> ((i + 1) & 7))) & 1:
                    trans += 1
            uni = 1 if trans <= 2 else 0
            out += [code, uni]
    return out


# ---------------------------------------------------------------------------
# idx13 HOG -- feat_hog
#   per pixel: dx = w5 - w3, dy = w7 - w1 (central diff, signed)
#   fold dx<0: u = |dx|, v = (dx<0) ? -dy : dy ; av = |v|
#   steep = av >= u ; bin = steep ? (v<0 ? 2 : 1) : (v<0 ? 3 : 0)
#   cell = 8x8 block; emit [c0,c1,c2,c3] when x%8==7 AND y%8==7
#   (16 cells, row-major)
# ---------------------------------------------------------------------------
def hog_stream():
    out = []
    acc = [[0, 0, 0, 0] for _ in range(4)]     # per cell-column
    for y in range(H):
        for x in range(W):
            w = win3(y, x)
            dx = w[5] - w[3]
            dy = w[7] - w[1]
            if dx < 0:
                u = -dx
                v = -dy
            else:
                u = dx
                v = dy
            av = v if v >= 0 else -v
            steep = av >= u
            if steep:
                b = 2 if v < 0 else 1
            else:
                b = 3 if v < 0 else 0
            cc = x >> 3
            acc[cc][b] += 1
            if (x & 7) == 7 and (y & 7) == 7:
                out += acc[cc]
                acc[cc] = [0, 0, 0, 0]
    return out


# ---------------------------------------------------------------------------
# idx10 HAR -- feat_harris
#   gx = (w2 + 2w5 + w8) - (w0 + 2w3 + w6)   Sobel, range +-1020
#   gy = (w6 + 2w7 + w8) - (w0 + 2w1 + w2)
#   qx = gx >> HAR_QSH (arithmetic), qy = gy >> HAR_QSH
#   pxx = qx*qx, pyy = qy*qy, pxy = qx*qy
#   CAUSAL 3x3 accumulation with edge replication:
#     S(y,x) = sum_{i=0..2} sum_{j=0..2} p[clamp(y-i)][clamp(x-j)]
#   score = (Sxx*Syy - Sxy*Sxy) - ((Sxx+Syy)*(Sxx+Syy) >> 5)   [signed 32b]
#   emits per pixel: score[7:0], [15:8], [23:16], [31:24], flag(0/1)
# ---------------------------------------------------------------------------
def harris_stream():
    pxx = [[0] * W for _ in range(H)]
    pyy = [[0] * W for _ in range(H)]
    pxy = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            w = win3(y, x)
            gx = (w[2] + 2 * w[5] + w[8]) - (w[0] + 2 * w[3] + w[6])
            gy = (w[6] + 2 * w[7] + w[8]) - (w[0] + 2 * w[1] + w[2])
            qx = gx >> HAR_QSH          # python >> = arithmetic shift
            qy = gy >> HAR_QSH
            pxx[y][x] = qx * qx
            pyy[y][x] = qy * qy
            pxy[y][x] = qx * qy
    out = []
    scores = []
    for y in range(H):
        for x in range(W):
            sxx = syy = sxy = 0
            for i in range(3):
                for j in range(3):
                    yy = clamp(y - i, H - 1)
                    xx = clamp(x - j, W - 1)
                    sxx += pxx[yy][xx]
                    syy += pyy[yy][xx]
                    sxy += pxy[yy][xx]
            det = sxx * syy - sxy * sxy
            tr = sxx + syy
            score = det - ((tr * tr) >> 5)
            score &= 0xFFFFFFFF          # wrap to 32 bits (two's complement)
            sscore = score - 0x100000000 if score & 0x80000000 else score
            scores.append(sscore)
            flag = 1 if sscore > HAR_THR else 0
            out += [score & 0xFF, (score >> 8) & 0xFF,
                    (score >> 16) & 0xFF, (score >> 24) & 0xFF, flag]
    return out, scores


# ---------------------------------------------------------------------------
# idx11 FST -- feat_fast
#   7x7 clamped window, centre tap24; Bresenham r=3 circle tap indices:
#     (dx,dy): (0,-3)(1,-3)(2,-2)(3,-1)(3,0)(3,1)(2,2)(1,3)(0,3)(-1,3)
#              (-2,2)(-3,1)(-3,0)(-3,-1)(-2,-2)(-1,-3)
#   bright_i = circ_i > c + T ; dark_i = circ_i + T < c   (9-bit compares)
#   corner = longest circular run(bright) >= N or run(dark) >= N
#   emits per pixel: [flag, arc]   arc = max(runB, runD), 0..16
# ---------------------------------------------------------------------------
FAST_OFFS = [(0, -3), (1, -3), (2, -2), (3, -1), (3, 0), (3, 1), (2, 2),
             (1, 3), (0, 3), (-1, 3), (-2, 2), (-3, 1), (-3, 0), (-3, -1),
             (-2, -2), (-1, -3)]
FAST_TAPS = [(3 + dy) * 7 + (3 + dx) for (dx, dy) in FAST_OFFS]


def maxrun(bits):
    """longest run of 1s on a 16-bit ring."""
    best = 0
    for s in range(16):
        n = 0
        while n < 16 and bits[(s + n) & 15]:
            n += 1
        best = max(best, n)
    return best


def fast_stream(thr=FAST_T, n=FAST_N):
    out = []
    ncorn = 0
    for y in range(H):
        for x in range(W):
            w = win7(y, x)
            c = w[24]
            brt = [1 if w[FAST_TAPS[i]] > c + thr else 0 for i in range(16)]
            drk = [1 if w[FAST_TAPS[i]] + thr < c else 0 for i in range(16)]
            rb = maxrun(brt)
            rd = maxrun(drk)
            flag = 1 if (rb >= n or rd >= n) else 0
            arc = rb if rb >= rd else rd
            ncorn += flag
            out += [flag, arc]
    return out, ncorn


# ---------------------------------------------------------------------------
# idx14 INT -- img_integral
#   I(y,x) = p + I(y,x-1) + I(y-1,x) - I(y-1,x-1);  I(*,-1)=I(-1,*)=0
#   stored row buffers are 18-bit (max 32*32*255 = 261120 < 2^18)
#   emits per pixel: 4 bytes little-endian of the 32-bit register
# ---------------------------------------------------------------------------
def int_stream():
    out = []
    prev = [0] * W
    for y in range(H):
        left = 0
        aleft = 0
        cur = [0] * W
        for x in range(W):
            above = prev[x]
            iv = IMG[y][x] + left + above - aleft
            iv &= 0x3FFFF            # 18-bit storage cap
            cur[x] = iv
            aleft = above
            left = iv
            out += [iv & 0xFF, (iv >> 8) & 0xFF,
                    (iv >> 16) & 0xFF, (iv >> 24) & 0xFF]
        prev = cur
    return out


# ---------------------------------------------------------------------------
def write_stream(name, out):
    path = os.path.join(ROOT, "sim", "golden_%s.txt" % name)
    with open(path, "w") as f:
        for b in out:
            f.write("%02x\n" % (b & 0xFF))
    return fold(FNV_SEED, out)


def main():
    res = {}

    s = lbp_stream()
    res["LBP"] = write_stream("feat_lbp", s)

    s = hog_stream()
    res["HOG"] = write_stream("feat_hog", s)

    s, scores = harris_stream()
    res["HAR"] = write_stream("feat_harris", s)
    nc = sum(1 for v in scores if v > HAR_THR)
    print("HAR stats: QSH=%d THR=%d  score min=%d max=%d  flags=%d/1024"
          % (HAR_QSH, HAR_THR, min(scores), max(scores), nc))

    s, ncorn = fast_stream()
    res["FST"] = write_stream("feat_fast", s)
    for t in (8, 16, 24, 32, 48):
        _, n_t = fast_stream(thr=t)
        print("FST stats: T=%d corners=%d/1024" % (t, n_t))

    s = int_stream()
    res["INT"] = write_stream("img_integral", s)

    for tag in ("HAR", "FST", "LBP", "HOG", "INT"):
        print("%s DIGEST=%08X" % (tag, res[tag]))
    print("wrote sim/golden_{feat_harris,feat_fast,feat_lbp,feat_hog,"
          "img_integral}.txt")


if __name__ == "__main__":
    main()
