"""Bit-exact reference model for rtl/cca_stream.sv (ISP-09, CCA).

Mirrors the RTL contract exactly:
  * raster scan; provisional label = min of distinct nonzero neighbour labels
    (left always; up-left/up/up-right with conn8, up only with conn4)
  * label budget nl: a foreground pixel with no labelled neighbour allocates
    alloc++ when alloc <= nl, else the pixel is dropped (label 0) and
    ovf_lbl is raised
  * sorted distinct neighbour sets with >= 2 members are pushed to the
    equivalence table; when the table is full (eqt entries) the entry is
    dropped and ovf_eq is raised
  * resolve: per entry {n1..nk} in scan order, r1 = find(n1); for each extra
    nj: r2 = find(nj); parent[max(r1,r2)] = min(r1,r2); r1 = min(r1,r2)
    (union-by-min-root -> every root is the class minimum)
  * child features merge into roots scanning labels ascending; regions are
    emitted in ascending root-label order
  * feature tuple = (area, sumX, sumY, minX, maxX, minY, maxY); centroid is
    left to the host (sums are emitted, no division in RTL)

analyze() returns (regions, summary) where
  regions  = [(label, area, sumX, sumY, minX, maxX, minY, maxY), ...]
  summary  = dict(nregions, nalloc, ovf_lbl, ovf_eq)
"""

NL = 128
EQT = 256


def analyze(pix, conn8, nl=NL, eqt=EQT):
    """pix: H rows x W cols of 0/1. Returns (regions, summary)."""
    h = len(pix)
    w = len(pix[0]) if h else 0
    parent = list(range(nl + 1))
    alloc = 1
    ovf_lbl = 0
    ovf_eq = 0
    eq = []                                  # sorted neighbour sets
    feat = [[0] * 7 for _ in range(nl + 1)]  # [area,sx,sy,minx,maxx,miny,maxy]
    lab = [[0] * w for _ in range(h)]
    for yy in range(h):
        for xx in range(w):
            if not pix[yy][xx]:
                continue
            nb = []
            if xx > 0 and lab[yy][xx - 1]:
                nb.append(lab[yy][xx - 1])                # left
            if conn8:
                if xx > 0 and yy > 0 and lab[yy - 1][xx - 1]:
                    nb.append(lab[yy - 1][xx - 1])        # up-left
                if yy > 0 and lab[yy - 1][xx]:
                    nb.append(lab[yy - 1][xx])            # up
                if xx < w - 1 and yy > 0 and lab[yy - 1][xx + 1]:
                    nb.append(lab[yy - 1][xx + 1])        # up-right
            elif yy > 0 and lab[yy - 1][xx]:
                nb.append(lab[yy - 1][xx])                # up (4-conn)
            nb = sorted(set(nb))
            if not nb:
                if alloc <= nl:
                    lab[yy][xx] = alloc
                    parent[alloc] = alloc
                    feat[alloc] = [1, xx, yy, xx, xx, yy, yy]
                    alloc += 1
                else:
                    ovf_lbl = 1                            # dropped pixel
                continue
            picked = nb[0]
            lab[yy][xx] = picked
            if len(nb) >= 2:
                if len(eq) < eqt:
                    eq.append(nb)
                else:
                    ovf_eq = 1                             # dropped merge
            f = feat[picked]
            f[0] += 1
            f[1] += xx
            f[2] += yy
            f[3] = min(f[3], xx)
            f[4] = max(f[4], xx)
            f[5] = min(f[5], yy)
            f[6] = max(f[6], yy)

    def find(i):
        while parent[i] != i:
            i = parent[i]
        return i

    # union pass: apply recorded neighbour sets in scan order
    for entry in eq:
        r1 = find(entry[0])
        for nj in entry[1:]:
            r2 = find(nj)
            if r2 != r1:
                parent[max(r1, r2)] = min(r1, r2)
                r1 = min(r1, r2)
    # merge pass: child features fold into roots, ascending label order
    roots = []
    for i in range(1, alloc):
        r = find(i)
        if r == i:
            roots.append(i)
        else:
            fr, fc = feat[r], feat[i]
            fr[0] += fc[0]
            fr[1] += fc[1]
            fr[2] += fc[2]
            fr[3] = min(fr[3], fc[3])
            fr[4] = max(fr[4], fc[4])
            fr[5] = min(fr[5], fc[5])
            fr[6] = max(fr[6], fc[6])
    regions = [(i,) + tuple(feat[i]) for i in roots]       # ascending roots
    summary = dict(nregions=len(roots), nalloc=alloc - 1,
                   ovf_lbl=ovf_lbl, ovf_eq=ovf_eq)
    return regions, summary


def pack_region(label, feat):
    """Region beat word: {label, area, sumX, sumY, minX, maxX, minY, maxY}
    with the same MSB->LSB order as the RTL result stream."""
    area, sx, sy, minx, maxx, miny, maxy = feat
    return (area, sx, sy, minx, maxx, miny, maxy, label)  # LSB last in tuple


def pack_expected(regions, summary, xw, yw, aw, sw, lblw):
    """Pack emitted beats exactly as the RTL result stream emits them:
    N region beats (tuser=0,tlast=0) then one summary beat (tuser=1,tlast=1).
    Returns list of (tuser, tlast, tdata)."""
    beats = []
    for label, area, sx, sy, minx, maxx, miny, maxy in regions:
        word = label
        word = (word << aw) | area
        word = (word << sw) | sx
        word = (word << sw) | sy
        word = (word << xw) | minx
        word = (word << xw) | maxx
        word = (word << yw) | miny
        word = (word << yw) | maxy
        beats.append((0, 0, word))
    summ = ((summary['ovf_lbl'] & 1) << (2 * lblw)
            | (summary['ovf_eq'] & 1) << (2 * lblw + 1)
            | (summary.get('oerr', 0) & 1) << (2 * lblw + 2)
            | (summary['nalloc'] & ((1 << lblw) - 1)) << lblw
            | (summary['nregions'] & ((1 << lblw) - 1)))
    beats.append((1, 1, summ))
    return beats


def widths(wmax=256, hmax=256, nl=NL):
    """(xw, yw, aw, sw, lblw) matching the RTL localparam derivation."""
    import math
    xw = max(1, (wmax - 1).bit_length()) if wmax > 1 else 1
    yw = max(1, (hmax - 1).bit_length()) if hmax > 1 else 1
    lblw = (nl + 1).bit_length()         # clog2(NL+2)
    aw = (wmax * hmax).bit_length()      # clog2(W*H)+1
    sw = aw + xw
    return xw, yw, aw, sw, lblw
