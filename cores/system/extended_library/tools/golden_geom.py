#!/usr/bin/env python3
# ============================================================================
# golden_geom.py -- independent golden model for wave2 group-D geometry /
# statistics / matching units (idx15..19).  Replicates w2_img_stim.v pixel
# formula verbatim and each unit's documented algorithm; writes one
# sim/golden_<unit>.txt (one hex byte per line = the byte stream the RTL
# folds into its FNV-1a digest) and prints "<TAG> DIGEST=XXXXXXXX".
#
# Units:
#   SCL img_scaler     bilinear rescale, Q8 src pos, truncating map src=dst*IN/OUT
#                      two scenarios in one digest: 32x32->16x16 then 16x16->32x32
#   HST img_histogram  256-bin frame histogram, drains count[7:0],count[15:8]
#   CLA hist_clahe     4x4 tiles of 8x8, 16-bin clipped hist -> CDF LUT ->
#                      bilinear blend of 4 nearest tile mappings (fx/fy 3-bit)
#   SAD match_sad      8x8 template SAD over 32x32 frame, per-candidate lo,hi
#                      then best_x,best_y,min_lo,min_hi
#   CRP img_crop       ROI streamer X0,Y0,CW,CH
# ============================================================================
import os, sys

IMG_W = 32
IMG_H = 32

# --------------------------------------------------------------------------
# w2_img_stim pixel formula (must match src/w2_img_stim.v verbatim):
#   base = (x + x<<4) ^ (y + y<<3 + y<<5) ^ ((x & y) << 3)      [mod 256]
#   boost: sx0=6+2f, sy0=5+f, x in [sx0,sx0+3], y in [sy0,sy0+5] -> +0x50
# Every 8-bit operand wraps mod 256 BEFORE the xor (Verilog 8-bit semantics).
# --------------------------------------------------------------------------
def fpix(x, y, f=0):
    base = ((x + ((x << 4) & 0xFF)) & 0xFF) ^ \
           ((y + ((y << 3) & 0xFF) + ((y << 5) & 0xFF)) & 0xFF) ^ \
           (((x & y) << 3) & 0xFF)
    sx0 = 6 + 2 * f
    sy0 = 5 + f
    if sx0 <= x <= sx0 + 3 and sy0 <= y <= sy0 + 5:
        return (base + 0x50) & 0xFF
    return base

def frame(w, h, f=0):
    return [[fpix(x, y, f) for x in range(w)] for y in range(h)]

def fnv(stream, h=0x811C9DC5):
    for b in stream:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h

def write_golden(unit, stream):
    path = os.path.join(os.path.dirname(__file__), "..", "sim",
                        "golden_%s.txt" % unit)
    path = os.path.normpath(path)
    with open(path, "w") as fp:
        for b in stream:
            fp.write("%02x\n" % (b & 0xFF))
    return path

# ==========================================================================
# idx15 SCL img_scaler
#   STX = (IMG_W*256)//OUT_W ; sx_q8 = ox*STX ; xi=sx>>8 ; fx=sx&255
#   xi2 = min(xi+1, IMG_W-1)
#   top = (a<<8) + (b-a)*fx ; bot = (c<<8) + (d-c)*fx          [Q8 image]
#   res = (top<<8) + (bot-top)*fy                              [Q16 image]
#   out = clamp((res + 0x8000) >> 16, 0, 255)
# ==========================================================================
def scale_stream(img, iw, ih, ow, oh):
    stx = (iw * 256) // ow
    sty = (ih * 256) // oh
    out = []
    for oy in range(oh):
        sy = oy * sty
        yi = sy >> 8
        fy = sy & 0xFF
        yi2 = min(yi + 1, ih - 1)
        for ox in range(ow):
            sx = ox * stx
            xi = sx >> 8
            fx = sx & 0xFF
            xi2 = min(xi + 1, iw - 1)
            a = img[yi][xi];  b = img[yi][xi2]
            c = img[yi2][xi]; d = img[yi2][xi2]
            top = (a << 8) + (b - a) * fx
            bot = (c << 8) + (d - c) * fx
            res = (top << 8) + (bot - top) * fy
            o = (res + 0x8000) >> 16
            out.append(max(0, min(255, o)))
    return out

def gen_scaler():
    img_a = frame(32, 32)
    img_b = frame(16, 16)
    s = scale_stream(img_a, 32, 32, 16, 16) + \
        scale_stream(img_b, 16, 16, 32, 32)
    return "img_scaler", s

# ==========================================================================
# idx16 HST img_histogram
#   256 bins over 32x32 frame; drain bin 0..255 as count[7:0], count[15:8]
# ==========================================================================
def gen_histogram():
    img = frame(IMG_W, IMG_H)
    h = [0] * 256
    for y in range(IMG_H):
        for x in range(IMG_W):
            h[img[y][x]] += 1
    s = []
    for b in range(256):
        s.append(h[b] & 0xFF)
        s.append((h[b] >> 8) & 0xFF)
    return "img_histogram", s

# ==========================================================================
# idx17 CLA hist_clahe
#   32x32 -> 4x4 tiles of 8x8. Per tile t: 16-bin hist over p>>4,
#   clip h->min(h,CLIP), S=sum, cdf_i = sum_{k<=i},
#   LUT_t[i] = min(255, (cdf_i*255)//S)     (floor division)
#   Apply: per pixel, tile-centre bilinear:
#     x<4  -> ix0=ix1=0,fx=0 ; 4<=x<28 -> ix0=(x-4)>>3, ix1=ix0+1, fx=(x-4)&7
#     x>=28-> ix0=ix1=3,fx=0 ; same for y.
#   m_* = LUT_tile[p>>4]
#   top = (m00<<3)+(m01-m00)*fx ; bot = (m10<<3)+(m11-m10)*fx
#   res = (top<<3)+(bot-top)*fy ; out = clamp((res+32)>>6,0,255)
# ==========================================================================
CLIP = 8
def gen_clahe():
    img = frame(IMG_W, IMG_H)
    # build 16 LUTs of 16 entries
    luts = []
    for ty in range(4):
        for tx in range(4):
            h = [0] * 16
            for r in range(8):
                for c in range(8):
                    h[img[ty * 8 + r][tx * 8 + c] >> 4] += 1
            clip = [min(v, CLIP) for v in h]
            S = sum(clip)
            cdf = 0
            lut = []
            for i in range(16):
                cdf += clip[i]
                lut.append(min(255, (cdf * 255) // S))
            luts.append(lut)

    def tilepair(v):
        # returns (i0, i1, frac) for coordinate v in 0..31
        if v < 4:
            return 0, 0, 0
        if v >= 28:
            return 3, 3, 0
        i0 = (v - 4) >> 3
        return i0, i0 + 1, (v - 4) & 7

    s = []
    for y in range(IMG_H):
        iy0, iy1, fy = tilepair(y)
        for x in range(IMG_W):
            ix0, ix1, fx = tilepair(x)
            b = img[y][x] >> 4
            m00 = luts[iy0 * 4 + ix0][b]
            m01 = luts[iy0 * 4 + ix1][b]
            m10 = luts[iy1 * 4 + ix0][b]
            m11 = luts[iy1 * 4 + ix1][b]
            top = (m00 << 3) + (m01 - m00) * fx
            bot = (m10 << 3) + (m11 - m10) * fx
            res = (top << 3) + (bot - top) * fy
            s.append(max(0, min(255, (res + 32) >> 6)))
    return "hist_clahe", s

# ==========================================================================
# idx18 SAD match_sad
#   template T[r][c] = fpix(10+c, 9+r)   (exact patch -> SAD=0 at (10,9))
#   candidates (y,x) in [0,24]^2 row-major; sad = sum |I[y+r][x+c]-T[r][c]|
#   emit per candidate: sad&0xFF, (sad>>8)&0xFF ; min: strict < (first wins)
#   then emit best_x, best_y, min&0xFF, (min>>8)&0xFF
# ==========================================================================
SAD_TX = 10
SAD_TY = 9
def gen_sad():
    img = frame(IMG_W, IMG_H)
    tpl = [[fpix(SAD_TX + c, SAD_TY + r, 0) for c in range(8)]
           for r in range(8)]
    s = []
    best = None
    for y in range(IMG_W - 7):        # 25
        for x in range(IMG_W - 7):
            sad = 0
            for r in range(8):
                for c in range(8):
                    sad += abs(img[y + r][x + c] - tpl[r][c])
            s.append(sad & 0xFF)
            s.append((sad >> 8) & 0xFF)
            if best is None or sad < best[2]:
                best = (x, y, sad)
    s += [best[0], best[1], best[2] & 0xFF, (best[2] >> 8) & 0xFF]
    sys.stderr.write("SAD best=(%d,%d) min=%d\n" % best)
    return "match_sad", s

# ==========================================================================
# idx19 CRP img_crop   X0=5, Y0=7, CW=13, CH=9 over 32x32
# ==========================================================================
CRP_X0, CRP_Y0, CRP_CW, CRP_CH = 5, 7, 13, 9
def gen_crop():
    img = frame(IMG_W, IMG_H)
    s = []
    for y in range(IMG_H):
        for x in range(IMG_W):
            if CRP_X0 <= x < CRP_X0 + CRP_CW and \
               CRP_Y0 <= y < CRP_Y0 + CRP_CH:
                s.append(img[y][x])
    return "img_crop", s

# ==========================================================================
def main():
    units = [gen_scaler, gen_histogram, gen_clahe, gen_sad, gen_crop]
    for g in units:
        name, s = g()
        write_golden(name, s)
        print("%s DIGEST=%08X N=%d" % (name.split("_")[1].upper()[:3]
              if False else
              {"img_scaler": "SCL", "img_histogram": "HST", "hist_clahe": "CLA",
               "match_sad": "SAD", "img_crop": "CRP"}[name],
              fnv(s), len(s)))

if __name__ == "__main__":
    main()
