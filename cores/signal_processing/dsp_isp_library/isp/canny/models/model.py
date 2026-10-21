"""Bit-exact reference for isp/canny (ISP-16 Canny edge chain).

Pipeline, identical to rtl/canny_stream.sv:
  1. optional 3x3 Gaussian smooth [1 2 1;2 4 2;1 2 1]/16, round-half-up
     (cfg_smooth=0 bypasses the smoother, documented sigma=0 mode)
  2. Sobel Gx/Gy on the smoothed image (3x3, same padding mode)
  3. L1 magnitude |Gx|+|Gy| and gradient direction quantized to the same
     8-sector scheme as isp/gradient (22.5 deg bound = 53/128), folded to
     the 4 NMS neighbour pairs {W-E, N-S, NE-SW, NW-SE}
  4. non-maximum suppression: keep if mag >= both directional neighbours
     (ties kept, documented); flat pixels (Gx=Gy=0) are forced NONE
  5. double threshold: mag>=t_hi -> EDGE(2), mag>=t_lo -> WEAK(1), else 0
  6. hysteresis: PASSES alternating serpentine propagation sweeps over the
     stored class bitmap. Pass 0 is forward raster (causal NW,N,NE,W),
     pass 1 backward (causal SE,S,SW,E), alternating. Within a sweep a
     WEAK pixel is promoted to EDGE if any 8-neighbour is EDGE, where
     already-visited (causal) neighbours see this-pass promotions and
     not-yet-visited (anti-causal) neighbours see pass-start values.
     This is a BOUNDED approximation of exact Canny flood hysteresis;
     canny_exact() below gives the exact flood for error quantification.

Padding: pad=0 -> outside pixels are zero (records {sec=0,av=0,mag=0});
pad=1 -> edge replication (replicated record at window stage 3).
"""
CLS_NONE, CLS_WEAK, CLS_EDGE = 0, 1, 2


def _pad_pix(img, y, x, pad):
    h = len(img); w = len(img[0])
    if 0 <= y < h and 0 <= x < w:
        return img[y][x]
    if pad == 0:
        return 0
    return img[min(max(y, 0), h - 1)][min(max(x, 0), w - 1)]


def smooth3(img, pad):
    """3x3 Gaussian [1 2 1;2 4 2;1 2 1]/16 round-half-up."""
    h = len(img); w = len(img[0])
    k = ((1, 2, 1), (2, 4, 2), (1, 2, 1))
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            acc = 0
            for iy in range(3):
                for ix in range(3):
                    acc += k[iy][ix] * _pad_pix(img, y + iy - 1, x + ix - 1, pad)
            row.append((acc + 8) >> 4)
        out.append(row)
    return out


def _pad_rec(rec, y, x, pad):
    """Window-3 record padding: zero record or edge-record replication."""
    h = len(rec); w = len(rec[0])
    if 0 <= y < h and 0 <= x < w:
        return rec[y][x]
    if pad == 0:
        return (0, 0, 0)
    return rec[min(max(y, 0), h - 1)][min(max(x, 0), w - 1)]


def sector(gx, gy):
    """Folded NMS sector. 0:W/E 1:N/S 2:NE/SW(signs equal) 3:NW/SE."""
    ax, ay = abs(gx), abs(gy)
    if ax == 0 and ay == 0:
        return 0, False
    if 128 * ay < 53 * ax:
        return 0, True
    if 128 * ax < 53 * ay:
        return 1, True
    return (2 if (gx < 0) == (gy < 0) else 3), True


def nms_classify(img, t_lo, t_hi, smooth, pad):
    """Stages 2-5: returns per-pixel class bitmap and record image."""
    h = len(img); w = len(img[0])
    sm = smooth3(img, pad) if smooth else img
    rec = []
    for y in range(h):
        rrow = []
        for x in range(w):
            p = [[_pad_pix(sm, y + iy - 1, x + ix - 1, pad) for ix in range(3)]
                 for iy in range(3)]
            gx = (p[0][2] - p[0][0]) + 2 * (p[1][2] - p[1][0]) + (p[2][2] - p[2][0])
            gy = (p[2][0] - p[0][0]) + 2 * (p[2][1] - p[0][1]) + (p[2][2] - p[0][2])
            mag = abs(gx) + abs(gy)
            sec, av = sector(gx, gy)
            rrow.append((sec, int(av), mag))
        rec.append(rrow)
    nb = {0: ((0, -1), (0, 1)), 1: ((-1, 0), (1, 0)),
          2: ((-1, 1), (1, -1)), 3: ((-1, -1), (1, 1))}
    cls = [[CLS_NONE] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            sec, av, mag = rec[y][x]
            na = _pad_rec(rec, y + nb[sec][0][0], x + nb[sec][0][1], pad)[2]
            nbx = _pad_rec(rec, y + nb[sec][1][0], x + nb[sec][1][1], pad)[2]
            if not av or mag < na or mag < nbx:
                continue
            if mag >= t_hi:
                cls[y][x] = CLS_EDGE
            elif mag >= t_lo:
                cls[y][x] = CLS_WEAK
    return cls, rec


def hysteresis(cls, passes):
    """Bounded serpentine propagation, identical to the RTL sweep order."""
    h = len(cls); w = len(cls[0])
    bm = [row[:] for row in cls]
    promoted = 0
    for p in range(passes):
        ys = range(h) if p % 2 == 0 else range(h - 1, -1, -1)
        for y in ys:
            xs = range(w) if p % 2 == 0 else range(w - 1, -1, -1)
            for x in xs:
                if bm[y][x] != CLS_WEAK:
                    continue
                hit = False
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dy == 0 and dx == 0:
                            continue
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < h and 0 <= nx < w and bm[ny][nx] == CLS_EDGE:
                            hit = True
                if hit:
                    bm[y][x] = CLS_EDGE
                    promoted += 1
    return bm, promoted


def hysteresis_exact(cls):
    """Exact Canny flood: WEAK reachable from EDGE via 8-connectivity."""
    h = len(cls); w = len(cls[0])
    bm = [row[:] for row in cls]
    stack = [(y, x) for y in range(h) for x in range(w) if bm[y][x] == CLS_EDGE]
    while stack:
        y, x = stack.pop()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and bm[ny][nx] == CLS_WEAK:
                    bm[ny][nx] = CLS_EDGE
                    stack.append((ny, nx))
    return bm


def canny(image, t_lo, t_hi, smooth=True, pad=0, passes=4):
    """Full bit-exact chain. Returns dict with mask/classes/promotions and
    the exact-hysteresis mask plus divergence count vs the bounded mode."""
    h = len(image); w = len(image[0]); maxpix = (1 << 8) - 1
    cls, rec = nms_classify(image, t_lo, t_hi, smooth, pad)
    bm, promoted = hysteresis(cls, passes)
    ex = hysteresis_exact(cls)
    mask = [[(1 if bm[y][x] == CLS_EDGE else 0) for x in range(w)]
            for y in range(h)]
    exmask = [[(1 if ex[y][x] == CLS_EDGE else 0) for x in range(w)]
              for y in range(h)]
    diff = sum(1 for y in range(h) for x in range(w)
               if mask[y][x] != exmask[y][x])
    return dict(mask=mask, classes=bm, promoted=promoted,
                exact_mask=exmask, diff_vs_exact=diff,
                strong=sum(1 for r in cls for c in r if c == CLS_EDGE),
                weak=sum(1 for r in cls for c in r if c == CLS_WEAK))
