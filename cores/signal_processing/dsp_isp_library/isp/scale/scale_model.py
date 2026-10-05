"""Bit-exact golden model for scale_poly6_stream.

Mirrors the RTL exactly:
  step = (in_dim*65536 + out_dim//2) // out_dim          (Q16.16)
  c(0) = (step - 65536) >> 1 ; c(n+1) = c(n) + step    (arithmetic shift)
  base = c >> 16 ; frac = c & 0xFFFF ; phase = frac >> 10
  taps at positions base-2 .. base+3, clamped to [0, in_dim-1]
  vertical:  u8 * s13 coefs -> acc; intermediate = clamp((acc+64)>>7, 0, 4095)
  horizontal: u12 * s13 coefs -> acc; output = clamp((acc+16384)>>15, 0, 255)
"""
import json, pathlib

_COEF = json.loads((pathlib.Path(__file__).resolve().parent /
                    'scale_coeffs.json').read_text())
TABLE = _COEF["table"]


def step_q16(src, dst):
    return (src * 65536 + dst // 2) // dst


def _taps(c, n):
    base = c >> 16
    ph = (c & 0xFFFF) >> 10
    idx = [min(max(base - 2 + t, 0), n - 1) for t in range(6)]
    return idx, TABLE[ph]


def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def vfilter(pix, in_w, in_h, out_h, sy):
    """Vertical stage: returns intermediate[out_h][in_w][3] of 12-bit."""
    out = []
    cy = (sy - 65536) >> 1
    for _oy in range(out_h):
        idx, coef = _taps(cy, in_h)
        row = []
        for x in range(in_w):
            px = []
            for ch in range(3):
                acc = sum(pix[idx[t]][x][ch] * coef[t] for t in range(6))
                px.append(_clamp((acc + 64) >> 7, 0, 4095))
            row.append(tuple(px))
        out.append(row)
        cy += sy
    return out


def hfilter(interm, in_w, out_w, sx):
    """Horizontal stage: returns output[out_h][out_w][3] of 8-bit."""
    out = []
    for row in interm:
        cx = (sx - 65536) >> 1
        orow = []
        for _ox in range(out_w):
            idx, coef = _taps(cx, in_w)
            px = []
            for ch in range(3):
                acc = sum(row[idx[t]][ch] * coef[t] for t in range(6))
                px.append(_clamp((acc + 16384) >> 15, 0, 255))
            orow.append(tuple(px))
            cx += sx
        out.append(orow)
    return out


def scale_frame(frame, in_w, in_h, out_w, out_h):
    """frame: list[in_h][in_w] of (r,g,b). Returns list[out_h][out_w]."""
    sx = step_q16(in_w, out_w)
    sy = step_q16(in_h, out_h)
    return hfilter(vfilter(frame, in_w, in_h, out_h, sy), in_w, out_w, sx)


def pack(pixel):
    return (pixel[0] << 16) | (pixel[1] << 8) | pixel[2]
