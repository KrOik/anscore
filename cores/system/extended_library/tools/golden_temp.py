# ============================================================================
# golden_temp.py -- independent golden model for wave2 group E units
# (temporal analysis + connected components: idx20..24).
#
# Replicates w2_img_stim.v pixel formula EXACTLY (see that file's header):
#   base  = (x + x<<4) ^ (y + y<<3 + y<<5) ^ ((x & y) << 3)     [mod 256]
#   boost region: sx0 = 6 + 2*fidx, sy0 = 5 + fidx,
#                 boost = sx0<=x<=sx0+3 && sy0<=y<=sy0+5
#   pix   = base + 0x50 when boost else base                    [mod 256]
#
# Units / parameters (must match src/st_<unit>.v localparams):
#   FDIF frame_diff : N_FRAMES=3, THR=32.  Emits mask byte (0/1) for every
#                     pixel of frames 1..N-1 (mask = |curr-prev| > THR).
#   BGS  bg_model   : N_FRAMES=4, ALPHA=4, THR=32.  bg init = frame0 pixel;
#                     later frames: d = pix - bg (signed); fg = |d|>THR;
#                     bg = bg + (d >> ALPHA)  (arithmetic/floor shift, mod 256).
#                     Emits fg byte per pixel of FINAL frame, then all 1024
#                     final background bytes.
#   BBOX mot_bbox   : input = FDIF mask stream (frames 1..2 of N_FRAMES=3
#                     chain).  Per received frame emits 6 bytes:
#                     minx,miny,maxx,maxy,count_lo,count_hi (zeros if empty).
#   CCL  ccl_bbox   : input frame = (frame0 pix >= 160).  Two-pass 4-conn CCL,
#                     union-find min-root linking, <=63 labels (0=bg).
#                     Emits [ncomp][ovf] then per root label (ascending):
#                     label, area_lo, area_hi, minx, miny, maxx, maxy.
#   PRJ  meas_proj  : input = raw frame0 pixels (8-bit accumulation).
#                     Emits row sums y=0..31 then col sums x=0..31, each
#                     16-bit little-endian (lo,hi).
#
# Writes sim/golden_<unit>.txt (one %02x byte per line) and prints
# "TAG DIGEST=XXXXXXXX" for each unit.  Digests are FNV-1a over the emitted
# byte stream, init 0x811C9DC5.
# ============================================================================
import os

W = H = 32
NPIX = W * H
FNV_INIT = 0x811C9DC5

OUTDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sim")


def fnv(h, b):
    x = (h ^ b) & 0xFFFFFFFF
    return (x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24)) & 0xFFFFFFFF


def stim_pix(x, y, f):
    base = ((x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^ ((x & y) << 3)) & 0xFF
    sx0 = 6 + 2 * f
    sy0 = 5 + f
    boost = (sx0 <= x <= sx0 + 3) and (sy0 <= y <= sy0 + 5)
    return (base + 0x50) & 0xFF if boost else base


def get_frames(n):
    return [[[stim_pix(x, y, f) for x in range(W)] for y in range(H)]
            for f in range(n)]


def emit(tag, unit, stream):
    """stream: list of byte ints.  Writes golden file, prints digest."""
    h = FNV_INIT
    for b in stream:
        h = fnv(h, b)
    path = os.path.join(OUTDIR, "golden_%s.txt" % unit)
    with open(path, "w") as f:
        for b in stream:
            f.write("%02x\n" % (b & 0xFF))
    print("%s DIGEST=%08X  (%d bytes)" % (tag, h, len(stream)))
    return h


# ---------------------------------------------------------------- FDIF (idx20)
def gen_fdif():
    NF, THR = 3, 32
    fr = get_frames(NF)
    s = []
    for f in range(1, NF):
        for y in range(H):
            for x in range(W):
                d = fr[f][y][x] - fr[f - 1][y][x]
                s.append(1 if (d > THR or d < -THR) else 0)
    return emit("FDIF", "frame_diff", s)


# ----------------------------------------------------------------- BGS (idx21)
def gen_bgs():
    NF, ALPHA, THR = 4, 4, 32
    fr = get_frames(NF)
    bg = [fr[0][y][x] for y in range(H) for x in range(W)]
    s = []
    for f in range(1, NF):
        for y in range(H):
            for x in range(W):
                i = y * W + x
                p = fr[f][y][x]
                d = p - bg[i]
                if f == NF - 1:
                    s.append(1 if (d > THR or d < -THR) else 0)
                bg[i] = (bg[i] + (d >> ALPHA)) & 0xFF   # python >> = floor
    s.extend(bg)
    return emit("BGS", "bg_model", s)


# ---------------------------------------------------------------- BBOX (idx22)
def gen_bbox():
    NF, THR = 3, 32     # chain: stim(3f) -> frame_diff -> mot_bbox(NFR=2)
    fr = get_frames(NF)
    s = []
    for f in range(1, NF):
        cnt = 0
        minx = miny = W  # bigger than any coord
        maxx = maxy = -1
        for y in range(H):
            for x in range(W):
                d = fr[f][y][x] - fr[f - 1][y][x]
                m = 1 if (d > THR or d < -THR) else 0
                if m:
                    cnt += 1
                    minx = min(minx, x); miny = min(miny, y)
                    maxx = max(maxx, x); maxy = max(maxy, y)
        if cnt == 0:
            s.extend([0, 0, 0, 0, 0, 0])
        else:
            s.extend([minx, miny, maxx, maxy, cnt & 0xFF, (cnt >> 8) & 0xFF])
    return emit("BBOX", "mot_bbox", s)


# ----------------------------------------------------------------- CCL (idx23)
def gen_ccl():
    THR = 160
    MAXLBL = 63
    fr = get_frames(1)
    mask = [[1 if fr[0][y][x] >= THR else 0 for x in range(W)] for y in range(H)]

    # pass 1: raster label + union (link larger root under smaller root)
    lbl = [[0] * W for _ in range(H)]
    parent = [0] * (MAXLBL + 1)
    top = 0
    ovf = 0

    def find(a):
        while parent[a] != a:
            a = parent[a]
        return a

    for y in range(H):
        for x in range(W):
            if not mask[y][x]:
                continue
            w = lbl[y][x - 1] if x > 0 else 0
            n = lbl[y - 1][x] if y > 0 else 0
            if w == 0 and n == 0:
                if top >= MAXLBL:
                    ovf = 1          # pixel dropped (documented simplification)
                    continue
                top += 1
                lbl[y][x] = top
                parent[top] = top
            elif w == 0 or n == 0:
                lbl[y][x] = w | n
            elif w == n:
                lbl[y][x] = w
            else:
                a, b = (w, n) if w < n else (n, w)
                lbl[y][x] = a
                ra, rb = find(a), find(b)
                if ra != rb:
                    parent[max(ra, rb)] = min(ra, rb)

    # resolve + pass 2 stats per root label
    area = [0] * (MAXLBL + 1)
    minx = [W] * (MAXLBL + 1); miny = [H] * (MAXLBL + 1)
    maxx = [0] * (MAXLBL + 1); maxy = [0] * (MAXLBL + 1)
    for y in range(H):
        for x in range(W):
            l = lbl[y][x]
            if l == 0:
                continue
            r = find(l)
            area[r] += 1
            minx[r] = min(minx[r], x); miny[r] = min(miny[r], y)
            maxx[r] = max(maxx[r], x); maxy[r] = max(maxy[r], y)

    ncomp = sum(1 for l in range(1, top + 1) if area[l] > 0)
    s = [ncomp & 0xFF, ovf & 0xFF]
    for l in range(1, top + 1):
        if area[l] == 0:
            continue
        s.extend([l & 0xFF, area[l] & 0xFF, (area[l] >> 8) & 0xFF,
                  minx[l], miny[l], maxx[l], maxy[l]])
    return emit("CCL", "ccl_bbox", s)


# ----------------------------------------------------------------- PRJ (idx24)
def gen_prj():
    fr = get_frames(1)
    rows = [sum(fr[0][y]) for y in range(H)]
    cols = [sum(fr[0][y][x] for y in range(H)) for x in range(W)]
    s = []
    for v in rows:
        s.extend([v & 0xFF, (v >> 8) & 0xFF])
    for v in cols:
        s.extend([v & 0xFF, (v >> 8) & 0xFF])
    return emit("PRJ", "meas_proj", s)


if __name__ == "__main__":
    gen_fdif()
    gen_bgs()
    gen_bbox()
    gen_ccl()
    gen_prj()
