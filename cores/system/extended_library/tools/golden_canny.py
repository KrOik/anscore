#!/usr/bin/env python3
# ============================================================================
# golden_canny.py -- independent golden model for wave2 group-B units
# (idx6..9: canny_grad / canny_nms / canny_dth / canny_hyst).
#
# Stimulus: w2_img_stim frame 0, IMG_W=IMG_H=32 (pixel formula replicated
# verbatim from src/w2_img_stim.v).  Window semantics: 3x3, tap(r,c) =
# img[clamp(y+r-1)][clamp(x+c-1)], emitted row-major -- identical to
# win3x3_gen / w2_win_rd edge-replication policy.
#
# Chain tested by the st_ cells:
#   st_canny_grad : stim -> grad                        (digest: mag,dir bytes)
#   st_canny_nms  : stim -> grad -> nms                 (digest: thinned mag)
#   st_canny_dth  : stim -> grad -> dth(LO=100,HI=200)  (digest: class byte)
#   st_canny_hyst : stim -> grad -> nms -> dth(LO=200,HI=255) -> hyst
#                   then a synthetic 2nd class frame -> hyst (isolated-weak
#                   coverage: the stim frame has every weak pixel adjacent to
#                   a strong one, so the reject path needs a synthetic frame)
#
# Output: sim/golden_canny_<unit>.txt (one hex byte per line) + per-unit
#         "TAG DIGEST=XXXXXXXX" lines for the st_ cell EXP constants.
# ============================================================================
import os

W = H = 32
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim")

TH_LO_DTH, TH_HI_DTH = 100, 200   # st_canny_dth thresholds (raw-mag chain)
TH_LO_HYS, TH_HI_HYS = 200, 255   # st_canny_hyst chain thresholds (nms chain)


# ---------------------------------------------------------------------------
# stimulus (verbatim w2_img_stim, frame index 0 -> sx0=6, sy0=5)
# ---------------------------------------------------------------------------
def stim_pix(x, y):
    base = ((x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^ ((x & y) << 3)) & 0xFF
    if 6 <= x <= 9 and 5 <= y <= 10:
        base = (base + 0x50) & 0xFF
    return base


IMG = [[stim_pix(x, y) for x in range(W)] for y in range(H)]


def clamp(v, hi):
    return 0 if v < 0 else (hi if v > hi else v)


def window(img, y, x):
    """9 taps, index i = r*3+c row-major, edge replication (clamp)."""
    return [img[clamp(y + r - 1, H - 1)][clamp(x + c - 1, W - 1)]
            for r in range(3) for c in range(3)]


def fnv(h, b):
    h ^= b & 0xFF
    return (h * 0x01000193) & 0xFFFFFFFF


FNV_SEED = 0x811C9DC5


def digest_of(byte_stream):
    h = FNV_SEED
    for b in byte_stream:
        h = fnv(h, b)
    return h


# ---------------------------------------------------------------------------
# unit models
# ---------------------------------------------------------------------------
def grad(w):
    """canny_grad: Sobel Gx/Gy -> saturated |Gx|+|Gy| and 2-bit direction.
    dir: 0 = ~0deg  (8*|Gy| <= 3*|Gx|, |Gx| dominant -> NMS along row)
         2 = ~90deg (8*|Gx| <= 3*|Gy|, |Gy| dominant -> NMS along col)
         1 = ~45deg (sign(Gx)==sign(Gy), TL-BR diagonal neighbours)
         3 = ~135deg (opposite signs, TR-BL diagonal neighbours)
    Checks 0deg first; both axis tests true only when Gx=Gy=0 -> dir 0."""
    gx = (w[2] + 2 * w[5] + w[8]) - (w[0] + 2 * w[3] + w[6])
    gy = (w[6] + 2 * w[7] + w[8]) - (w[0] + 2 * w[1] + w[2])
    agx, agy = abs(gx), abs(gy)
    mag = min(agx + agy, 255)
    if 8 * agy <= 3 * agx:
        d = 0
    elif 8 * agx <= 3 * agy:
        d = 2
    elif (gx < 0) == (gy < 0):
        d = 1
    else:
        d = 3
    return mag, d


# dir -> the two directional neighbours compared in NMS (dr,dc offsets)
NMS_NB = {0: ((0, -1), (0, 1)),      # gradient ~horizontal  -> left/right
          2: ((-1, 0), (1, 0)),      # gradient ~vertical    -> up/down
          1: ((-1, -1), (1, 1)),     # ~45deg                -> TL/BR
          3: ((-1, 1), (1, -1))}     # ~135deg               -> TR/BL


def nms(mag_img, dir_img, y, x):
    """canny_nms: keep centre iff >= both neighbours along dir (clamped)."""
    c = mag_img[y][x]
    (r1, c1), (r2, c2) = NMS_NB[dir_img[y][x]]
    n1 = mag_img[clamp(y + r1, H - 1)][clamp(x + c1, W - 1)]
    n2 = mag_img[clamp(y + r2, H - 1)][clamp(x + c2, W - 1)]
    return c if (c >= n1 and c >= n2) else 0


def dth(v, lo, hi):
    """canny_dth: 2 strong / 1 weak / 0 none."""
    return 2 if v >= hi else (1 if v >= lo else 0)


def hyst(cls_img, y, x):
    """canny_hyst (single-pass local propagation): strong -> FF;
    weak -> FF iff any of the 8 clamped neighbours is strong; else 00."""
    c = cls_img[y][x]
    if c == 2:
        return 0xFF
    if c == 1:
        for r in (-1, 0, 1):
            for cc in (-1, 0, 1):
                if (r, cc) != (0, 0) and \
                        cls_img[clamp(y + r, H - 1)][clamp(x + cc, W - 1)] == 2:
                    return 0xFF
    return 0x00


def cls_b(x, y):
    """Synthetic pass-B class frame for st_canny_hyst (mirrors RTL formula):
    strong at (x%8==0 && y%8==0); weak at (x%8<=1 && y%8<=1) [strong-adjacent]
    and at (x%8==4 && y%8==4) [isolated]; all other pixels none."""
    mx, my = x & 7, y & 7
    if mx == 0 and my == 0:
        return 2
    if (mx <= 1 and my <= 1) or (mx == 4 and my == 4):
        return 1
    return 0


# ---------------------------------------------------------------------------
# build the streams
# ---------------------------------------------------------------------------
MAG = [[0] * W for _ in range(H)]
DIR = [[0] * W for _ in range(H)]
grad_stream = []
for y in range(H):
    for x in range(W):
        m, d = grad(window(IMG, y, x))
        MAG[y][x] = m
        DIR[y][x] = d
        grad_stream += [m, d]                     # mag byte, then dir byte

NMS_IMG = [[nms(MAG, DIR, y, x) for x in range(W)] for y in range(H)]
nms_stream = [NMS_IMG[y][x] for y in range(H) for x in range(W)]

dth_stream = [dth(MAG[y][x], TH_LO_DTH, TH_HI_DTH)
              for y in range(H) for x in range(W)]

CLS_IMG = [[dth(NMS_IMG[y][x], TH_LO_HYS, TH_HI_HYS) for x in range(W)]
           for y in range(H)]
CLS_B = [[cls_b(x, y) for x in range(W)] for y in range(H)]
hys_stream = ([hyst(CLS_IMG, y, x) for y in range(H) for x in range(W)] +
              [hyst(CLS_B, y, x) for y in range(H) for x in range(W)])


# ---------------------------------------------------------------------------
# emit golden files + digests
# ---------------------------------------------------------------------------
def dump(name, stream):
    path = os.path.join(SIM, name)
    with open(path, "w") as f:
        for b in stream:
            f.write("%02x\n" % b)
    return path


def main():
    os.makedirs(SIM, exist_ok=True)
    for tag, name, stream in (
            ("CGR", "golden_canny_grad.txt", grad_stream),
            ("NMS", "golden_canny_nms.txt", nms_stream),
            ("DTH", "golden_canny_dth.txt", dth_stream),
            ("HYS", "golden_canny_hyst.txt", hys_stream)):
        dump(name, stream)
        print("%s DIGEST=%08X  (%d bytes -> sim/%s)"
              % (tag, digest_of(stream), len(stream), name))

    # coverage stats for the unit doc
    import collections
    dc = collections.Counter(dth_stream)
    cc = collections.Counter(v for r in CLS_IMG for v in r)
    cb = collections.Counter(v for r in CLS_B for v in r)
    hc = collections.Counter(hys_stream)
    print("info: DTH classes none/weak/strong = %d/%d/%d"
          % (dc[0], dc[1], dc[2]))
    print("info: HYS chain classes none/weak/strong = %d/%d/%d"
          % (cc[0], cc[1], cc[2]))
    print("info: HYS passB classes none/weak/strong = %d/%d/%d"
          % (cb[0], cb[1], cb[2]))
    print("info: HYS edges FF/00 = %d/%d" % (hc[0xFF], hc[0x00]))


if __name__ == "__main__":
    main()
