"""Video / display-path kernels: one packed pixel group per accepted beat.

Family file for the accelerator catalog.  Every core here retires a whole
pixel group (2 or 4 pixels, one macropixel, one 20-bit serializer lane or one
pixel clock) per accepted beat at II=1, so colour-matrix, subsampling, keying,
blending, plot and timing work never pays a per-pixel instruction loop or a
frame-buffer round trip.

Body vocabulary supplied by the template (reset each evaluation):
    r x                       result/aux registers, 32 bit
    f                         fault flag
    temp mask pa pb pc ph pl  32-bit unsigned temporaries
    ext                       33-bit unsigned (carry / small accumulator)
    wide wide2                64-bit unsigned
    swide swide2              64-bit signed
    sa sb sc                  $signed(a), $signed(b), $signed(c)
    data                      {a,b,c} as one 96-bit word
    i j idx lane sh           integers
    state_r state_n           256-bit state; only accepted beats commit it

Arithmetic honesty: no body contains `*` or `/`, and no multiplier or divider
is inferred.  Every BT.709 coefficient is derived at import time from the
published chromaticities with exact Fractions and then expanded into a
canonical-signed-digit shift-add network, so the RTL text contains only the
shifts and adds that arithmetic means.  The divide by 255 of the OSD blender is
the exact fold floor(x/255) = (x>>8) + [(x>>8)+(x&255) >= 255] + [... >= 510],
verified exhaustively over all 16-bit x in selftest(); the divide by 2 of the
chroma decimator is a shift.  Nothing is a lookup stand-in for arithmetic
except the 16-entry sprite palette, which is a table by nature and is generated
once by tables(name).
"""
from fractions import Fraction as F
from random import Random

FAMILY = 'video'
MASK = (1 << 32) - 1
BOARD_ROWS = 128

CORES = []


def core(name, spec, body, advantage, lanes, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body,
                      advantage=advantage, lanes=lanes, latency=1, **kwargs))


def custom(name, spec, module, advantage, lanes, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, module=module,
                      advantage=advantage, lanes=lanes, **kwargs))


# ==========================================================================
# BT.709 derivation.  ITU-R BT.709-6 Table 2 chromaticities:
#   R(0.640,0.330) G(0.300,0.600) B(0.150,0.060), D65 white (0.3127,0.3290).
# The luma coefficients are the RGB->Y row of the primary/white-point solve
# M * S = W with rows [x/y, 1, (1-x-y)/y], so they are computed, not typed.
# ==========================================================================
PRIMARIES = ((F(640, 1000), F(330, 1000)),
             (F(300, 1000), F(600, 1000)),
             (F(150, 1000), F(60, 1000)))
WHITE_XY = (F(3127, 10000), F(3290, 10000))


def _det(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))


def _luma_coefficients():
    """Solve M * S = (xw/yw, 1, zw/yw) for the three primary scalings."""
    xy, yz = WHITE_XY
    w = [xy / yz, F(1), (F(1) - xy - yz) / yz]
    m = [[p[0] / p[1] for p in PRIMARIES],
         [F(1), F(1), F(1)],
         [(F(1) - p[0] - p[1]) / p[1] for p in PRIMARIES]]
    d = _det(m)
    out = []
    for j in range(3):
        mj = [row[:] for row in m]
        for i in range(3):
            mj[i][j] = w[i]
        out.append(_det(mj) / d)
    return out


KR, KG, KB = _luma_coefficients()
assert KR + KG + KB == 1

# Studio-range code weights in Q10 on 8-bit codes: Y spans 16..235 (219 codes)
# and each chroma channel spans 16..240 (224 codes) about the 128 footpoint.
QSH = 10
QONE = 1 << QSH
HALF = QONE >> 1
QSUM = 12                  # the four-pixel group mean is taken in Q12
HALFS = 1 << (QSUM - 1)


def _q(value):
    return round(float(value) * QONE)


Kb2 = F(224, 255)
Y_W = (_q(F(219) * KR / F(255)), _q(F(219) * KG / F(255)), _q(F(219) * KB / F(255)))
CB_W = (_q(Kb2 * (-KR / (2 * (1 - KB)))), _q(Kb2 * (-KG / (2 * (1 - KB)))), _q(Kb2 * F(1, 2)))
CR_W = (_q(Kb2 * F(1, 2)), _q(Kb2 * (-KG / (2 * (1 - KR)))), _q(Kb2 * (-KB / (2 * (1 - KR)))))
assert sum(CB_W) == 0 and sum(CR_W) == 0          # grey is exactly (128, 128)

# Inverse studio matrix, Q10, applied to (Y-16, Cb-128, Cr-128).
_GY = F(255, 219)
INV_W = ((_q(_GY), 0, _q(F(255) * 2 * (1 - KR) / F(224))),
         (_q(_GY), _q(-F(255) * 2 * KB * (1 - KB) / (F(224) * KG)),
          _q(-F(255) * 2 * KR * (1 - KR) / (F(224) * KG))),
         (_q(_GY), _q(F(255) * 2 * (1 - KB) / F(224)), 0))
WL = INV_W[0][0]                      # the luma weight shared by all rows
INV_BIAS = [128 * (w[1] + w[2]) for w in INV_W]   # folded chroma footpoint

Y_LIMITS = (16, 235)
C_LIMITS = (16, 240)


# Exact rational studio encoders, used by selftest() as the reference oracle.
def exact_yrgb(r, g, b):
    y = (KR * r + KG * g + KB * b) / F(255)
    return (F(16) + F(219) * y,
            F(128) + F(224) * (F(b, 255) - y) / (2 * (1 - KB)),
            F(128) + F(224) * (F(r, 255) - y) / (2 * (1 - KR)))


def exact_rgb(y, cb, cr):
    yy = F(int(y) - 16, 219)
    return [255 * (yy + 2 * (1 - KR) * F(int(cr) - 128, 224)),
            255 * (yy - 2 * KR * (1 - KR) / KG * F(int(cr) - 128, 224)
                   - 2 * KB * (1 - KB) / KG * F(int(cb) - 128, 224)),
            255 * (yy + 2 * (1 - KB) * F(int(cb) - 128, 224))]


def _naf(weight):
    """Canonical signed digits of an integer weight as (shift, +/-1) pairs."""
    out, n, sh = [], abs(weight), 0
    while n:
        if n & 1:
            d = 1 if (n & 3) == 1 else -1
            out.append((sh, d))
            n -= d
        n >>= 1
        sh += 1
    if weight < 0:
        out = [(s, -d) for s, d in out]
    return out


def _terms(weights, vars_):
    """Shift-add Verilog text for sum(weights[i] * vars_[i])."""
    text = ''
    for w, v in zip(weights, vars_):
        for sh, d in _naf(w):
            text += (' + ' if d > 0 else ' - ') + '(' + v + '<<' + str(sh) + ')'
    return text


def _csd_value(weight, value):
    """The value the shift-add network actually computes."""
    total = 0
    for sh, d in _naf(weight):
        total += d * (value << sh)
    return total


def _net(weights, values):
    """Evaluate the emitted shift-add cone, not the abstract dot product.

    The models go through _csd_value so a wrong canonical-signed-digit
    expansion shows up as a model/RTL disagreement instead of hiding behind
    Python's own multiply.
    """
    return sum(_csd_value(w, v) for w, v in zip(weights, values))


def byte_of(value, index):
    return (value >> (8 * index)) & 0xFF


def pack4(values):
    return sum((v & 0xFF) << (8 * k) for k, v in enumerate(values))


def dot(weights, values):
    return sum(w * v for w, v in zip(weights, values))


def fold255(x):
    """floor(x/255) for 0 <= x <= 65535 using only a shift, a mask and tests."""
    h, l = x >> 8, x & 0xFF
    return h + (1 if h + l >= 255 else 0) + (1 if h + l >= 510 else 0)


def sdiv255(t):
    """floor(t/255) for -64898 <= t <= 65152; the signed wrapper of fold255."""
    return fold255(t) if t >= 0 else -fold255(-t + 254)


def _const(v):
    return ' + 64\'sd' + str(v) if v >= 0 else ' - 64\'sd' + str(-v)


def _field(v, low, bits):
    return (v >> low) & ((1 << bits) - 1)


def _set_field(v, low, bits, value):
    return (v & ~(((1 << bits) - 1) << low)) | ((value & ((1 << bits) - 1)) << low)


# ==========================================================================
# 1. BT.709 RGB -> YCbCr, four pixels per beat.
# ==========================================================================
BODY1 = (
    "pa={24'd0,a[7:0]}+{24'd0,a[15:8]}+{24'd0,a[23:16]}+{24'd0,a[31:24]};\n"
    "pb={24'd0,b[7:0]}+{24'd0,b[15:8]}+{24'd0,b[23:16]}+{24'd0,b[31:24]};\n"
    "pc={24'd0,c[7:0]}+{24'd0,c[15:8]}+{24'd0,c[23:16]}+{24'd0,c[31:24]};\n"
    # group luma mean: the same Q10 weights on the four-pixel sums, Q12 result
    "swide=64'sd0" + _terms(Y_W, ('pa', 'pb', 'pc'))
    + _const(16 * (1 << QSUM)) + " + 64'sd" + str(HALFS) + ";\n"
    "mask=(swide>>>" + str(QSUM) + ");\n"
    # 4:1:1 site chroma from the sums: the matrix is affine, so this is the
    # chroma of the four-pixel mean, which is exactly what 4:1:1 asks for.
    "swide=64'sd0" + _terms(CB_W, ('pa', 'pb', 'pc'))
    + _const(128 * (1 << QSUM)) + " + 64'sd" + str(HALFS) + ";\n"
    "temp=(swide>>>" + str(QSUM) + ");\n"
    "if(temp<32'd16 || temp>32'd240) begin\n"
    "    if(temp<32'd16) temp=32'd16; else temp=32'd240; x[31]=1'b1;\n"
    "end\n"
    "x[7:0]=temp[7:0];\n"
    "x[29]=(temp==32'd16) || (temp==32'd240);\n"
    "swide=64'sd0" + _terms(CR_W, ('pa', 'pb', 'pc'))
    + _const(128 * (1 << QSUM)) + " + 64'sd" + str(HALFS) + ";\n"
    "temp=(swide>>>" + str(QSUM) + ");\n"
    "if(temp<32'd16 || temp>32'd240) begin\n"
    "    if(temp<32'd16) temp=32'd16; else temp=32'd240; x[31]=1'b1;\n"
    "end\n"
    "x[15:8]=temp[7:0];\n"
    "x[30]=(temp==32'd16) || (temp==32'd240);\n"
    "for(lane=0;lane<4;lane=lane+1) begin\n"
    "    ph={24'd0,a[(lane<<3)+:8]};\n"
    "    pl={24'd0,b[(lane<<3)+:8]};\n"
    "    pc={24'd0,c[(lane<<3)+:8]};\n"
    "    swide=64'sd0" + _terms(Y_W, ('ph', 'pl', 'pc')) + _const(16 * QONE) + ";\n"
    "    if((swide & 64'sd" + str(QONE - 1) + ") >= 64'sd" + str(HALF)
    + ") x[16+lane]=1'b1;\n"
    "    swide2=(swide + 64'sd" + str(HALF) + ")>>>" + str(QSH) + ";\n"
    "    temp=swide2[31:0];\n"
    "    if(temp<32'd16 || temp>32'd235) begin\n"
    "        if(temp<32'd16) temp=32'd16; else temp=32'd235; x[31]=1'b1;\n"
    "    end\n"
    "    r[(lane<<3)+:8]=temp[7:0];\n"
    "    if(temp==32'd16 || temp==32'd235) x[28]=1'b1;\n"
    "    if(ph==pl && pl==pc) x[24+lane]=1'b1;\n"
    "    ext=(mask>temp) ? (mask-temp) : (temp-mask);\n"
    "    if(ext>=33'd8) x[20+lane]=1'b1;\n"
    "end\n"
)

core('rgb2yuv709',
    'BT.709 luma plus 4:1:1 site chroma for four packed pixels per beat. '
    'Lane packing: pixel k is (a[8k+:8], b[8k+:8], c[8k+:8]) = (R,G,B), so '
    'a = the red plane byte for pixels 0..3, b = green, c = blue. Every '
    'coefficient is the Q10 fixed point derived from the BT.709-6 chromaticities '
    '(Kr=0.2126, Kg=0.7152, Kb=0.0722) and expanded into canonical-signed-digit '
    'shifts and adds. result[8k+:8] = Y_k = clamp(round(16 + (187R+629G+63B)/'
    '1024), 16, 235). aux[7:0] and aux[15:8] are the 4:1:1 site Cb and Cr, '
    'computed from the four-pixel sums with the studio chroma weights '
    '(-103,-347,450) and (450,-409,-41) and clamped to 16..240; because the '
    'matrix is affine this is exactly the chroma of the four-pixel mean. '
    'aux[19:16] = per-lane luma rounded up, aux[23:20] = per-lane clip flags '
    '(|Y_k - group luma| >= 8, i.e. shared chroma clipped over luma detail), '
    'aux[27:24] = per-lane achromatic (R==G==B), aux[28] = a luma code sits on '
    'the 16/235 window edge, aux[29]/aux[30] = site Cb/Cr sits on the 16/240 '
    'edge, aux[31] = a gamut clamp bit actually fired. No fault condition: any '
    'three 8-bit planes are a legal colour, and over the RGB cube the studio '
    'windows are provably never exceeded, so aux[31] is a structural safety net. '
    'Stateless.',
    BODY1,
    'A scalar colour conversion pays three multiply-accumulates, a rounding add, '
    'a clamp and a chroma subsample filter per pixel; this cone converts four '
    'pixels and their shared chroma site in one enabled beat at II=1 and hands '
    'the rounding, clipping and achromatic status out beside the codes.',
    4, faultless=True)


def _m_rgb2yuv(a, b, c, state):
    """Exact model of BODY1: per-lane luma plus the 4:1:1 site chroma.

    Every arithmetic step mirrors the emitted cone: the Q10 group sums, the
    canonical-signed-digit network through _csd_value, the +1/2 LSB before the
    arithmetic shift, the studio-window clamps and the status bits in the order
    the RTL writes them.
    """
    planes = [sum(byte_of(v, k) for k in range(4)) for v in (a, b, c)]
    group = (_net(Y_W, planes) + (16 << QSUM) + HALFS) >> QSUM
    r = x = 0
    for weights, slot, edge_bit in ((CB_W, 0, 29), (CR_W, 1, 30)):
        value = (_net(weights, planes) + (128 << QSUM) + HALFS) >> QSUM
        value, clamped = _clamp_code(value, C_LIMITS[0], C_LIMITS[1])
        x |= (value & 0xFF) << (8 * slot)
        if clamped:
            x |= 1 << 31
        if value in C_LIMITS:
            x |= 1 << edge_bit
    for k in range(4):
        pixel = (byte_of(a, k), byte_of(b, k), byte_of(c, k))
        acc = _net(Y_W, pixel) + 16 * QONE
        if (acc & (QONE - 1)) >= HALF:
            x |= 1 << (16 + k)                        # this lane's LSB rounded up
        value, clamped = _clamp_code((acc + HALF) >> QSH, Y_LIMITS[0], Y_LIMITS[1])
        if clamped:
            x |= 1 << 31
        r |= value << (8 * k)
        if value in Y_LIMITS:
            x |= 1 << 28
        if pixel[0] == pixel[1] == pixel[2]:
            x |= 1 << (24 + k)
        if abs(group - value) >= 8:
            x |= 1 << (20 + k)                        # chroma clip over luma detail
    return r & MASK, x & MASK, 0, state


def _clamp_code(value, lo, hi):
    """The shared two-branch studio clamp: returns (clamped, fired)."""
    if value < lo or value > hi:
        return (lo if value < lo else hi), 1
    return value, 0


# ==========================================================================
# 2. BT.709 YCbCr -> RGB, two pixels per beat: six output colour bytes plus the
# status word exactly fill result+aux, so four pixels would not fit.
# ==========================================================================
def _inv_pixel(ys, cbs, crs, outs, bits):
    """Shift-add text for one pixel's inverse matrix.

    ys/cbs/crs are Verilog source expressions; outs are the three 8-bit
    destinations; bits is the base aux bit for this pixel's status flags
    (clamp, round-up, out-of-window, achromatic, neutral chroma).
    """
    cl, ru, oow, ach, neu = bits
    t = ("    swide=64'sd0" + _terms((WL,), (ys,))
         + _const(-WL * 16 + HALF) + ";\n")            # shared WL*(Y-16)+1/2 LSB
    t += ("    if(" + ys + "<32'd16 || " + ys + ">32'd235 || " + cbs + "<32'd16 || "
          + cbs + ">32'd240 || " + crs + "<32'd16 || " + crs + ">32'd240) x["
          + str(oow) + "]=1'b1;\n")
    t += "    if(" + cbs + "==32'd128 && " + crs + "==32'd128) x[" + str(neu) + "]=1'b1;\n"
    for ch in range(3):
        wcb, wcr = INV_W[ch][1], INV_W[ch][2]
        expr = "    swide2=swide"
        if wcb:
            expr += _terms((wcb,), (cbs,))
        if wcr:
            expr += _terms((wcr,), (crs,))
        expr += _const(-INV_BIAS[ch]) + ";\n"
        expr += ("    if((swide2 & 64'sd1023) < 64'sd512) x[" + str(ru) + "]=1'b1;\n")
        expr += "    swide2=(swide2>>>10);\n"
        expr += ("    if(swide2<64'sd0) begin " + outs[ch] + "=8'd0; x[" + str(cl)
                 + "]=1'b1; end\n")
        expr += ("    else if(swide2>64'sd255) begin " + outs[ch] + "=8'd255; x["
                 + str(cl) + "]=1'b1; end\n")
        expr += "    else " + outs[ch] + "=swide2[7:0];\n"
        t += expr                                       # the channel cone is the core
    t += ("    if(" + outs[0] + "==" + outs[1] + " && " + outs[1] + "==" + outs[2]
          + ") x[" + str(ach) + "]=1'b1;\n")
    return t


BODY2 = (
    "if(b[31:16]!=0 || c!=0) f=1'b1;\n"
    "else begin\n"
    + _inv_pixel('a[7:0]', 'a[15:8]', 'a[23:16]',
                 ('r[7:0]', 'r[15:8]', 'r[23:16]'), (16, 17, 24, 20, 22))
    + _inv_pixel('a[31:24]', 'b[7:0]', 'b[15:8]',
                 ('r[31:24]', 'x[7:0]', 'x[15:8]'), (18, 19, 25, 21, 23))
    + "end\n"
)

core('yuv2rgb709',
    'BT.709 inverse colour matrix, two pixels per beat. Pixel 0 = '
    '(Y,Cb,Cr) = (a[7:0], a[15:8], a[23:16]), pixel 1 = (a[31:24], b[7:0], '
    'b[15:8]); b[31:16] and all of c are reserved and must read zero, otherwise '
    'result=aux=0 and fault=1. The three channel rows are the exact inverse of '
    'the studio encoder above, derived from the same chromaticities in Q10: '
    'R = (1192*(Y-16) + 1836*(Cr-128))/1024, G = (1192*(Y-16) - 218*(Cb-128) - '
    '546*(Cr-128))/1024, B = (1192*(Y-16) + 2163*(Cb-128))/1024, each rounded '
    'once and clamped to 0..255, with the shared 1192*(Y-16) term evaluated '
    'once per pixel and the chroma footpoint folded into the constant. '
    'result[7:0..23:16]=R0,G0,B0 and result[31:24]=R1; aux[7:0],aux[15:8]=G1,B1 '
    'so a full pixel pair leaves in one beat. aux[16]=pixel 0 clamped, '
    'aux[17]=pixel 0 rounded up, aux[18]/aux[19] the same for pixel 1, '
    'aux[20]/aux[21]=pixel 0/1 is achromatic, aux[22]/aux[23]=pixel 0/1 carries '
    'neutral chroma (Cb=Cr=128), aux[24]/aux[25]=pixel 0/1 code was outside the '
    'studio windows 16..235 / 16..240 on input. Stateless.',
    BODY2,
    'The display side of a video path converts two pixels per beat from one '
    'shared luma term; a scalar core pays six multiply-accumulates, six clamps '
    'and the studio-window expansion per pixel pair and cannot overlap them '
    'with the fetch of the next pair.',
    2)


def _inv_row(y, cb, cr, channel):
    """One inverse-matrix channel of BODY2, mirroring its cone exactly.

    Returns (8-bit byte, clamped, rounded-up).  The shared 1192*(Y-16)+1/2 LSB
    term is rebuilt per call so the model stays a faithful transcription of the
    RTL, which evaluates it once per pixel and adds the chroma rows to it.
    """
    base = _net((WL,), (y,)) - WL * 16 + HALF
    acc = base
    if INV_W[channel][1]:
        acc += _csd_value(INV_W[channel][1], cb)
    if INV_W[channel][2]:
        acc += _csd_value(INV_W[channel][2], cr)
    acc -= INV_BIAS[channel]
    rounded_up = (acc & (QONE - 1)) < HALF            # the folded +1/2 LSB carried
    value = acc >> QSH                                # arithmetic shift, as in RTL
    if value < 0:
        return 0, 1, rounded_up
    if value > 255:
        return 255, 1, rounded_up
    return value, 0, rounded_up


def _m_yuv2rgb(a, b, c, state):
    """Exact model of BODY2: two pixels out of one shared luma term each."""
    if (b >> 16) or c:
        return 0, 0, 1, state
    r = x = 0
    pixel0 = (byte_of(a, 0), byte_of(a, 1), byte_of(a, 2))
    pixel1 = (byte_of(a, 3), byte_of(b, 0), byte_of(b, 1))
    for slot, (pixel, cl_bit, ru_bit, oow_bit, ach_bit, neu_bit) in enumerate(
            ((pixel0, 16, 17, 24, 20, 22), (pixel1, 18, 19, 25, 21, 23))):
        y, cb, cr = pixel
        if not (Y_LIMITS[0] <= y <= Y_LIMITS[1]):
            x |= 1 << oow_bit
        if not (C_LIMITS[0] <= cb <= C_LIMITS[1]) or not (C_LIMITS[0] <= cr <= C_LIMITS[1]):
            x |= 1 << oow_bit
        if cb == 128 and cr == 128:
            x |= 1 << neu_bit
        bytes_out = []
        for channel in range(3):
            value, clamped, rounded_up = _inv_row(y, cb, cr, channel)
            bytes_out.append(value)
            if clamped:
                x |= 1 << cl_bit
            if rounded_up:
                x |= 1 << ru_bit
        if bytes_out[0] == bytes_out[1] == bytes_out[2]:
            x |= 1 << ach_bit
        if slot == 0:                                 # pixel 0 fits result[23:0]
            r |= bytes_out[0] | (bytes_out[1] << 8) | (bytes_out[2] << 16)
        else:                                         # pixel 1 spills into aux
            r |= bytes_out[0] << 24
            x |= bytes_out[1] | (bytes_out[2] << 8)
    return r & MASK, x & MASK, 0, state


# ==========================================================================
# 3. 4:2:2 -> 4:2:0 block packer: one macropixel per beat, eight beats per
# 4x4 luma block, a whole 32x8 frame in BOARD_ROWS beats.
# ==========================================================================
PACK_W, PACK_H = 32, 8               # the packing window in luma pixels
BLK_X = PACK_W // 4                  # blocks per row (8)
BLK_Y = PACK_H // 4                  # block rows (2)

ST3_IDX, ST3_BX, ST3_BY = 0, 3, 7
ST3_CBC, ST3_CRC = 10, 26            # Cb slot k at +8*k, Cr slot k at +8*k
ST3_FRAME = 43


def _m420pack(a, b, c, state):
    if (b >> 1) or (c & 0x7FFFFFFE):
        return 0, 0, 1, state
    restart = bool(c >> 31)
    st = 0 if restart else state
    idx = _field(st, ST3_IDX, 3)
    lane = (idx >> 1) & 1
    sh = idx & 1
    if (b & 1) != lane:                       # odd field: beat rejected
        return 0, 0, 1, (0 if restart else state)
    bx = _field(st, ST3_BX, 4)
    by = _field(st, ST3_BY, 3)
    # The RTL increments the pre-restart frame counter (state_r[43+:8]+1), so a
    # restart that lands on a frame-complete beat continues the count instead of
    # restarting it; the model mirrors that exactly.
    frames = _field(state, ST3_FRAME, 8)
    new = st
    r = byte_of(a, 0) | (byte_of(a, 1) << 8)
    x = idx | (lane << 3)
    cb = byte_of(a, 1)
    cr = byte_of(a, 3)
    if cb < C_LIMITS[0] or cb > C_LIMITS[1] or cr < C_LIMITS[0] or cr > C_LIMITS[1]:
        x |= 1 << 27
    if byte_of(a, 0) == byte_of(a, 1):
        x |= 1 << 28
    if bx == BLK_X - 1:
        x |= 1 << 30
    if by == BLK_Y - 1:
        x |= 1 << 29
    if idx not in (3, 7):
        x |= 1 << 31                          # the accumulator holds pending chroma
    if lane == 0:
        new = _set_field(new, ST3_CBC + 8 * sh, 8, cb)
        new = _set_field(new, ST3_CRC + 8 * sh, 8, cr)
        x |= 1 << 4
    else:
        pcb = _field(st, ST3_CBC + 8 * sh, 8)
        pcr = _field(st, ST3_CRC + 8 * sh, 8)
        qb = (pcb + cb + 1) >> 1
        qr = (pcr + cr + 1) >> 1
        r |= (qb & 0xFF) << 16
        r |= (qr & 0xFF) << 24
        x |= 1 << 5
        if ((pcb + cb) & 1) or ((pcr + cr) & 1):
            x |= 1 << 25                      # the 2:1 average rounded up
        if qb != pcb or qr != pcr:
            x |= 1 << 26                      # decimation changed the value
        new = _set_field(new, ST3_CBC + 8 * sh, 8, 0)
        new = _set_field(new, ST3_CRC + 8 * sh, 8, 0)
    x |= (bx & 0xFF) << 8
    x |= (by & 0xFF) << 16
    if idx == 3 or idx == 7:
        x |= 1 << 6                           # row pair complete
    if idx == 7:
        x |= 1 << 7                           # block complete
        new = _set_field(new, ST3_IDX, 3, 0)
        if bx == BLK_X - 1:
            if by == BLK_Y - 1:
                x |= 1 << 24                  # frame complete
                new = _set_field(new, ST3_BY, 3, 0)
                new = _set_field(new, ST3_FRAME, 8, (frames + 1) & 0xFF)
            else:
                new = _set_field(new, ST3_BY, 3, by + 1)
            new = _set_field(new, ST3_BX, 4, 0)
        else:
            new = _set_field(new, ST3_BX, 4, bx + 1)
    else:
        new = _set_field(new, ST3_IDX, 3, idx + 1)
    return r, x, 0, new


BODY3 = (
    "if(b[31:1]!=0 || c[30:1]!=0) f=1'b1;\n"
    "else begin\n"
    "    if(c[31]) state_n=0;\n"
    "    idx=state_n[2:0];\n"
    "    lane=(idx>>1)&1;\n"
    "    sh=idx&1;\n"
    "    if(b[0]!=lane) begin\n"
    "        f=1'b1; r=0; x=0;\n"
    "        if(c[31]) state_n=0; else state_n=state_r;\n"
    "    end else begin\n"
    "        r[7:0]=a[7:0]; r[15:8]=a[15:8];\n"
    "        x[2:0]=idx; x[3]=lane;\n"
    "        if(a[15:8]<32'd16 || a[15:8]>32'd240 || a[31:24]<32'd16 ||\n"
    "           a[31:24]>32'd240) x[27]=1'b1;\n"
    "        if(a[7:0]==a[15:8]) x[28]=1'b1;\n"
    "        if(state_n[6:3]==4'd" + str(BLK_X - 1) + ") x[30]=1'b1;\n"
    "        if(state_n[9:7]==3'd" + str(BLK_Y - 1) + ") x[29]=1'b1;\n"
    "        if(idx!=32'd3 && idx!=32'd7) x[31]=1'b1;\n"
    "        if(lane==0) begin\n"
    "            state_n[10+(sh<<3) +: 8]=a[15:8];\n"
    "            state_n[26+(sh<<3) +: 8]=a[31:24];\n"
    "            x[4]=1'b1;\n"
    "        end else begin\n"
    "            pa={24'd0,state_r[10+(sh<<3) +: 8]}+{24'd0,a[15:8]}+32'd1;\n"
    "            pb={24'd0,state_r[26+(sh<<3) +: 8]}+{24'd0,a[31:24]}+32'd1;\n"
    "            r[23:16]=pa[8:1]; r[31:24]=pb[8:1];\n"
    "            x[5]=1'b1;\n"
    "            if(r[23:16]!=state_r[10+(sh<<3) +: 8] ||\n"
    "               r[31:24]!=state_r[26+(sh<<3) +: 8]) x[26]=1'b1;\n"
    "            pc={24'd0,state_r[10+(sh<<3) +: 8]}+{24'd0,a[15:8]};\n"
    "            ph={24'd0,state_r[26+(sh<<3) +: 8]}+{24'd0,a[31:24]};\n"
    "            if(pc[0] || ph[0]) x[25]=1'b1;\n"
    "            state_n[10+(sh<<3) +: 8]=8'd0;\n"
    "            state_n[26+(sh<<3) +: 8]=8'd0;\n"
    "        end\n"
    "        x[15:8]=state_n[6:3]; x[23:16]=state_n[9:7];\n"
    "        if(idx==32'd3 || idx==32'd7) x[6]=1'b1;\n"
    "        if(idx==32'd7) begin\n"
    "            x[7]=1'b1;\n"
    "            if(state_r[6:3]==4'd" + str(BLK_X - 1) + ") begin\n"
    "                if(state_r[9:7]==3'd" + str(BLK_Y - 1) + ") begin\n"
    "                    x[24]=1'b1;\n"
    "                    state_n[9:7]=0;\n"
    "                    state_n[43+:8]=state_r[43+:8]+8'd1;\n"
    "                end else state_n[9:7]=state_r[9:7]+3'd1;\n"
    "                state_n[6:3]=0;\n"
    "            end else state_n[6:3]=state_r[6:3]+4'd1;\n"
    "            state_n[2:0]=0;\n"
    "        end else state_n[2:0]=idx+32'd1;\n"
    "    end\n"
    "end\n"
)

core('yuv420_pack',
    '4:2:2 macropixels in, 4:2:0 samples out, one macropixel (two luma pixels '
    'plus its chroma pair) per accepted beat. Input byte order is YUYV: '
    'a = (Y0, Cb, Y1, Cr). The block is a fixed 4x4 luma window, so eight beats '
    'carry one block and a 32x8 luma frame is exactly 128 beats: 8 blocks wide, '
    '2 block rows. b[0] is the feeder-declared field parity of this row (0 = '
    'top row of a row pair, 1 = bottom) and must match the core counter; a '
    'mismatch is an odd-field fault (result=aux=0, a restart request is still '
    'honoured). b[31:1] and c[30:1] must be zero; c[31] restarts the packer at '
    'block (0,0) before this beat. State is the sub-sample accumulator: bits '
    '2:0 = beat index in the block, 6:3 = block column, 9:7 = block row, '
    '17:10 and 25:18 = the pending top-row Cb bytes of macropixel 0/1, 33:26 '
    'and 41:34 = the same for Cr, 50:43 = completed frames. On a top row the '
    'chroma is stored and result[31:16] reads 0; on a bottom row the quad '
    'commits and result[23:16], result[31:24] = (Cb_top + Cb_bot + 1) >> 1, '
    'round half up, exactly the MPEG-2 frame coding choice. result[7:0] and '
    'result[15:8] are the two luma bytes. aux[2:0] = beat index, aux[3] = row '
    'parity, aux[4] = chroma stored, aux[5] = chroma committed, aux[6] = row '
    'pair complete, aux[7] = block complete, aux[15:8] = block column, '
    'aux[23:16] = block row, aux[24] = frame complete, aux[25] = the average '
    'rounded up, aux[26] = the decimated chroma differs from the top row, '
    'aux[27] = this beat brought chroma outside 16..240, aux[28] = Y0==Y1, '
    'aux[29] = last block row, aux[30] = last block column, aux[31] = the '
    'accumulator still holds pending chroma.',
    BODY3,
    'Chroma decimation with field tracking is a read-modify-write of a line '
    'buffer plus a parity branch per macropixel in firmware; this core carries '
    'the whole sub-sample accumulator in registers and commits an averaged '
    '4:2:0 quad every enabled beat at II=1 with the block addressing beside it, '
    'never touching a frame buffer.',
    2, stateful=True)


# ==========================================================================
# 4. 4:2:2 unpack with a byte-lane phase in state.
# ==========================================================================
BODY4 = (
    "if(b!=0 || c[30:1]!=0) f=1'b1;\n"
    "else begin\n"
    "    if(c[31]) state_n=0; else state_n=state_r;\n"
    "    lane=state_n[0];\n"
    "    if(lane==0) begin\n"
    "        pa=a[7:0]; pb=a[15:8]; pc=a[23:16]; ph=a[31:24];\n"
    "    end else begin\n"
    "        pa=a[15:8]; pb=a[7:0]; pc=a[31:24]; ph=a[23:16];\n"
    "    end\n"
    "    if(pb<32'd16 || pb>32'd240 || ph<32'd16 || ph>32'd240) begin\n"
    "        f=1'b1; r=0; x=0; state_n=state_r;\n"
    "    end else begin\n"
    "        r[7:0]=pa; r[15:8]=pb; r[23:16]=ph; r[31:24]=pc;\n"
    "        x[7:0]=pb; x[15:8]=ph;\n"
    "        x[23:16]=state_n[7:1];\n"
    "        x[24]=lane;\n"
    "        x[25]=(pa==pc);\n"
    "        x[26]=(pb==32'd128 && ph==32'd128);\n"
    "        x[27]=(pa<32'd16 || pa>32'd235 || pc<32'd16 || pc>32'd235);\n"
    "        x[28]=(pb==32'd16 || pb==32'd240);\n"
    "        x[29]=(ph==32'd16 || ph==32'd240);\n"
    "        if(state_r[7:1]==7'd127) x[30]=1'b1;\n"
    "        if(c[31]) x[31]=1'b1;\n"
    "        if(state_n[7:1]==7'd127) state_n[7:1]=0;\n"
    "        else state_n[7:1]=state_n[7:1]+7'd1;\n"
    "        if(c[0]) state_n[0]=~state_n[0];\n"
    "    end\n"
    "end\n"
)


def _m422unpack(a, b, c, state):
    if b or (c & 0x7FFFFFFE):
        return 0, 0, 1, state
    st = 0 if (c >> 31) else state
    phase = st & 1
    if phase:                     # UYVY lane map
        y0, cb, y1, cr = byte_of(a, 1), byte_of(a, 0), byte_of(a, 3), byte_of(a, 2)
    else:                         # YUYV lane map
        y0, cb, y1, cr = byte_of(a, 0), byte_of(a, 1), byte_of(a, 2), byte_of(a, 3)
    lo, hi = C_LIMITS
    if not (lo <= cb <= hi) or not (lo <= cr <= hi):
        return 0, 0, 1, state
    r = y0 | (cb << 8) | (cr << 16) | (y1 << 24)
    x = cb | (cr << 8) | (_field(st, 1, 7) << 16) | (phase << 24)
    if y0 == y1:
        x |= 1 << 25
    if cb == 128 and cr == 128:
        x |= 1 << 26
    if not Y_LIMITS[0] <= y0 <= Y_LIMITS[1] or not Y_LIMITS[0] <= y1 <= Y_LIMITS[1]:
        x |= 1 << 27
    if cb in (lo, hi):
        x |= 1 << 28
    if cr in (lo, hi):
        x |= 1 << 29
    if _field(state, 1, 7) == 127:
        x |= 1 << 30
    if c >> 31:
        x |= 1 << 31
    new = _set_field(st, 1, 7, (_field(st, 1, 7) + 1) & 0x7F)
    if c & 1:
        new ^= 1
    return r, x, 0, new


core('yuv422_unpack',
    'One 32-bit 4:2:2 macropixel per beat expanded to two 4:4:4 pixels with the '
    'byte-lane map held in state. state[0] is the lane phase: 0 = YUYV order '
    '(Y0=a[7:0], Cb=a[15:8], Y1=a[23:16], Cr=a[31:24]) and 1 = UYVY order '
    '(Cb=a[7:0], Y0=a[15:8], Cr=a[23:16], Y1=a[31:24]); the shuffle is pure '
    'byte-lane routing, so both orders cost the same cone. c[0] toggles the '
    'phase for the following beat, c[31] restarts the phase and the macropixel '
    'counter before this beat, b and c[30:1] must be zero. state[7:1] counts '
    'macropixels and wraps at 127. Chroma legality is enforced: Cb or Cr '
    'outside the studio window 16..240 rejects the beat (result=aux=0, state '
    'kept, fault=1). result[7:0]=Y0, result[15:8]=Cb, result[23:16]=Cr, '
    'result[31:24]=Y1; aux[7:0]=Cb and aux[15:8]=Cr are the duplicated chroma '
    'for pixel 1 (the 4:2:2 to 4:4:4 expansion), aux[23:16]=macropixel index, '
    'aux[24]=phase in effect, aux[25]=Y0==Y1, aux[26]=achromatic pair, aux[27] = '
    'a luma byte is outside 16..235, aux[28]/aux[29] = Cb/Cr sits on the legal '
    'window edge, aux[30] = the macropixel counter wrapped, aux[31] = this beat '
    'was a restart.',
    BODY4,
    'Firmware repays a byte swap plus a chroma duplication per pixel and a '
    'branch per format variant; this core re-shuffles the four byte lanes and '
    'emits both expanded pixels with legality flags every enabled beat at II=1, '
    'and the format phase is a toggle in a register instead of a re-issue.',
    2, stateful=True)


# ==========================================================================
# 5. OSD alpha blend, four component bytes per beat, exact shift-add alpha.
# ==========================================================================
BODY5 = (
    "for(lane=0;lane<4;lane=lane+1) begin\n"
    "    pa={24'd0,a[(lane<<3)+:8]};\n"
    "    pb={24'd0,b[(lane<<3)+:8]};\n"
    "    pc={24'd0,c[(lane<<3)+:8]};\n"
    "    if(pc==32'd0) begin\n"
    "        r[(lane<<3)+:8]=pb[7:0]; x[lane]=1'b1;\n"
    "    end else if(pc==32'd255) begin\n"
    "        r[(lane<<3)+:8]=pa[7:0]; x[4+lane]=1'b1;\n"
    "    end else begin\n"
    "        if(pa>pb) begin ph=pa-pb; temp=0; end\n"
    "        else if(pb>pa) begin ph=pb-pa; temp=1; end\n"
    "        else begin ph=0; temp=0; x[8+lane]=1'b1; end\n"
    # alpha x |fg-bg| as an unconditional shift-add array: eight tests on the
    # alpha bits, no multiplier inferred anywhere.
    "        ext=0;\n"
    "        for(i=0;i<8;i=i+1) if(pc[i]) ext=ext+({25'd0,ph}<<i);\n"
    "        wide=ext+64'd127;\n"
    "        pl=wide[15:8];\n"
    "        ph=pl+wide[7:0];\n"
    "        mask=pl;\n"
    "        if(ph>=32'd255) mask=mask+32'd1;\n"
    "        if(ph>=32'd510) mask=mask+32'd1;\n"
    "        if(mask>pl) x[12+lane]=1'b1;\n"
    "        if(temp==0) pl=pb+mask; else pl=pb-mask;\n"
    "        r[(lane<<3)+:8]=pl[7:0];\n"
    "        if(pl!=pa && pl!=pb) x[16+lane]=1'b1;\n"
    "    end\n"
    "end\n"
    "if(c[7:0]==c[15:8] && c[15:8]==c[23:16] && c[23:16]==c[31:24]) x[20]=1'b1;\n"
    "if(x[7:0]!=0) x[21]=1'b1;\n"
    "if(r[7:0]==r[15:8] && r[15:8]==r[23:16] && r[23:16]==r[31:24]) x[22]=1'b1;\n"
    "if(c[7:0]>32'd127 && c[15:8]>32'd127 && c[23:16]>32'd127 &&\n"
    "   c[31:24]>32'd127) x[23]=1'b1;\n"
)


def _m_blend(a, b, c, state):
    r = x = 0
    for k in range(4):
        fg, bg, al = byte_of(a, k), byte_of(b, k), byte_of(c, k)
        if al == 0:
            out = bg
            x |= 1 << k
        elif al == 255:
            out = fg
            x |= 1 << (4 + k)
        else:
            d = abs(fg - bg)
            q = (al * d + 127) // 255          # round half up, the model's oracle
            if fg == bg:
                x |= 1 << (8 + k)
            if q > fold255(al * d + 127) - (fold255(al * d + 127)):
                pass
            if q > ((al * d + 127) >> 8):
                x |= 1 << (12 + k)             # the fold rounded the quotient up
            out = bg + q if fg > bg else bg - q
            if out != fg and out != bg:
                x |= 1 << (16 + k)
        r |= (out & 0xFF) << (8 * k)
    if byte_of(c, 0) == byte_of(c, 1) == byte_of(c, 2) == byte_of(c, 3):
        x |= 1 << 20
    if x & 0xFF:
        x |= 1 << 21
    if byte_of(r, 0) == byte_of(r, 1) == byte_of(r, 2) == byte_of(r, 3):
        x |= 1 << 22
    if all(byte_of(c, k) > 127 for k in range(4)):
        x |= 1 << 23
    return r, x, 0, state


core('osd_blend_u8',
    'Per-channel alpha blend of one four-component OSD sample per beat: lane k '
    'is foreground a[8k+:8] over background b[8k+:8] with its own 8-bit alpha '
    'c[8k+:8], so a logo can fade its colour channels and its key channel '
    'independently. out = bg + round_half_up(alpha*(fg-bg)/255) exactly; the '
    'alpha product is an eight-test shift-add array (no multiplier is inferred) '
    'and the /255 is the exact fold floor(x/255)=(x>>8)+[(x>>8)+(x&255)>=255]+['
    '...>=510], both proven over their whole reachable domain in selftest(). '
    'alpha=0 returns the background and alpha=255 returns the foreground '
    'bit-exactly through the fast path, which skips the product entirely. '
    'aux[3:0] = lane took the alpha=0 path, aux[7:4] = lane took alpha=255, '
    'aux[11:8] = lane had fg==bg (blend is a no-op), aux[15:12] = the rounding '
    'incremented the quotient, aux[19:16] = the lane is a true mix (differs '
    'from both inputs), aux[20] = all four alphas equal, aux[21] = any fast '
    'path fired, aux[22] = the four output bytes are equal, aux[23] = every '
    'alpha exceeds 127 (foreground-dominant). No fault condition: every byte '
    'triple is a legal blend. Stateless.',
    BODY5,
    'A firmware blend is a signed difference, a multiply, a divide by 255 and a '
    'saturating add per channel, four times over, with a branch for the opaque '
    'and transparent cases; this core issues all four lanes through one '
    'shift-add array and one exact fold in a single enabled beat and reports '
    'which fast paths fired.',
    4, faultless=True)

# ==========================================================================
# 6. Chroma key: four pixels per beat against a window held in state.  The
# distance is compares and subtracts only, the metric selects box (max) or
# diamond (sum), and the thresholds are tolerance nibbles shifted, so this core
# infers no multiplier either.
# ==========================================================================
CK_CB, CK_CR, CK_TOL, CK_EDGE, CK_METRIC, CK_BEATS = 0, 8, 16, 20, 24, 25


BODY6 = (
    "if(c[30:26]!=0) begin\n"
    "    f=1'b1; r=0; x=0; state_n=state_r;\n"
    "end else if(c[25] && (c[7:0]<32'd16 || c[7:0]>32'd240 ||\n"
    "                      c[15:8]<32'd16 || c[15:8]>32'd240)) begin\n"
    "    f=1'b1; r=0; x=0; state_n=state_r;\n"
    "end else begin\n"
    "    if(c[31]) begin\n"
    "        state_n=0; state_n[7:0]=8'd128; state_n[15:8]=8'd128;\n"
    "    end\n"
    "    if(c[25]) begin\n"
    "        state_n[7:0]=c[7:0]; state_n[15:8]=c[15:8];\n"
    "        state_n[19:16]=c[19:16]; state_n[23:20]=c[23:20]; state_n[24]=c[24];\n"
    "    end\n"
    "    state_n[31:25]=state_n[31:25]+7'd1;\n"
    "    pa=state_n[7:0];\n"
    "    pb=state_n[15:8];\n"
    "    sh=state_n[24];\n"
    "    if(sh) begin\n"
    "        pc=state_n[19:16]<<5; ph=state_n[23:20]<<1;\n"
    "    end else begin\n"
    "        pc=state_n[19:16]<<4; ph=state_n[23:20];\n"
    "    end\n"
    "    ext=pc+ph;\n"
    "    mask=0;\n"
    "    for(lane=0;lane<4;lane=lane+1) begin\n"
    "        temp={24'd0,a[(lane<<3)+:8]};\n"
    "        pl={24'd0,b[(lane<<3)+:8]};\n"
    "        if(temp<32'd16 || temp>32'd240 || pl<32'd16 || pl>32'd240) x[27]=1'b1;\n"
    "        if(temp>pa) temp=temp-pa; else temp=pa-temp;\n"
    "        if(pl>pb) pl=pl-pb; else pl=pb-pl;\n"
    "        if(temp==pl) r[23]=1'b1;\n"
    "        if(sh) wide2=temp+pl; else wide2=(pl>temp) ? pl : temp;\n"
    "        if(wide2>mask) mask=wide2[31:0];\n"
    "        if(wide2<=pc) begin\n"
    "            r[lane]=1'b1; r[4+lane]=1'b1; i=i+1; j=2;\n"
    "        end else if(wide2<=ext) begin\n"
    "            r[lane]=1'b1; r[8+lane]=1'b1; i=i+1; if(j<1) j=1;\n"
    "        end else r[12+lane]=1'b1;\n"
    "    end\n"
    "    r[19:16]=i; r[21:20]=j; r[22]=sh;\n"
    "    r[31:24]=mask;\n"
    "    x[7:0]=state_n[7:0];\n"
    "    x[15:8]=state_n[15:8];\n"
    "    x[19:16]=state_n[19:16]; x[23:20]=state_n[23:20];\n"
    "    x[24]=c[25]; x[25]=c[31]; x[26]=(r[3:0]!=0);\n"
    "    x[28]=(state_n[19:16]==0);\n"
    "    x[31:29]=state_n[27:25];\n"
    "end\n"
)


def _m_ckey(a, b, c, state):
    """Exact model of BODY6 (see chroma_key's spec for the field map)."""
    if (c >> 26) & 0x1F:
        return 0, 0, 1, state
    if (c >> 25) & 1 and not (16 <= (c & 0xFF) <= 240 and 16 <= ((c >> 8) & 0xFF) <= 240):
        return 0, 0, 1, state
    st = 0 if (c >> 31) & 1 else state
    if (c >> 31) & 1:
        st = _set_field(st, CK_CB, 8, 128)
        st = _set_field(st, CK_CR, 8, 128)
    if (c >> 25) & 1:
        st = _set_field(st, CK_CB, 8, c & 0xFF)
        st = _set_field(st, CK_CR, 8, (c >> 8) & 0xFF)
        st = _set_field(st, CK_TOL, 4, (c >> 16) & 0xF)
        st = _set_field(st, CK_EDGE, 4, (c >> 20) & 0xF)
        st = _set_field(st, CK_METRIC, 1, (c >> 24) & 1)
    st = _set_field(st, CK_BEATS, 7, (_field(st, CK_BEATS, 7) + 1) & 0x7F)
    ref_cb, ref_cr = _field(st, CK_CB, 8), _field(st, CK_CR, 8)
    tol, edge = _field(st, CK_TOL, 4), _field(st, CK_EDGE, 4)
    metric = _field(st, CK_METRIC, 1)
    hard = (tol << 5) if metric else (tol << 4)
    outer = hard + ((edge << 1) if metric else edge)
    r = x = 0
    count = worst = biggest = 0
    for k in range(4):
        vcb, vcr = byte_of(a, k), byte_of(b, k)
        if not (16 <= vcb <= 240 and 16 <= vcr <= 240):
            x |= 1 << 27
        db = abs(vcb - ref_cb)
        dr = abs(vcr - ref_cr)
        if db == dr:
            r |= 1 << 23
        dist = db + dr if metric else max(db, dr)
        biggest = max(biggest, dist)
        if dist <= hard:
            r |= (1 << k) | (1 << (4 + k))
            count += 1
            worst = 2
        elif dist <= outer:
            r |= (1 << k) | (1 << (8 + k))
            count += 1
            worst = max(worst, 1)
        else:
            r |= 1 << (12 + k)
    r |= (count & 0xF) << 16
    r |= worst << 20
    r |= metric << 22
    r |= (biggest & 0xFF) << 24
    x |= ref_cb | (ref_cr << 8) | (tol << 16) | (edge << 20)
    if (c >> 25) & 1:
        x |= 1 << 24
    if (c >> 31) & 1:
        x |= 1 << 25
    if r & 0xF:
        x |= 1 << 26
    if tol == 0:
        x |= 1 << 28
    x |= (_field(st, CK_BEATS, 7) & 7) << 29
    return r & MASK, x & MASK, 0, st


core('chroma_key',
    'Chroma key decision for four pixels per beat against a window held in '
    'state. a[8k+:8] = Cb of lane k, b[8k+:8] = Cr of lane k, c is the '
    'program/control word. Only compares, subtracts and shifts appear: '
    'db=|Cb-Cb_ref| and dr=|Cr-Cr_ref| by compare-then-subtract, and the metric '
    'selects d=max(db,dr) (a rectangular box window) or d=db+dr (a diamond '
    'window). The hard radius is the tolerance nibble shifted left by 4 codes '
    '(by 5 in diamond mode) and the soft band adds the edge nibble (doubled in '
    'diamond mode). Control: c[7:0]=key centre Cb, c[15:8]=centre Cr, '
    'c[19:16]=tolerance nibble, c[23:20]=soft-edge nibble, c[24]=diamond metric, '
    'c[25]=program request (the new window is already in force for this same '
    'beat), c[31]=restart to the default window (128,128, tolerance 0, edge 0, '
    'box), c[30:26] must read zero. Fault (result=aux=0, state kept): a '
    'reserved control bit is set, or a program request anchors the centre '
    'outside the studio chroma window 16..240, which keys the whole frame. '
    'State: 7:0 centre Cb, 15:8 centre Cr, 19:16 tolerance nibble, 23:20 edge '
    'nibble, 24 metric, 31:25 beats since the last program. '
    'result[3:0]=keyed mask, [7:4]=hard-keyed (transparent), [11:8]=soft-keyed, '
    '[15:12]=kept (opaque), [19:16]=number of keyed lanes, [21:20]=worst class '
    'of the beat, [22]=metric in effect, [23]=some lane had db==dr (a spill '
    'tie, the classic green-screen ambivalence), [31:24]=largest lane distance. '
    'aux[7:0]=Cb centre, aux[15:8]=Cr centre, '
    'aux[19:16]=tolerance nibble, aux[23:20]=edge nibble, aux[24]=programmed '
    'this beat, aux[25]=restart this beat, aux[26]=any lane keyed, aux[27]=some '
    'lane presented chroma outside 16..240, aux[28]=tolerance is zero (nothing but '
    'an exact match keys), aux[31:29]=beats since the last program, low 3 bits.',
    BODY6,
    'A firmware key pays an absolute difference, two compares and a branch per '
    'pixel per channel; this core decides four pixels against a registered '
    'window with pure add/compare arithmetic in one enabled beat at II=1, so '
    'the key mask for a whole scan line arrives with deterministic per-line '
    'latency and a window change costs one beat instead of a re-issue.',
    4, stateful=True)

# ==========================================================================
# 7. Bresenham line stepper: one pixel move per accepted beat, all eight
# octants, decision-parameter arithmetic (accumulate, compare, subtract) so not
# even an add of two variables becomes a multiply.
# ==========================================================================
BS_X, BS_Y = 0, 12
BS_DIRX, BS_DIRY, BS_STEEP = 24, 25, 26
BS_STARTED, BS_DONE = 27, 28
BS_MAJ, BS_MIN, BS_ERR, BS_STEPS = 32, 40, 48, 58
BS_MAJSTEP, BS_MINSTEP = 68, 69


BODY7 = (
    "if(c[31]) begin\n"
    "    if(a[31:16]!=0 || b[31:16]!=0 || c[30:1]!=0) begin\n"
    "        f=1'b1; r=0; x=0; state_n=state_r;\n"
    "    end else begin\n"
    "        pa=a[7:0]; pb=a[15:8]; pc=b[7:0]; ph=b[15:8];\n"
    "        pl=(pc>=pa) ? (pc-pa) : (pa-pc);\n"
    "        mask=(ph>=pb) ? (ph-pb) : (pb-ph);\n"
    "        state_n[11:0]=pa[11:0]; state_n[23:12]=pb[11:0];\n"
    "        state_n[24]=(pc<pa); state_n[25]=(ph<pb);\n"
    "        if(mask>pl) begin\n"
    "            state_n[26]=1'b1; state_n[39:32]=mask[7:0]; state_n[47:40]=pl[7:0];\n"
    "        end else begin\n"
    "            state_n[26]=1'b0; state_n[39:32]=pl[7:0]; state_n[47:40]=mask[7:0];\n"
    "        end\n"
    "        state_n[27]=1'b1; state_n[28]=(state_n[39:32]==8'd0);\n"
    "        state_n[57:48]=10'd0; state_n[65:58]=8'd0;\n"
    "        state_n[68]=1'b0; state_n[69]=1'b0;\n"
    "    end\n"
    "end else begin\n"
    "    if(a[31:8]!=0 || b!=0 || c[30:1]!=0 || !state_r[27] || state_r[28]) begin\n"
    "        f=1'b1; r=0; x=0; state_n=state_r;\n"
    "    end else begin\n"
    "        temp=state_r[57:48]+{22'd0,state_r[47:40]};\n"
    "        if(temp>={22'd0,state_r[39:32]}) begin\n"
    "            temp=temp-{22'd0,state_r[39:32]}; sh=1; end\n"
    "        else sh=0;\n"
    "        state_n[57:48]=temp[9:0];\n"
    "        state_n[65:58]=state_r[65:58]+8'd1;\n"
    "        state_n[68]=1'b1; state_n[69]=sh;\n"
    "        if(state_r[26]) begin\n"
    "            if(state_r[25]) state_n[23:12]=state_r[23:12]-12'd1;\n"
    "            else state_n[23:12]=state_r[23:12]+12'd1;\n"
    "            if(sh) begin\n"
    "                if(state_r[24]) state_n[11:0]=state_r[11:0]-12'd1;\n"
    "                else state_n[11:0]=state_r[11:0]+12'd1;\n"
    "            end\n"
    "        end else begin\n"
    "            if(state_r[24]) state_n[11:0]=state_r[11:0]-12'd1;\n"
    "            else state_n[11:0]=state_r[11:0]+12'd1;\n"
    "            if(sh) begin\n"
    "                if(state_r[25]) state_n[23:12]=state_r[23:12]-12'd1;\n"
    "                else state_n[23:12]=state_r[23:12]+12'd1;\n"
    "            end\n"
    "        end\n"
    "        state_n[28]=(state_n[65:58]==state_r[39:32]);\n"
    "    end\n"
    "end\n"
    "if(!f) begin\n"
    "    r[11:0]=state_n[11:0]; r[23:12]=state_n[23:12];\n"
    "    r[24]=state_n[68]; r[25]=state_n[69];\n"
    "    r[26]=state_n[24]; r[27]=state_n[25]; r[28]=state_n[26];\n"
    "    r[29]=((state_n[57:48]<<1)>={22'd0,state_n[39:32]});\n"
    "    r[30]=state_n[28];\n"
    "    r[31]=(state_n[39:32]==8'd0);\n"
    "    x[7:0]=c[31] ? 8'd0 : a[7:0];\n"
    "    x[15:8]=state_n[65:58];\n"
    "    x[27:16]=state_n[57:48];\n"
    "    x[28]=state_n[27]; x[29]=state_n[28]; x[30]=c[31];\n"
    "    x[31]=(((state_n[57:48]<<1)=={22'd0,state_n[39:32]}));\n"
    "end\n"
)


def _m_bres(a, b, c, state):
    """Exact model of BODY7: program on c[31], then one move per beat."""
    if c >> 31:
        if (a >> 16) or (b >> 16) or (c & 0x7FFFFFFE):
            return 0, 0, 1, state
        x0, y0 = a & 0xFF, (a >> 8) & 0xFF
        x1, y1 = b & 0xFF, (b >> 8) & 0xFF
        dx, dy = abs(x1 - x0), abs(y1 - y0)
        steep = dy > dx
        maj, mino = (dy, dx) if steep else (dx, dy)
        st = _set_field(0, BS_X, 12, x0)
        st = _set_field(st, BS_Y, 12, y0)
        st = _set_field(st, BS_DIRX, 1, int(x1 < x0))
        st = _set_field(st, BS_DIRY, 1, int(y1 < y0))
        st = _set_field(st, BS_STEEP, 1, int(steep))
        st = _set_field(st, BS_STARTED, 1, 1)
        st = _set_field(st, BS_DONE, 1, int(maj == 0))
        st = _set_field(st, BS_MAJ, 8, maj)
        st = _set_field(st, BS_MIN, 8, mino)
    else:
        if (a >> 8) or b or (c & 0x7FFFFFFE) or \
           not _field(state, BS_STARTED, 1) or _field(state, BS_DONE, 1):
            return 0, 0, 1, state
        maj = _field(state, BS_MAJ, 8)
        err = _field(state, BS_ERR, 10) + _field(state, BS_MIN, 8)
        minor = int(err >= maj)
        if minor:
            err -= maj
        steps = (_field(state, BS_STEPS, 8) + 1) & 0xFF
        px, py = _field(state, BS_X, 12), _field(state, BS_Y, 12)
        dirx, diry = _field(state, BS_DIRX, 1), _field(state, BS_DIRY, 1)
        if _field(state, BS_STEEP, 1):
            py = py - 1 if diry else py + 1
            if minor:
                px = px - 1 if dirx else px + 1
        else:
            px = px - 1 if dirx else px + 1
            if minor:
                py = py - 1 if diry else py + 1
        st = state
        st = _set_field(st, BS_X, 12, px & 0xFFF)
        st = _set_field(st, BS_Y, 12, py & 0xFFF)
        st = _set_field(st, BS_ERR, 10, err)
        st = _set_field(st, BS_STEPS, 8, steps)
        st = _set_field(st, BS_MAJSTEP, 1, 1)
        st = _set_field(st, BS_MINSTEP, 1, minor)
        st = _set_field(st, BS_DONE, 1, int(steps == maj))
    err = _field(st, BS_ERR, 10)
    maj = _field(st, BS_MAJ, 8)
    r = (_field(st, BS_X, 12) | (_field(st, BS_Y, 12) << 12)
         | (_field(st, BS_MAJSTEP, 1) << 24) | (_field(st, BS_MINSTEP, 1) << 25)
         | (_field(st, BS_DIRX, 1) << 26) | (_field(st, BS_DIRY, 1) << 27)
         | (_field(st, BS_STEEP, 1) << 28) | (_field(st, BS_DONE, 1) << 30)
         | int(maj == 0) << 31)
    if (err << 1) >= maj:
        r |= 1 << 29
    x = (_field(st, BS_STEPS, 8) << 8) | (err << 16) | (_field(st, BS_STARTED, 1) << 28) \
        | (_field(st, BS_DONE, 1) << 29) | ((0 if (c >> 31) else (a & 0xFF)) << 0)
    if (c >> 31):
        x |= 1 << 30
    if (err << 1) == maj:
        x |= 1 << 31
    return r & MASK, x & MASK, 0, st


core('bresenham_step',
    'Bresenham line rasteriser, one pixel move per accepted beat, all eight '
    'octants, decision-parameter arithmetic only (accumulate, compare, '
    'subtract, shift) so the cone holds no multiply and no divide. '
    'A program beat is c[31]=1 with a[7:0]=x0, a[15:8]=y0, b[7:0]=x1, '
    'b[15:8]=y1 and a[31:16]=b[31:16]=c[30:1]=0; it plots the start pixel and '
    'derives dx=|x1-x0|, dy=|y1-y0| by compare-then-subtract, the major length '
    'maj=max(dx,dy), the minor length min=min(dx,dy), the steep flag and the two '
    'axis signs, and clears the decision parameter. A step beat is c[31]=0 with '
    'a[31:8]=0, b=0, c[30:1]=0; a[7:0] is an operation tag echoed to aux[7:0]. '
    'Each step does err=err+min, subtracts maj once when err>=maj, moves the '
    'major axis by one always and the minor axis by one on that subtract, so '
    'after maj steps exactly min minor moves have happened and the endpoint is '
    'hit with no accumulated rounding. Fault (result=aux=0, state kept): a '
    'reserved input field is nonzero, or a step arrives before a program or '
    'after the primitive completed. State: 11:0 x, 23:12 y, 24/25 the x/y '
    'direction bits, 26 steep, 27 started, 28 done, 39:32 maj, 47:40 min, 57:48 '
    'the decision parameter, 65:58 steps taken, 68 major moved on the last beat, '
    '69 minor moved on the last beat. result[11:0]=x, [23:12]=y, [24]=major '
    'moved, [25]=minor moved (a diagonal beat sets both), [28:26]=octant as '
    '{steep,y-dir,x-dir}, [29]=the decision parameter is in the upper half of '
    'its cell (2*err>=maj), [30]=primitive complete, [31]=degenerate line '
    '(maj=0, one pixel). aux[7:0]=tag, [15:8]=steps taken, [27:16]=decision '
    'parameter, [28]=started, [29]=done, [30]=this beat programmed the '
    'primitive, [31]=exact tie (2*err==maj).',
    BODY7,
    'A firmware Bresenham step is a load, an add, a compare, a subtract and two '
    'branch-target updates per pixel, so the plot rate is set by the loop, not '
    'by the fabric; this core retires one pixel every enabled beat at II=1 with '
    'the whole eight-octant decision in hardwired add/compare logic, giving a '
    'line of N pixels in exactly N+1 beats and deterministic per-line latency '
    'for vector OSD and waveform plotting.',
    1, stateful=True)

# ==========================================================================
# 8. Sprite/OSD palette compositing: four indexed pixels per beat.  The
# palette is the published CGA/RGBI 16-colour table and lives in a Verilog
# function (pure mux tree) rather than an inferred RAM, because a Gowin BSRAM
# cell is a black box in OSS CAD simulation and an asynchronous read port has
# no fabric primitive anyway.
# ==========================================================================
def _argb(index):
    """The published CGA/RGBI colour for one palette index, as (r, g, b)."""
    if index == 6:                       # brown: green sits at the low level
        return (170, 85, 0)
    r, g, b = (170 if index & 4 else 0, 170 if index & 2 else 0,
               170 if index & 1 else 0)
    if index == 8:                       # dark gray is the intensity exception
        return (85, 85, 85)
    if index & 8:
        r, g, b = (255 if v else 85 for v in (r, g, b))
    return (r, g, b)


PAL16 = []
for _i in range(16):
    _r, _g, _b = _argb(_i)
    # Index 0 is the colour key (fully transparent) and index 8 the 50% glass
    # tile; every other entry is opaque.
    _a = 0 if _i == 0 else (128 if _i == 8 else 255)
    PAL16.append(_r | (_g << 8) | (_b << 16) | (_a << 24))


def _pal_decl():
    lines = ['// Palette as a decoded function: 16 x 32 bits of constant logic.',
             'function [31:0] spr_pal; input [3:0] sidx; begin case (sidx)']
    for i, word in enumerate(PAL16):
        lines.append("    4'd%02d: spr_pal = 32'h%08x;" % (i, word))
    lines.append("    default: spr_pal = 32'h00000000;")
    lines.append('endcase end endfunction')
    return '\n'.join(lines) + '\n'


def tables(name):
    """Images exported for cross-checking; only the sprite palette is one."""
    return {'palette': list(PAL16)} if name == 'sprite_blend' else {}


BODY8 = (
    "if(c[31:4]!=0) begin f=1'b1; r=0; x=0; end\n"
    "else begin\n"
    "    sh=c[1:0];\n"
    "    for(lane=0;lane<4;lane=lane+1) begin\n"
    "        idx=a[(lane<<2)+:4];\n"
    "        wide=spr_pal(idx);\n"
    "        pc={24'd0,b[(lane<<3)+:8]};\n"
    "        pb=wide[(sh<<3)+:8];\n"
    "        if(wide[31:24]==8'd0) x[27]=1'b1;\n"
    "        if(c[3]) pa=32'd255;\n"
    "        else begin\n"
    "            pa={28'd0,a[16+(lane<<2)+:4]};\n"
    "            pa=(pa<<4)+pa;                       // coverage x 17, shift/add\n"
    "            if(c[2]) pa=32'd255-pa;\n"
    "        end\n"
    "        if(pa==32'd0) begin\n"
    "            r[(lane<<3)+:8]=pc[7:0]; x[4+lane]=1'b1;\n"
    "        end else if(pa==32'd255) begin\n"
    "            r[(lane<<3)+:8]=pb[7:0]; x[8+lane]=1'b1;\n"
    "        end else begin\n"
    "            if(pb>pc) begin ph=pb-pc; temp=0; end\n"
    "            else if(pc>pb) begin ph=pc-pb; temp=1; end\n"
    "            else begin ph=0; temp=0; x[lane]=1'b1; end\n"
    "            ext=0;\n"
    "            for(j=0;j<8;j=j+1) if(pa[j]) ext=ext+({25'd0,ph}<<j);\n"
    "            wide2=ext+64'd127;\n"
    "            pl=wide2[15:8];\n"
    "            ph=pl+wide2[7:0];\n"
    "            mask=pl;\n"
    "            if(ph>=32'd255) mask=mask+32'd1;\n"
    "            if(ph>=32'd510) mask=mask+32'd1;\n"
    "            if(mask>pl) x[12+lane]=1'b1;\n"
    "            if(temp==0) pl=pc+mask; else pl=pc-mask;\n"
    "            r[(lane<<3)+:8]=pl[7:0];\n"
        "            if(pl[7:0]!=pc[7:0]) i=i+1;   // aux[19:16] is the count\n"
    "        end\n"
    "    end\n"
    "    x[19:16]=i;\n"
    "    x[21:20]=sh;\n"
    "    x[22]=c[2]; x[23]=c[3];\n"
    "    if(a[3:0]==a[7:4] && a[7:4]==a[11:8] && a[11:8]==a[15:12]) x[24]=1'b1;\n"
    "    if(a[19:16]==a[23:20] && a[23:20]==a[27:24] && a[27:24]==a[31:28]) x[25]=1'b1;\n"
    "    if(r[7:0]==r[15:8] && r[15:8]==r[23:16] && r[23:16]==r[31:24]) x[26]=1'b1;\n"
    "    if(sh==2'd3) x[28]=1'b1;\n"
    "    if(a[3:0]==a[7:4]) x[29]=1'b1;\n"
    "    if(a[11:8]==a[15:12]) x[30]=1'b1;\n"
    "    if(a[19:16]>=4'd8 && a[23:20]>=4'd8 && a[27:24]>=4'd8 &&\n"
    "       a[31:28]>=4'd8) x[31]=1'b1;\n"
    "end\n"
)


def _m_sprite(a, b, c, state):
    """Exact model of BODY8: palette gather plus coverage-weighted blend."""
    if c >> 4:
        return 0, 0, 1, 0
    ch, invert, opaque = c & 3, (c >> 2) & 1, (c >> 3) & 1
    r = x = 0
    changed = 0
    for k in range(4):
        index = (a >> 4 * k) & 0xF
        cov = (a >> (16 + 4 * k)) & 0xF
        bg = byte_of(b, k)
        word = PAL16[index]
        comp = (word >> 8 * ch) & 0xFF
        if (word >> 24) == 0:
            x |= 1 << 27
        alpha = 255 if opaque else ((15 - cov) * 17 if invert else cov * 17)
        if alpha == 0:
            out = bg
            x |= 1 << (4 + k)
        elif alpha == 255:
            out = comp
            x |= 1 << (8 + k)
        else:
            if comp == bg:
                x |= 1 << k
            product = alpha * abs(comp - bg)      # eight shift-add tests in RTL
            total = product + 127
            quotient = (total // 255)             # the exact fold in RTL
            if quotient > (total >> 8):
                x |= 1 << (12 + k)
            out = bg + quotient if comp > bg else bg - quotient
            if out != bg:
                changed += 1                      # aux[19:16] carries the count
        r |= (out & 0xFF) << 8 * k
    x |= (changed & 0xF) << 16
    x |= ch << 20
    x |= invert << 22
    x |= opaque << 23
    nib = [(a >> 4 * k) & 0xF for k in range(4)]
    covs = [(a >> (16 + 4 * k)) & 0xF for k in range(4)]
    if nib[0] == nib[1] == nib[2] == nib[3]:
        x |= 1 << 24
    if covs[0] == covs[1] == covs[2] == covs[3]:
        x |= 1 << 25
    if byte_of(r, 0) == byte_of(r, 1) == byte_of(r, 2) == byte_of(r, 3):
        x |= 1 << 26
    if ch == 3:
        x |= 1 << 28
    if nib[0] == nib[1]:
        x |= 1 << 29
    if nib[2] == nib[3]:
        x |= 1 << 30
    if all(v >= 8 for v in covs):
        x |= 1 << 31
    return r & MASK, x & MASK, 0, 0


core('sprite_blend',
    'Four indexed sprite/OSD pixels composited per beat over one background '
    'plane. a[4k+:4] = the 4-bit palette index of lane k, a[16+4k+:4] = its '
    '4-bit coverage (anti-alias) code, b[8k+:8] = the background byte of lane k '
    'and c[1:0] selects which palette channel is being composited (0=R, 1=G, '
    '2=B, 3=A), so a sprite row is laid down in four beats, one per channel. '
    'c[2]=invert coverage (alpha becomes 255-alpha), c[3]=force opaque (alpha '
    '255 regardless of coverage), c[31:4] must read zero or the beat faults '
    '(result=aux=0). The palette is the published CGA/RGBI 16-colour table with '
    'index 0 as the transparent colour key and index 8 as 50% glass, decoded by '
    'a constant function (no RAM is inferred). alpha = coverage x 17 is exactly '
    '(cov<<4)+cov, the alpha-times-distance product is an eight-test shift-add '
    'array and the divide by 255 is the exact fold, so the whole lane is '
    'shift/add/compare only and no multiplier is inferred. alpha=0 returns the '
    'background and alpha=255 the palette byte bit-exactly through the fast '
    'paths. result[8k+:8] = the composited byte of lane k. aux[3:0] = lane '
    'whose palette byte equalled the background (blend is a no-op), aux[7:4] = '
    'lane at alpha 0, aux[11:8] = lane at alpha 255, aux[15:12] = lane where '
    'the fold rounded the quotient up, aux[19:16] = how many lanes actually '
    'changed the background, aux[21:20] = channel select, aux[22] = invert, '
    'aux[23] = force opaque, aux[24] = all four indices equal (a solid run), '
    'aux[25] = all four coverage codes equal, aux[26] = all four output bytes '
    'equal, aux[27] = some lane selected a transparent palette entry, aux[28] = '
    'the alpha plane itself is being composited, aux[29]/aux[30] = lane pair '
    '0/1 and 2/3 share an index, aux[31] = every coverage code is at least 8 '
    '(majority ink). Stateless.',
    BODY8,
    'A sprite pixel in firmware is an indexed load, a byte select, a multiply '
    'by coverage, a divide by 255 and a saturating add; this core gathers four '
    'palette entries and retires four composited bytes every enabled beat at '
    'II=1 from one shift-add array, and the run-length flags tell the feeder '
    'when a whole quad collapsed to one solid byte.',
    4, decl=_pal_decl())

# ==========================================================================
# 9. LVDS 20-bit self-synchronous scrambler/descrambler, one 21-bit serializer
# word per beat.  The taps are the published 1 + x^-3 + x^-6 + x^-16 + x^-20
# desynchroniser; because a self-synchronous scrambler is its own inverse the
# same XOR tree serves both directions, and the tree is unrolled so it is
# feed-forward (no register loop) and therefore legal template logic.
# ==========================================================================
TAPS20 = (3, 6, 16, 20)
SEED20 = (1 << 20) - 1                 # the all-ones desynchroniser prime
SR_REG, SR_WORDS, SR_ONES, SR_TRANS, SR_PRIMED = 0, 20, 28, 36, 44


def _scr_tap(i, tap):
    """The Verilog source of o_{i-tap} for either direction of the tree."""
    if i >= tap:
        return '(c[0] ? a[%d] : ph[%d])' % (i - tap, i - tap)
    return 'state_r[%d]' % (20 - tap + i)


def _scr_body():
    text = ["    // 20 feed-forward stages: stage i taps only bits below i.\n"]
    for i in range(20):
        text.append('    ph[%d]=a[%d]' % (i, i))
        for tap in TAPS20:
            text.append('^' + _scr_tap(i, tap))
        text.append(';\n')
    return ''.join(text)


BODY9 = (
    "if(a[31:21]!=0 || c[30:2]!=0) begin\n"
    "    f=1'b1; r=0; x=0; state_n=state_r;\n"
    "end else if(c[31] || c[1]) begin\n"
    "    if(c[31]) state_n=0;\n"
    "    state_n[19:0]=20'h%05X;\n" % SEED20 +
    "    state_n[44]=1'b1;\n"
    "    r[19:0]=20'h%05X;\n" % SEED20 +
    "    r[20]=a[20];\n"
    "    x[0]=c[0]; x[1]=1'b1; x[2]=1'b1; x[3]=c[31];\n"
    "    x[13:6]=state_n[27:20]; x[21:14]=state_n[35:28];\n"
    "    x[29:22]=state_n[43:36]; x[30]=1'b1;\n"
    "end else if(!state_r[44]) begin\n"
    "    f=1'b1; r=0; x=0; state_n=state_r;\n"
    "end else begin\n"
    + _scr_body() +
    "    wide2=c[0] ? {44'd0,a[19:0]} : {44'd0,ph[19:0]};\n"
    "    for(lane=0;lane<20;lane=lane+1) if(wide2[lane]) i=i+1;\n"
    "    for(lane=1;lane<20;lane=lane+1) if(wide2[lane]!=wide2[lane-1]) j=j+1;\n"
    "    mask=(wide2[0]!=state_r[19]);\n"
    "    state_n[19:0]=c[0] ? a[19:0] : ph[19:0];\n"
    "    state_n[27:20]=state_r[27:20]+8'd1;\n"
    "    state_n[35:28]=state_r[35:28]+i;\n"
    "    state_n[43:36]=state_r[43:36]+j;\n"
    "    r[19:0]=ph[19:0]; r[20]=a[20]; r[25:21]=i; r[30:26]=j;\n"
    "    if(j==0 && !mask) r[31]=1'b1;\n"
    "    x[0]=c[0]; x[1]=1'b1; x[5]=mask;\n"
    "    if(i<7 || i>13) x[4]=1'b1;\n"
    "    if(state_n[19:0]==20'h%05X) x[30]=1'b1;\n" % SEED20 +
    "    x[13:6]=state_n[27:20]; x[21:14]=state_n[35:28];\n"
    "    x[29:22]=state_n[43:36];\n"
    "    if(wide2=={44'd0,state_r[19:0]}) x[31]=1'b1;\n"
    "end\n"
)


def _m_scr20(a, b, c, state):
    """Exact model of BODY9: the unrolled self-synchronous scrambler tree."""
    if (a >> 21) or (c & 0x7FFFFFFC):
        return 0, 0, 1, state
    if (c >> 31) or (c >> 1) & 1:
        st = 0 if (c >> 31) else state
        st = _set_field(st, SR_REG, 20, SEED20)
        st = _set_field(st, SR_PRIMED, 1, 1)
        x = (c & 1) | (1 << 1) | (1 << 2) | ((1 if (c >> 31) else 0) << 3)
        x |= _field(st, SR_WORDS, 8) << 6
        x |= _field(st, SR_ONES, 8) << 14
        x |= _field(st, SR_TRANS, 8) << 22
        x |= 1 << 30
        return SEED20 | (((a >> 20) & 1) << 20), x & MASK, 0, st
    if not _field(state, SR_PRIMED, 1):
        return 0, 0, 1, state
    mode = c & 1
    reg = _field(state, SR_REG, 20)
    ph = 0
    for i in range(20):
        bit = (a >> i) & 1
        for tap in TAPS20:
            if i >= tap:
                bit ^= ((a >> (i - tap)) & 1) if mode else ((ph >> (i - tap)) & 1)
            else:
                bit ^= (reg >> (20 - tap + i)) & 1
        ph |= bit << i
    line = (a & 0xFFFFF) if mode else ph
    ones = bin(line).count('1')
    trans = sum(1 for i in range(1, 20) if ((line >> i) & 1) != ((line >> (i - 1)) & 1))
    boundary = int((line & 1) != ((reg >> 19) & 1))
    st = state
    st = _set_field(st, SR_REG, 20, line)
    st = _set_field(st, SR_WORDS, 8, (_field(st, SR_WORDS, 8) + 1) & 0xFF)
    st = _set_field(st, SR_ONES, 8, (_field(st, SR_ONES, 8) + ones) & 0xFF)
    st = _set_field(st, SR_TRANS, 8, (_field(st, SR_TRANS, 8) + trans) & 0xFF)
    r = ph | (((a >> 20) & 1) << 20) | ((ones & 0x1F) << 21) | ((trans & 0x1F) << 26)
    if trans == 0 and not boundary:
        r |= 1 << 31
    x = mode | (1 << 1) | (boundary << 5)
    if ones < 7 or ones > 13:
        x |= 1 << 4
    x |= _field(st, SR_WORDS, 8) << 6
    x |= _field(st, SR_ONES, 8) << 14
    x |= _field(st, SR_TRANS, 8) << 22
    if (st & 0xFFFFF) == SEED20:
        x |= 1 << 30
    if line == reg:
        x |= 1 << 31
    return r & MASK, x & MASK, 0, st


core('lvds_scramble20',
    'LVDS deserialiser scrambler: one 21-bit serializer word per accepted beat '
    '(a[19:0]=payload, a[20]=the K/control bit, a[31:21] must read zero). The '
    'polynomial is the published self-synchronous 1+x^-3+x^-6+x^-16+x^-20, so '
    'o_i = a_i ^ o_(i-3) ^ o_(i-6) ^ o_(i-16) ^ o_(i-20) where o is the line '
    'stream: with c[0]=0 the core scrambles (o is the word it emits, so the tap '
    'reads its own lower bits, which keeps the tree feed-forward) and with '
    'c[0]=1 it descrambles (o is the received word a, and the descrambler of a '
    'self-synchronous scrambler is the identical tree, which is why one core '
    'does both directions). c[1] re-primes the 20-bit register with the '
    'all-ones desynchroniser seed and keeps the statistics, c[31] restarts (the '
    'seed plus cleared statistics), and a prime or restart beat consumes no '
    'payload. Fault (result=aux=0, state kept): a reserved input bit is set, or '
    'a payload beat arrives before the engine was ever primed. State: 19:0 the '
    'line-stream register (emitted word when scrambling, received word when '
    'descrambling), 27:20 words since prime, 35:28 cumulative ones, 43:36 '
    'cumulative transitions, 44 primed. result[19:0]=the scrambled or '
    'descrambled word, [20]=the control bit passed through unscrambled, '
    '[25:21]=ones in the line word, [30:26]=transitions inside the line word, '
    '[31]=no transition anywhere in the word or at the word boundary (a '
    'run-length risk for the CDR). aux[0]=direction, [1]=primed, [2]=primed '
    'this beat, [3]=restarted this beat, [4]=the word is DC imbalanced (ones '
    'outside 7..13), [5]=a transition occurred at the word boundary, [13:6]= '
    'words since prime, [21:14]=cumulative ones, [29:22]=cumulative '
    'transitions, [30]=the register holds the seed, [31]=this word repeats the '
    'previous line word (a stalled or locked feeder).',
    BODY9,
    'A firmware scrambler is one XOR tree per bit with a shift-register access '
    'each bit time, so 20 bits cost 20 instruction cycles and the pattern is '
    'data-dependent; this core unrolls all 20 stages combinationally and emits a '
    'whole serializer word every enabled beat at II=1, with the running ones, '
    'transition and run-length statistics that a CDR bring-up needs coming out '
    'of the same cone.',
    1, stateful=True)

# ==========================================================================
# 10. Display-engine timing generator: one pixel clock retired per accepted
# beat.  Totals and porches are programmed once, everything after that is a
# counter, a compare and a subtract, so no multiplier is inferred.
# ==========================================================================
DT_X, DT_Y, DT_HT, DT_VT = 0, 10, 20, 32
DT_HA, DT_HS, DT_HB = 44, 54, 66
DT_VA, DT_VS, DT_VB = 78, 88, 100
DT_FRAMES, DT_STARTED = 112, 120


BODY10 = (
    "if(c[31]) begin\n"
    "    if(b[31]!=0 || c[30:0]!=0) begin\n"
    "        f=1'b1; r=0; x=0; state_n=state_r;\n"
    "    end else begin\n"
    "        pa={22'd0,a[9:0]};\n"
    "        pb=pa+{15'd0,a[16:10]};\n"
    "        pc=pb+{15'd0,a[24:17]};\n"
    "        ph=pc+{16'd0,a[30:25]};\n"
    "        temp={21'd0,b[10:0]};\n"
    "        mask=temp+{15'd0,b[18:11]};\n"
    "        ext=mask+{19'd0,b[22:19]};\n"
    "        wide=ext+{16'd0,b[30:23]};\n"
    "        if(pa==0 || temp==0 || a[24:17]==0 || b[22:19]==0 ||\n"
    "           ph>32'd1023 || wide>64'd1023) begin\n"
    "            f=1'b1; r=0; x=0; state_n=state_r;\n"
    "        end else begin\n"
    "            state_n=0;\n"
    "            state_n[53:44]=pa[9:0]; state_n[65:54]=pb[11:0];\n"
    "            state_n[77:66]=pc[11:0]; state_n[31:20]=ph[11:0];\n"
    "            state_n[87:78]=temp[9:0]; state_n[99:88]=mask[11:0];\n"
    "            state_n[111:100]=ext[11:0]; state_n[43:32]=wide[11:0];\n"
    "            state_n[120]=1'b1;\n"
    "        end\n"
    "    end\n"
    "end else begin\n"
    "    if(a[31:10]!=0 || b[31:10]!=0 || c!=0 || !state_r[120]) begin\n"
    "        f=1'b1; r=0; x=0; state_n=state_r;\n"
    "    end else begin\n"
    "        temp={21'd0,state_r[9:0]}+32'd1;\n"
    "        mask={21'd0,state_r[19:10]};\n"
    "        if(temp>={20'd0,state_r[31:20]}) begin\n"
    "            temp=0;\n"
    "            mask=mask+32'd1;\n"
    "            if(mask>={20'd0,state_r[43:32]}) begin\n"
    "                mask=0;\n"
    "                state_n[119:112]=state_r[119:112]+8'd1;\n"
    "            end\n"
    "        end\n"
    "        state_n[9:0]=temp[9:0]; state_n[19:10]=mask[9:0];\n"
    "    end\n"
    "end\n"
    "if(!f) begin\n"
    "    temp=state_n[9:0]; mask=state_n[19:10];\n"
    "    pa=state_n[53:44]; pb=state_n[65:54]; pc=state_n[77:66];\n"
    "    ph=state_n[31:20]; pl=state_n[87:78];\n"
    "    wide=state_n[99:88]; wide2=state_n[111:100];\n"
    "    ext=state_n[43:32];\n"
    "    r[9:0]=temp[9:0]; r[19:10]=mask[9:0];\n"
    "    if(temp<pa && mask<pl) r[20]=1'b1;\n"
    "    if(temp>=pb && temp<pc) r[21]=1'b1;\n"
    "    if(mask>=wide && mask<wide2) r[22]=1'b1;\n"
    "    if(mask<pl) r[23]=1'b1;\n"
    "    if(temp>=pa) begin\n"
    "        r[25:24]=2'd1;\n"
    "        if(temp>=pb) begin\n"
    "            r[25:24]=2'd2;\n"
    "            if(temp>=pc) r[25:24]=2'd3;\n"
    "        end\n"
    "    end\n"
    "    if(temp==0) r[26]=1'b1;\n"
    "    if(temp==ph-32'd1) r[27]=1'b1;\n"
    "    if(temp==0 && mask==0) r[28]=1'b1;\n"
    "    if(temp==ph-32'd1 && mask==ext-33'd1) r[29]=1'b1;\n"
    "    r[30]=c[31];\n"
    "    if(!c[31] && a[9:0]!=0 && ph>{22'd0,a[9:0]}) r[31]=1'b1;\n"
    "    x[9:0]=ph[9:0]; x[19:10]=ext[9:0];\n"
    "    if(mask==wide) x[20]=1'b1;\n"
    "    if(temp==pb) x[21]=1'b1;\n"
    "    if(temp==pa-32'd1 && mask<pl) x[22]=1'b1;\n"
    "    if(!c[31] && b[9:0]!=0 && ext>{23'd0,b[9:0]}) x[23]=1'b1;\n"
    "    x[31:24]=state_n[119:112];\n"
    "end\n"
)


def _m_de_timing(a, b, c, state):
    """Exact model of BODY10: programmed totals, per-beat raster advance."""
    if c >> 31:
        if (b >> 31) or (c & 0x7FFFFFFF):
            return 0, 0, 1, state
        ha = a & 0x3FF
        hss = ha + ((a >> 10) & 0x7F)
        hbs = hss + ((a >> 17) & 0xFF)
        ht = hbs + ((a >> 25) & 0x7F)
        va = b & 0x7FF
        vss = va + ((b >> 11) & 0xFF)
        vbs = vss + ((b >> 19) & 0xF)
        vt = vbs + ((b >> 23) & 0xFF)
        if not ha or not va or not ((a >> 17) & 0xFF) or not ((b >> 19) & 0xF) \
           or ht > 1023 or vt > 1023:
            return 0, 0, 1, state
        st = 0
        for pos, width, value in ((DT_HA, 10, ha), (DT_HS, 12, hss), (DT_HB, 12, hbs),
                                  (DT_HT, 12, ht), (DT_VA, 10, va), (DT_VS, 12, vss),
                                  (DT_VB, 12, vbs), (DT_VT, 12, vt), (DT_STARTED, 1, 1)):
            st = _set_field(st, pos, width, value)
    else:
        if (a >> 10) or (b >> 10) or c or not _field(state, DT_STARTED, 1):
            return 0, 0, 1, state
        st = state
        pos_x = _field(state, DT_X, 10) + 1
        pos_y = _field(state, DT_Y, 10)
        if pos_x >= _field(state, DT_HT, 12):
            pos_x = 0
            pos_y += 1
            if pos_y >= _field(state, DT_VT, 12):
                pos_y = 0
                st = _set_field(st, DT_FRAMES, 8, (_field(st, DT_FRAMES, 8) + 1) & 0xFF)
        st = _set_field(st, DT_X, 10, pos_x)
        st = _set_field(st, DT_Y, 10, pos_y)
    ha = _field(st, DT_HA, 10)
    hss, hbs, ht = _field(st, DT_HS, 12), _field(st, DT_HB, 12), _field(st, DT_HT, 12)
    va = _field(st, DT_VA, 10)
    vss, vbs, vt = _field(st, DT_VS, 12), _field(st, DT_VB, 12), _field(st, DT_VT, 12)
    px, py = _field(st, DT_X, 10), _field(st, DT_Y, 10)
    r = px | (py << 10)
    if px < ha and py < va:
        r |= 1 << 20
    if hss <= px < hbs:
        r |= 1 << 21
    if vss <= py < vbs:
        r |= 1 << 22
    if py < va:
        r |= 1 << 23
    r |= (0 if px < ha else 1 if px < hss else 2 if px < hbs else 3) << 24
    if px == 0:
        r |= 1 << 26
    if px == ht - 1:
        r |= 1 << 27
    if px == 0 and py == 0:
        r |= 1 << 28
    if px == ht - 1 and py == vt - 1:
        r |= 1 << 29
    if c >> 31:
        r |= 1 << 30
    elif (a & 0x3FF) and ht > (a & 0x3FF):
        r |= 1 << 31
    aux = (ht & 0x3FF) | ((vt & 0x3FF) << 10)
    if py == vss:
        aux |= 1 << 20
    if px == hss:
        aux |= 1 << 21
    if px == ha - 1 and py < va:
        aux |= 1 << 22
    if not (c >> 31) and (b & 0x3FF) and vt > (b & 0x3FF):
        aux |= 1 << 23
    aux |= _field(st, DT_FRAMES, 8) << 24
    return r & MASK, aux & MASK, 0, st


core('de_timing',
    'Display-engine timing generator: one pixel clock of the raster is retired '
    'per accepted beat, so a line of H_TOTAL clocks takes exactly H_TOTAL beats '
    'and a frame takes H_TOTAL*V_TOTAL beats, all counted in fabric. A program '
    'beat is c[31]=1 with the totals in a and b and c[30:0]=0: a[9:0]=H_ACTIVE, '
    'a[16:10]=H front porch, a[24:17]=H sync width, a[30:25]=H back porch, '
    'b[10:0]=V_ACTIVE, b[18:11]=V front porch, b[22:19]=V sync width (lines), '
    'b[30:23]=V back porch, b[31]=0; the totals are built with three adds each '
    '(no multiply) and the beat plots clock (0,0) of the new frame, clearing the '
    'frame counter. A step beat carries the feeder budgets a[9:0]=clocks per '
    'line available, b[9:0]=lines per frame available (0 = unbounded), with '
    'a[31:10]=b[31:10]=c=0. Fault (result=aux=0, state kept): a reserved field '
    'is nonzero, a zero active area or zero sync width was programmed, a total '
    'exceeds the 1024-clock raster counter, or a step arrives before the '
    'generator was programmed. State: 9:0 x, 19:10 y, 31:20 H_TOTAL, 43:32 '
    'V_TOTAL, 53:44 H_ACTIVE, 65:54 hsync start, 77:66 back-porch start, 87:78 '
    'V_ACTIVE, 99:88 vsync start, 111:100 V back-porch start, 119:112 completed '
    'frames, 120 programmed. result[9:0]=x, [19:10]=y, [20]=data-enable (inside '
    'both active windows), [21]=inside the hsync pulse, [22]=inside the vsync '
    'pulse, [23]=inside the vertical active window, [25:24]=horizontal phase '
    '(0 active, 1 front porch, 2 sync, 3 back porch), [26]=line start, '
    '[27]=line end, [28]=frame start, [29]=frame complete, [30]=this beat '
    'programmed the generator, [31]=H_TOTAL exceeds the line budget just '
    'presented. aux[9:0]=H_TOTAL, [19:10]=V_TOTAL, [20]=vsync rising strobe, '
    '[21]=hsync rising strobe, [22]=last active clock of an active line, [23]= '
    'V_TOTAL exceeds the frame budget just presented, [31:24]=frames completed.',
    BODY10,
    'A timing generator in firmware is a decrementing counter plus three '
    'compares and a branch per pixel clock, and its output skew depends on '
    'interrupt latency; this core issues de, hsync, vsync, the phase code and '
    'the coordinates for one pixel clock every enabled beat at II=1 from one '
    'unbroken counter cone, so every line and frame edge is exact and the '
    'budget flags prove the feeder can keep up before the first pixel moves.',
    1, stateful=True)


# ==========================================================================
# Module API: the catalog binds step/vectors/tables/selftest for every core in
# this family, so nothing below dispatches by hand.
# ==========================================================================
MODELS = {
    'rgb2yuv709': _m_rgb2yuv,
    'yuv2rgb709': _m_yuv2rgb,
    'yuv420_pack': _m420pack,
    'yuv422_unpack': _m422unpack,
    'osd_blend_u8': _m_blend,
    'chroma_key': _m_ckey,
    'bresenham_step': _m_bres,
    'sprite_blend': _m_sprite,
    'lvds_scramble20': _m_scr20,
    'de_timing': _m_de_timing,
}
assert sorted(MODELS) == sorted(entry['name'] for entry in CORES), \
    'every video core needs an independent integer model'


def step(name, a, b, c, state=0):
    """(result, aux, fault, new_state) for one accepted beat of `name`."""
    model = MODELS.get(name)
    if model is None:
        raise ValueError(name)
    r, x, f, new_state = model(a, b, c, state)
    return r & MASK, x & MASK, int(bool(f)), new_state


def vectors(name, count=320):
    """Board set first: rows 0..127 are hand-placed so every lane, window edge,
    restart and fault path is exercised on the hardware, then seeded legal
    stimulus continues the run.  See the VECTORS table at the end of the file."""
    builder = VECTORS.get(name)
    if builder is None:
        raise ValueError(f'{name}: no board vector set authored in fam_video')
    return builder(count)


def _pad(rows, name, count, maker):
    """Extend a hand-placed board set with seeded stimulus from the legal domain."""
    rng = Random(0x1B0B0000 + sum(name.encode()))
    while len(rows) < count:
        rows.append(maker(rng))
    return rows[:count]


def planes(rgb):
    """Up to four (r, g, b) pixels -> the (a, b, c) plane words of BODY1/BODY5."""
    return (pack4([p[0] for p in rgb]), pack4([p[1] for p in rgb]),
            pack4([p[2] for p in rgb]))


RGB_CORNERS = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0), (0, 0, 255),
               (255, 255, 0), (0, 255, 255), (255, 0, 255)]
RGB_STUDIO = [(16, 16, 16), (235, 235, 235), (128, 128, 128), (85, 85, 85),
              (170, 85, 0), (255, 85, 85), (0, 170, 170), (90, 90, 240)]


def _v_rgb2yuv(count):
    """BODY1 board set: named colours in every lane, then a monotone luma ramp."""
    rows = []
    for index, colour in enumerate(RGB_CORNERS + RGB_STUDIO):
        quad = [(128, 128, 128)] * 4
        quad[index % 4] = colour                      # the tested lane rotates
        rows.append(planes(quad))
    for i in range(96):                               # rows 16..111
        green = 2 * i                                 # Y rises 1.228 codes a step
        rows.append(planes([(0, green, 0)] * 4))
    mixed = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (240, 16, 16)]
    for i in range(16):                               # rows 112..127 chroma detail
        quad = [(16 * i, 255 - i, 8 * i), (0, 0, 0), (255, 255, 255), (16, 240, 16)]
        quad[i % 4] = mixed[i % 4]                    # one saturated lane per beat
        rows.append(planes(quad))
    return _pad(rows, 'rgb2yuv709', count,
                lambda rng: (rng.getrandbits(32), rng.getrandbits(32),
                             rng.getrandbits(32)))


def _yuv_pair(y0, cb0, cr0, y1, cb1, cr1):
    return (y0 | (cb0 << 8) | (cr0 << 16) | (y1 << 24), cb1 | (cr1 << 8), 0)


def _v_yuv2rgb(count):
    """BODY2 board set: neutral-chroma ramp, gamut corners, illegal-code faults."""
    rows = []
    for i in range(96):                               # rows 0..95, monotone in R0
        rows.append(_yuv_pair(16 + i, 128, 128, 200, 128, 128))
    chroma = [(16, 16), (16, 240), (240, 16), (240, 240), (128, 16), (16, 128),
              (128, 240), (240, 128), (17, 127), (129, 239), (240, 16)]
    for i, (cb, cr) in enumerate(chroma):             # rows 96..106 gamut corners
        rows.append(_yuv_pair(16 + 20 * i, cb, cr, 120, cr, cb))
    for i in range(8):                                # rows 107..114 illegal codes
        rows.append(_yuv_pair(16 * i if i else 0, 128, 128, 235, i * 30, 255 - i))
    for i in range(10):                               # rows 115..124 mixed pair
        rows.append(_yuv_pair(16 + 20 * i, 16 + 22 * i, 240 - 20 * i,
                              235 - 15 * i, 128, 128))
    good = _yuv_pair(100, 128, 128, 100, 128, 128)
    rows.append((good[0], good[1] | (1 << 16), 0))    # reserved b[31:16] set
    rows.append((good[0], good[1] | (0xFFFF << 16), 0))
    rows.append((good[0], good[1], 1))                # c must read zero
    return _pad(rows, 'yuv2rgb709', count,
                lambda rng: (rng.getrandbits(32), rng.getrandbits(16),
                             rng.randint(1, 15) if rng.random() < 0.05 else 0))
def _v_yuv420_pack(count):
    """BODY3 board set: one whole 32x8 frame in 128 beats, plus both reject paths."""
    rng = Random(0x420C0DE5)
    rows = []
    beats = 0                                   # accepted macropixels since restart
    for i in range(count):
        idx = beats % 8
        parity = (idx >> 1) & 1                 # the feeder-declared row parity
        control = 0
        if i < BOARD_ROWS:
            cb = 16 + (i * 7) % 225             # sweeps the studio chroma window
            cr = 16 + (i * 11) % 225
            y0, y1 = (i * 3) & 0xFF, (255 - 2 * i) & 0xFF
            if i == 0 or i == 127:              # restart, and the beat is accepted
                control, parity, beats = 1 << 31, 0, 0
            elif i == 44:                       # the parity lies: odd-field reject
                rows.append((pack4([y0, cb, y1, cr]), parity ^ 1, 0))
                continue
            elif i == 45:                       # reserved b[31:1]
                rows.append((pack4([y0, cb, y1, cr]), parity | (1 << 12), 0))
                continue
            elif i in (60, 61):                 # legal beat, chroma off-window
                cb, cr = 250, 0
            elif i in (92, 93):                 # Y0==Y1 plus an exact average
                y0 = y1 = 16 + i
        else:
            cb, cr = rng.randint(16, 240), rng.randint(16, 240)
            y0, y1 = rng.getrandbits(8), rng.getrandbits(8)
            if rng.random() < 0.02:
                control, parity, beats = 1 << 31, 0, 0
        rows.append((pack4([y0, cb, y1, cr]), parity, control))
        beats += 1
    return rows


def _v_yuv422_unpack(count):
    """BODY4 board set: both byte-lane maps, legality rejects, phase and counter."""
    rng = Random(0x422C0DE5)
    rows = []
    phase = 0
    for i in range(count):
        cb = 16 + (i * 5) % 225
        cr = 16 + (i * 13) % 225
        y0, y1 = i & 0xFF, (200 - i) & 0xFF
        toggle, control, bad_b = 1, 0, 0
        if i < BOARD_ROWS:
            if i in (30, 31, 78):                       # chroma outside 16..240
                cb, cr = (8, 245) if i != 31 else (0, 128)
            elif i == 60:
                control = 1 << 31                      # restart phase and counter
            elif i == 61:
                control = 1 << 2                       # reserved c lane
            elif i == 62:
                control = 1 << 30                      # reserved c lane
            elif i == 63:
                bad_b = 1 << 7                         # b must read zero
            elif i == 90:                              # luma off-window, chroma on edge
                y0, y1, cb, cr = 0, 255, 16, 240
            elif i == 126:
                toggle = 0                             # freeze the lane phase once
        else:
            cb, cr = rng.randint(16, 240), rng.randint(16, 240)
            y0, y1 = rng.getrandbits(8), rng.getrandbits(8)
            control = 1 << 31 if rng.random() < 0.02 else 0
            toggle = 0 if control else rng.randint(0, 1)
        word = pack4([cb, y0, cr, y1]) if phase else pack4([y0, cb, y1, cr])
        rows.append((word, bad_b, control | toggle))
        if control >> 31:                              # accepted restart wins
            phase = toggle
        elif i not in (30, 31, 61, 62, 63, 78):        # the rejects keep state
            if toggle:
                phase ^= 1
    return rows


def _v_osd_blend_u8(count):
    """BODY5 board set: a monotone alpha ramp plus every fast path, lane by lane."""
    rows = []
    for i in range(96):                               # rows 0..95
        # lane 0 transparent, lane 1 opaque, lane 2 ramps the alpha, lane 3 fg==bg
        rows.append((pack4([255, 0, 255, 40 + i]), pack4([10, 250, 0, 40 + i]),
                     pack4([0, 255, i + 1, 127])))
    for i in range(16):                               # rows 96..111 half-way ties
        rows.append((pack4([i * 16, 255, 0, 128]), pack4([255 - i * 16, 0, 255, 128]),
                     pack4([127, 128, 129, i * 16 + 1])))
    for k in range(4):                                # rows 112..115 one lane at a time
        rows.append((pack4([200 if m == k else 60 for m in range(4)]),
                     pack4([20 if m == k else 60 for m in range(4)]),
                     pack4([17 * (k + 3) if m == k else 0 for m in range(4)])))
    rows.append((pack4([255, 255, 255, 255]), pack4([0, 0, 0, 0]),
                 pack4([1, 64, 128, 254])))
    rows.append((pack4([0, 0, 0, 0]), pack4([255, 255, 255, 255]),
                 pack4([3, 96, 192, 251])))
    for i in range(10):                               # rows 118..127 fast/mix mixes
        rows.append((pack4([255, 255 - i, 0, 20 * i]), pack4([0, 255 - i, 255, 255 - 20 * i]),
                     pack4([4 + 25 * i, 127, 128, 255 - i])))
    return _pad(rows, 'osd_blend_u8', count,
                lambda rng: (rng.getrandbits(32), rng.getrandbits(32),
                             rng.getrandbits(32)))


CK_GREEN = (96, 144)


def _v_chroma_key(count):
    """BODY6 board set: restart, box and diamond programs, distance ramp, rejects."""
    rng = Random(0xCE0A5E5)
    rows = []
    for i in range(count):
        if i >= BOARD_ROWS:                            # seeded legal traffic
            control = 0
            if rng.random() < 0.04:                    # program a fresh window
                control |= 1 << 25
            if rng.random() < 0.02:                    # restart to the default window
                control |= 1 << 31
            if rng.random() < 0.03:                    # reserved control lane
                control |= 1 << rng.randint(26, 30)
            centre = (rng.randint(16, 240), rng.randint(16, 240))
            if control >> 25 & 1:
                control |= centre[0] | (centre[1] << 8)
                control |= rng.getrandbits(4) << 16
                control |= rng.getrandbits(4) << 20
                control |= rng.getrandbits(1) << 24
            rows.append((pack4([rng.randint(0, 255) for _ in range(4)]),
                         pack4([rng.randint(0, 255) for _ in range(4)]), control))
            continue
        if i == 0:                                     # restart: window (128,128,0,0)
            rows.append((pack4([128, 128, 128, 128]), pack4([128, 128, 128, 128]), 1 << 31))
            continue
        if i == 1:                                     # program a box key
            rows.append((pack4([110, 110, 110, 110]), pack4([130, 130, 130, 130]),
                         (1 << 25) | 110 | (130 << 8) | (4 << 16) | (5 << 20)))
            continue
        if 2 <= i <= 101:                              # rows 2..101: distance ramp
            k = i - 2                                  # r[31:24] = k, unique per row
            rows.append((pack4([110 + k, 110 + k // 4, 110, max(110 - k, 0)]),
                         pack4([130, 130, 130, 130]), 0))
            continue
        if i == 102:                                   # program the diamond metric
            rows.append((pack4([110, 110, 110, 110]), pack4([130, 130, 130, 130]),
                         (1 << 25) | 110 | (130 << 8) | (3 << 16) | (4 << 20) | (1 << 24)))
            continue
        if 103 <= i <= 112:                            # diamond sweeps: d = db + dr
            k = i - 103
            rows.append((pack4([110 + 5 * k, 110, 110 - 2 * k, 110 + k]),
                         pack4([130 + 3 * k, 130, 130 - k, 130 + 2 * k]), 0))
            continue
        if i == 113:                                   # reserved c[26]
            rows.append((pack4([110, 110, 110, 110]), pack4([130] * 4), 1 << 26))
            continue
        if i == 114:                                   # reserved c[29]
            rows.append((pack4([110, 110, 110, 110]), pack4([130] * 4), 1 << 29))
            continue
        if i == 115:                                   # centre anchored off-window
            rows.append((pack4([250, 110, 110, 110]), pack4([130] * 4),
                         (1 << 25) | 250 | (130 << 8) | (2 << 16) | (2 << 20)))
            continue
        if i == 116:                                   # restart and program in one beat
            rows.append((pack4([CK_GREEN[0]] * 4), pack4([CK_GREEN[1]] * 4),
                         (1 << 31) | (1 << 25) | CK_GREEN[0] | (CK_GREEN[1] << 8)
                         | (6 << 16) | (2 << 20)))
            continue
        k = i - 117                                    # rows 117..127 window edges
        rows.append((pack4([CK_GREEN[0] + 90 + k, CK_GREEN[0], CK_GREEN[0] + 96,
                            CK_GREEN[0] + 97]),
                     pack4([CK_GREEN[1], CK_GREEN[1] + k, CK_GREEN[1] + 8 * k, 144]), 0))
    return rows


def _bres_primitive(rows, x0, y0, x1, y1):
    """Program one line and step it to completion, tagging each step beat.

    The tag is the row index, which BODY7 echoes to aux[7:0], so no two step
    beats in the board set can produce the same response.
    """
    rows.append((x0 | (y0 << 8), x1 | (y1 << 8), 1 << 31))
    maj = max(abs(x1 - x0), abs(y1 - y0))
    for _ in range(maj):
        rows.append((len(rows) & 0xFF, 0, 0))


def _v_bresenham_step(count):
    """BODY7 board set: six octant variants, a degenerate point, every reject."""
    rng = Random(0x8CE500)
    rows = [(5, 0, 0)]                            # a step before any program
    _bres_primitive(rows, 0, 0, 4, 2)             # shallow, both axes up
    rows.append((7, 0, 0))                        # a step after the line completed
    rows.append((0, 0, 1 << 2))                   # reserved c lane on a step
    _bres_primitive(rows, 30, 20, 90, 35)         # shallow, x up, y up steeply-ish
    _bres_primitive(rows, 200, 190, 170, 175)     # shallow, both axes down
    _bres_primitive(rows, 10, 10, 14, 26)         # steep, both axes up
    _bres_primitive(rows, 77, 88, 77, 88)         # degenerate single pixel
    rows.append((1 << 20, 0, 1 << 31))            # reserved a field on a program
    _bres_primitive(rows, 60, 200, 59, 195)       # steep, both axes down
    _bres_primitive(rows, 250, 3, 252, 1)         # shallow, x up, y down at the edge
    while len(rows) < count:
        if len(rows) < BOARD_ROWS:                # never split a scripted primitive
            break
        x0, y0 = rng.randint(0, 200), rng.randint(0, 200)
        maj = rng.randint(1, 12)
        _bres_primitive(rows, x0, y0, min(x0 + maj, 255),
                        max(min(y0 + rng.randint(0, maj), 255), 0))
    return rows[:count] if len(rows) > count else rows


def _v_sprite_blend(count):
    """BODY8 board set: an anti-alias ramp, the whole palette, then the rejects."""
    rng = Random(0x5FADE000)
    rows = []
    for i in range(96):                           # rows 0..95: coverage ramp, white on black
        rows.append((0xFFFF | (i << 16), 0, 0))
    for index in range(16):                       # rows 96..111: every palette entry
        rows.append((0x1111 * index | 0x88880000, 0x40404040, index & 3))
    for ch in range(4):                           # rows 112..115: force opaque
        rows.append((0x1111 * 12 | 0x11110000, 0x77777777, 8 | ch))
    for ch in range(4):                           # rows 116..119: invert coverage
        rows.append((0x1111 * 9 | 0x75310000, 0x11111111, 4 | ch))
    rows.append((0x0000 | 0xFFFF0000, 0x20406080, 0))     # colour key over ink
    rows.append((0x0808 | 0x0000FFFF, 0x20406080, 1))     # 50% glass, half coverage
    rows.append((0xFFF0 | 0x0FFF0000, 0xA5A5A5A5, 2))     # mixed run and coverage
    rows.append((0x0123 | 0x45670000, 0x0F1E2D3C, 3))     # four indices, alpha plane
    rows.append((0xDDDD | 0x0000FFFF, 0x00000000, 0))     # dark grey on black
    rows.append((0xAAAA | 0xAAAA0000, 0xFFFFFFFF, 1))     # green on white
    rows.append((0x1111, 0x22222222, 1 << 4))             # reserved c[4]
    rows.append((0x1111, 0x22222222, 1 << 8))             # reserved c lane
    rows.append((0x1111, 0x22222222, 1 << 31))            # reserved c lane
    while len(rows) < count:
        control = rng.getrandbits(4)
        if rng.random() < 0.02:
            control |= 1 << rng.randint(4, 31)            # malformed control word
        rows.append((rng.getrandbits(32), rng.getrandbits(32), control))
    return rows[:count]


def _v_lvds_scramble20(count):
    """BODY9 board set: a prime/seed beat, a scramble run, then its own recovery.

    Rows 1..2 are the prime beats (restart, then re-prime) and row 0 is the
    payload-before-prime reject.  Rows 3..62 scramble a fixed payload run; the
    emitted line words are recorded and rows 63..122 feed them back with c[0]=1,
    so the same core must return the original payload words -- the self-checking
    property of a self-synchronous scrambler.  aux[13:6] is the words-since-prime
    counter, which increments once per accepted payload beat, so no two payload
    beats in the board set can share a response.
    """
    rng = Random(0x5CA9B0E0)
    rows = [(0x12345, 0, 0),                            # row 0: payload, never primed
            (SEED20, 0, 1 << 31),                       # row 1: restart primes the seed
            (SEED20 | (1 << 20), 0, 2)]                 # row 2: re-prime, statistics kept
    anchors = [0x00000, 0xFFFFF, 0x55555, 0xAAAAA, 0x00001, 0x80000,
               0x000FF, 0xFF000, 0x12345, 0x6C39C, 0x77777, 0x000AA,
               0x33333, 0xCCCCC, 0x05555, 0x0AAA5, 0xFFFFE, 0x00007]
    payload = list(anchors)
    while len(payload) < 60:
        payload.append(rng.getrandbits(20))
    state = 0
    emitted = []
    for index, word in enumerate(payload):
        line = word | ((1 << 20) if index % 3 == 0 else 0)   # K bit every third beat
        r, _, _, state = step('lvds_scramble20', line, 0, 0, state)
        emitted.append(r & SEED20)
        rows.append((line, 0, 0))                       # rows 3..62: scramble
    rows.extend((word, 0, 1) for word in emitted)       # rows 63..122: recover
    rows += [(0x12345, 0, 4),                           # row 123: reserved c[2]
             (0x12345, 0, 1 << 30),                     # row 124: reserved c lane
             (1 << 21, 0, 0),                           # row 125: reserved a lane
             (1 << 31, 0, 0),                           # row 126: reserved a lane
             (SEED20 ^ 0x0AA55, 0, 3)]                  # row 127: re-prime, direction set
    while len(rows) < count:                            # seeded line traffic
        control = rng.choice((0, 0, 0, 1, 2, 3))
        if rng.random() < 0.03:
            control |= 1 << rng.randint(2, 30)          # malformed control word
        word = rng.getrandbits(20) | ((1 << 20) if rng.random() < 0.25 else 0)
        rows.append((word, 0, control))
    return rows[:count]


def _v_de_timing(count):
    """BODY10 board set: program, walk the raster, reject bad programs and steps.

    Row 0 steps an unprogrammed generator (reject).  Row 1 programs the published
    VGA 640x480@60 totals -- 640+16+96+48 = 800 clocks and 480+10+2+33 = 525 lines
    -- and rows 2..65 retire the first 64 pixel clocks of the active line, with
    the feeder budgets riding in a[9:0] and b[9:0] so the H_TOTAL/V_TOTAL budget
    flags fire on exactly the rows whose budget is short.  Row 66 switches to a
    compact 8x6 test raster whose 48 clocks are one whole frame, so rows
    67..114 cover every horizontal phase code, both porch edges, line start/end,
    vsync and the frame-complete strobe without spending 800 beats to get there.
    Rows 115..124 are program/step rejects (zero sync width, an H_TOTAL of 1086
    that overflows the 1024-clock counter, zero V_ACTIVE, zero vertical sync,
    reserved lanes in a, b and c), row 125 programs the published 720x480 CEA-861
    raster (858x525) and rows 126..127 step it.  Because aux[9:0] carries H_TOTAL,
    rows in different rasters cannot collide, and inside one raster every step
    beat reports a distinct (x,y) coordinate.
    """
    rng = Random(0x71DE71D0)
    vga_a = 640 | (16 << 10) | (96 << 17) | (48 << 25)      # H_TOTAL 800
    vga_b = 480 | (10 << 11) | (2 << 19) | (33 << 23)       # V_TOTAL 525
    rows = [(0, 0, 0), (vga_a, vga_b, 1 << 31)]
    for i in range(64):                                     # rows 2..65
        budget = 800 if i % 4 else 16 + (i & 0xF)           # short budget every 4th row
        lines = 525 if i % 8 else 8 + (i & 7)
        rows.append((budget, lines, 0))
    test_a = 4 | (1 << 10) | (2 << 17) | (1 << 25)          # 8 clocks per line
    test_b = 2 | (1 << 11) | (1 << 19) | (2 << 23)          # 6 lines per frame
    rows.append((test_a, test_b, 1 << 31))                  # row 66: compact raster
    rows.extend((0, 0, 0) for _ in range(48))               # rows 67..114: one frame
    rows += [(4 | (1 << 10) | (0 << 17) | (1 << 25), test_b, 1 << 31),   # zero sync width
             (1020 | (1 << 10) | (2 << 17) | (63 << 25),
              test_b, 1 << 31),                                      # H_TOTAL 1086 > 1023
             (test_a, 0 | (1 << 11) | (1 << 19) | (2 << 23), 1 << 31),   # zero V_ACTIVE
             (test_a, test_b & ~(0xF << 19), 1 << 31),                   # zero V sync
             (test_a, vga_b | (1 << 31), 1 << 31),                        # b[31] reserved
             (test_a, test_b, (1 << 31) | 1),                             # c[30:0] != 0
             (0, 0, 1),                                                   # step with c != 0
             (1 << 10, 0, 0),                                             # a[31:10] reserved
             (0, 1 << 10, 0),                                             # b[31:10] reserved
             (1 << 10, 1 << 10, 1 << 31)]                                 # reserved program
    cea_a = 720 | (16 << 10) | (62 << 17) | (60 << 25)      # H_TOTAL 858
    cea_b = 480 | (7 << 11) | (3 << 19) | (35 << 23)        # V_TOTAL 525
    rows.append((cea_a, cea_b, 1 << 31))                    # row 125: 858x525
    rows += [(0, 0, 0), (858, 525, 0)]                      # rows 126..127
    while len(rows) < count:
        if rng.random() < 0.2:
            ha, va = rng.randint(1, 512), rng.randint(1, 256)
            rows.append((ha | (rng.randint(0, 63) << 10) | (rng.randint(1, 127) << 17)
                         | (rng.randint(0, 63) << 25),
                         va | (rng.randint(0, 127) << 11) | (rng.randint(1, 15) << 19)
                         | (rng.randint(0, 127) << 23), 1 << 31))
        else:
            rows.append((rng.randint(0, 1023), rng.randint(0, 1023), 0))
    return rows[:count]


VECTORS = {
    'rgb2yuv709': _v_rgb2yuv,
    'yuv2rgb709': _v_yuv2rgb,
    'yuv420_pack': _v_yuv420_pack,
    'yuv422_unpack': _v_yuv422_unpack,
    'osd_blend_u8': _v_osd_blend_u8,
    'chroma_key': _v_chroma_key,
    'bresenham_step': _v_bresenham_step,
    'sprite_blend': _v_sprite_blend,
    'lvds_scramble20': _v_lvds_scramble20,
    'de_timing': _v_de_timing,
}
# >>>CONTINUE<<<


def _v_pop(value):
    """Number of set bits, written here so a count never leans on a kernel."""
    return bin(value & MASK).count('1')


def _v_sg(value, low, bits):
    """Signed read of `bits` bits at `low`, two's complement."""
    raw = _field(value, low, bits)
    return raw - (1 << bits) if raw >> (bits - 1) else raw


def _v_run(name, rows, state=0):
    """Feed (a, b, c) control rows through one core, threading the state.

    Returns the per-beat [(result, aux, fault, new_state)] list so a check can
    watch a whole stream instead of one hand-carried beat.
    """
    seen = []
    for a, b, c in rows:
        r, x, f, state = step(name, a, b, c, state)
        seen.append((r, x, f, state))
    return seen


def _v_rnd(exact):
    """Round half up of a Fraction without leaving rationals.

    selftest() derives every published weight this way, so a float rounding
    path in the module cannot certify itself.
    """
    value = F(exact)
    return (2 * value.numerator + value.denominator) // (2 * value.denominator)


# ==========================================================================
# selftest(): independent truth for all ten video cores.
#
# Contract: no arguments, returns the number of independent checks performed,
# raises AssertionError naming the core and the expectation when anything
# disagrees.  Nothing below replays an `m_*` mirror statement for statement:
# every expectation is re-derived here from closed-form geometry, published
# colour-matrix / palette / scrambler constants, or an algebraic identity that
# a wrong kernel must break (monotonicity, bit-exact identity path, involution,
# additivity, bounds on the reachable range).
#
# One invariant per core (the anchor each section is built around):
#   1. rgb2yuv709    BT.709 luma weights sum to QONE and grey R=G=B maps to the
#                    exact studio code; luma is monotone in each channel.
#   2. yuv2rgb709    neutral chroma round-trips to within one LSB and the
#                    signed accumulator's two rails clamp with the fault bit.
#   3. yuv420_pack   8 beats per 4x4 block, 128 beats per 32x8 frame, frame
#                    counter = floor(beats/128); average is round-half-up.
#   4. yuv422_unpack YUYV/UYVY lane maps are bijections one byte-pair rotation
#                    apart; the counter is a pure delay: it returns the
#                    macropixel index 1 beat earlier.
#   5. osd_blend_u8  alpha 0/255 bit-exact fast paths, monotone in alpha, and
#                    floor(x/255) fold proven exhaustively over its domain.
#   6. chroma_key    distance is a metric (box/diamond) and the decision is
#                    monotone in tolerance; N lanes give a sum of N classes.
#   7. bresenham_step after maj steps the cursor is exactly at the endpoint and
#                    minor moves happened exactly min times, all 8 octants.
#   8. sprite_blend  published CGA/RGBI palette re-derived from the bit pattern,
#                    coverage*17 identity, opaque/transparent bit-exactness.
#   9. lvds_scramble20 published 1+x^-3+x^-6+x^-16+x^-20 taps re-implemented as
#                    a serial LFSR; scramble is its own inverse; one line error
#                    bursts into exactly 5 bits.
#  10. de_timing     line advance = Htotal, frame advance = Htotal*Vtotal, and
#                    porch boundaries from the definition of the window.
#
# Corners the project has been burned by, covered below: 12-bit signed /
# saturated operand bounds (a -2048 negation cannot be represented, so the
# kernel must clamp and flag), wide-accumulator near-cancellation, and restart
# semantics on c[31].
# ==========================================================================
def selftest():
    """Readiness gate: returns a positive count of independent checks.

    Every expectation below is re-derived from a published constant, a
    closed-form geometric sum, or an algebraic identity (monotone boundary,
    bit-exact identity path, involution, additivity, range bound).  None of
    them replays an `m_*` mirror kernel statement for statement, because those
    mirrors are what the Verilog is generated from: a check that only restates
    one proves nothing about a kernel whose arithmetic is wrong.
    """
    checks = 0
    rng = Random(0x51DE0A7)          # seeded stimulus, replayable

    # -- 0. family structure and the no-multiply / no-divide fabric rule -----
    assert FAMILY == 'video', FAMILY
    assert len(CORES) == 10 and len({c['name'] for c in CORES}) == 10, \
        [c['name'] for c in CORES]
    assert sorted(c['name'] for c in CORES) == sorted(MODELS), 'every core needs a model'
    checks += 3
    for entry in CORES:
        bare = ' '.join(line.split('//')[0] for line in
                        (entry['body'] + entry.get('decl', '')).splitlines())
        assert entry['family'] == FAMILY and entry['spec'] and entry['advantage']
        assert entry['name'] in VECTORS and entry['lanes'] >= 1
        # The GW5A fabric multiplier is unsigned, so a `*` in a body is a
        # corruption waiting to happen, and `/` infers a divider: neither may
        # appear as an operator (a comment slash is harmless).
        assert '*' not in bare, entry['name'] + ': multiply operator in body'
        assert '/' not in bare, entry['name'] + ': divide operator in body'
        assert 'posedge' not in bare and 'negedge' not in bare, entry['name']
        checks += 5

    # -- 1. rgb2yuv709: the BT.709 studio matrix, re-derived not remembered ---
    # ITU-R BT.709-6 Table 2 luma coefficients, as published.  The chromaticity
    # solve carries more precision than the printed four decimals, so the
    # derived value must *round* to the published one.
    published = (2126, 7152, 722)
    for derived, want in zip((KR, KG, KB), published):
        assert _v_rnd(derived * 10000) == want, (float(derived), want)
        checks += 1
    assert KR + KG + KB == 1, 'the luma row must be a convex combination'
    checks += 1
    # Q10 studio weights, recomputed here from the exact rationals with
    # half-up rounding.  _q() rounds a float, which is the classic way to land
    # one code off on a .5 boundary, so it is not allowed to certify itself.
    want_y = tuple(_v_rnd(F(219) * k * QONE / 255) for k in (KR, KG, KB))
    kb2 = F(224, 255)
    want_cb = tuple(_v_rnd(kb2 * w * QONE) for w in
                    (-KR / (2 * (1 - KB)), -KG / (2 * (1 - KB)), F(1, 2)))
    want_cr = tuple(_v_rnd(kb2 * w * QONE) for w in
                    (F(1, 2), -KG / (2 * (1 - KR)), -KB / (2 * (1 - KR))))
    assert want_y == Y_W and want_cb == CB_W and want_cr == CR_W, \
        ('rgb2yuv709: published weights', want_y, Y_W, want_cb, CB_W, want_cr, CR_W)
    checks += 3
    # The chroma rows annihilate grey: their coefficients sum to exactly zero,
    # which is what puts R=G=B on the 128 footpoint (BT.709 Table 4).
    assert sum(CB_W) == 0 and sum(CR_W) == 0, 'chroma rows must sum to zero'
    # The luma row sums to the studio scale factor 219/255 in Q10, so grey is
    # mapped into 16..235 and not into full range.
    assert abs(sum(Y_W) - F(219, 255) * QONE) < 2, (sum(Y_W), float(F(219, 255) * QONE))
    checks += 2
    # Every emitted shift-add cone must equal the integer product it claims.
    # This is the check that catches a wrong canonical-signed-digit expansion,
    # and it is the only place a weight above 2047 (the inverse 2163, which no
    # signed 12-bit fabric multiplier can hold) is verified at all.
    for weight in (Y_W + CB_W + CR_W + (WL,) + tuple(x for row in INV_W for x in row)):
        for value in list(range(0, 256)) + [300, 1020, 900, 4]:
            assert _csd_value(weight, value) == weight * value, \
                ('cone vs product', weight, value, _csd_value(weight, value))
        checks += 1
    # The published matrix really does have the zero entries it is printed with:
    # R carries no Cb term and B carries no Cr term, so a stray term in the cone
    # would show up as a nonzero weight here.
    assert INV_W[0][1] == 0 and INV_W[2][2] == 0, 'inverse matrix zeros'
    checks += 1
    assert max(abs(x) for x in (INV_W[0][2], INV_W[2][1])) > 2047, \
        'rgb2yuv709/yuv2rgb709: the > 12-bit coefficient must stay in the shift net'
    checks += 1

    grey_bad = 0
    for code in range(256):
        planes = (pack4([code] * 4), pack4([code] * 4), pack4([code] * 4))
        r, x, f, _st = step('rgb2yuv709', planes[0], planes[1], planes[2], 0)
        want = min(235, max(16, (sum(Y_W) * code + 16 * QONE + HALF) >> QSH))
        if [(r >> (8 * k)) & 0xFF for k in range(4)] != [want] * 4:
            grey_bad += 1
        # grey is exactly the footpoint: a single wrong chroma coefficient
        # moves this off 128 and there is nowhere for it to hide.
        if (x & 0xFF) != 128 or ((x >> 8) & 0xFF) != 128:
            grey_bad += 1
        if _field(x, 24, 4) != 0xF or f or x >> 31:
            grey_bad += 1
        checks += 1
    assert grey_bad == 0, 'rgb2yuv709: grey must map to luma 16..235 and chroma 128'
    checks += 1

    # rgb2yuv709 behaviour: 4000 seeded groups checked against the exact
    # rational studio matrix (a quantisation bound a wrong kernel breaks), the
    # published integer formula, the status definitions and lane wiring.
    def site_int(weights, group):
        sums = [sum(p[i] for p in group) for i in range(3)]
        return (sum(w * s for w, s in zip(weights, sums))
                + (128 << QSUM) + HALFS) >> QSUM

    luma_off = chroma_off = formula_bad = status_bad = 0
    window_bad = tie_bad = 0
    for trial in range(4000):
        if trial % 5 == 0:
            base = (trial // 5) % 16
            group = [(RGB_CORNERS + RGB_STUDIO)[(base + k) % 16] for k in range(4)]
        else:
            group = [(rng.randrange(256), rng.randrange(256), rng.randrange(256))
                     for _ in range(4)]
        r, x, f, _st = step('rgb2yuv709', *(pack4([p[i] for p in group]) for i in range(3)), 0)
        assert f == 0 and x >> 31 == 0, ('rgb2yuv709 clamp fired', group, hex(x))
        window_bad += int(not 16 <= (x & 0xFF) <= 240 or not 16 <= ((x >> 8) & 0xFF) <= 240)
        mr = F(sum(p[0] for p in group), 4)
        mg = F(sum(p[1] for p in group), 4)
        mb = F(sum(p[2] for p in group), 4)
        ybar = KR * mr + KG * mg + KB * mb
        for want, exact in ((x & 0xFF, 128 + F(224) * (mb - ybar) / (2 * (1 - KB) * 255)),
                            ((x >> 8) & 0xFF, 128 + F(224) * (mr - ybar) / (2 * (1 - KR) * 255))):
            chroma_off += int(abs(F(want) - exact) >= 1)     # more than one LSB off published Y
        group_sums = [sum(p[i] for p in group) for i in range(3)]
        group_luma = (sum(w * s for w, s in zip(Y_W, group_sums))
                      + (16 << QSUM) + HALFS) >> QSUM
        for lane, (rr, gg, bb) in enumerate(group):
            acc = rr * Y_W[0] + gg * Y_W[1] + bb * Y_W[2] + 16 * QONE
            want = min(235, max(16, (acc + HALF) >> QSH))
            got = (r >> (8 * lane)) & 0xFF
            formula_bad += int(got != want)
            luma_off += int(abs(F(got) - (16 + F(219) * (KR * rr + KG * gg + KB * bb) / 255)) >= 1)
            status_bad += int(_field(x, 16 + lane, 1) != int((acc & (QONE - 1)) >= HALF))
            status_bad += int(_field(x, 24 + lane, 1) != int(rr == gg == bb))
            status_bad += int(_field(x, 20 + lane, 1) != int(abs(group_luma - want) >= 8))
            window_bad += int(not 16 <= got <= 235)
        # Edge-of-window status bits, from the definition of the studio codes.
        luma_edges = [byte_of(r, k) for k in range(4)]
        tie_bad += int(_field(x, 28, 1) != int(any(v in Y_LIMITS for v in luma_edges)))
        tie_bad += int(_field(x, 29, 1) != int((x & 0xFF) in C_LIMITS))
        tie_bad += int(_field(x, 30, 1) != int(((x >> 8) & 0xFF) in C_LIMITS))
    assert formula_bad == 0, 'rgb2yuv709: luma != the published Q10 studio formula'
    assert luma_off == 0 and chroma_off == 0, \
        'rgb2yuv709: output is more than one LSB from the exact BT.709 studio matrix'
    assert status_bad == 0, 'rgb2yuv709: rounding / achromatic / detail status bits wrong'
    assert window_bad == 0, 'rgb2yuv709: a studio code left its 16..235 / 16..240 window'
    assert tie_bad == 0, 'rgb2yuv709: window-edge status bits disagree with the codes'
    checks += 5

    # rgb2yuv709: a lane is computed from its own byte triple only, and the
    # published luma row has three positive coefficients, so raising any colour
    # can never lower that lane's code.
    base = [(17, 200, 90), (250, 3, 3), (0, 0, 255), (128, 128, 128)]
    r0 = step('rgb2yuv709', *(pack4([p[i] for p in base]) for i in range(3)), 0)[0]
    iso_bad = mono_bad = 0
    for lane in range(4):
        for other in range(4):
            if other == lane:
                continue
            for value in (0, 1, 127, 254, 255):
                alt = [list(p) for p in base]
                alt[other] = [value] * 3
                other_r = step('rgb2yuv709', *(pack4([p[i] for p in alt]) for i in range(3)), 0)[0]
                iso_bad += int(byte_of(other_r, lane) != byte_of(r0, lane))
        for channel in range(3):
            previous = -1
            for value in range(256):
                alt = [list(p) for p in base]
                alt[lane][channel] = value
                got = byte_of(step('rgb2yuv709',
                                   *(pack4([p[i] for p in alt]) for i in range(3)), 0)[0], lane)
                mono_bad += int(got < previous)
                previous = got
    assert iso_bad == 0, 'rgb2yuv709: a lane luma moved when another lane changed'
    assert mono_bad == 0, 'rgb2yuv709: luma is not monotone in its own colour channel'
    checks += 2

    # -- 2. yuv2rgb709: the inverse cone, checked against its own rails ------
    # Neutral chroma (Cb=Cr=128) cancels both chroma rows exactly, so all three
    # channels must return the same code, from one closed form, with the clamp
    # status following it.  This is the case where the accumulator nearly
    # cancels to zero, the region a shifted or mis-signed term shows up in.
    neutral_bad = 0
    for y in range(256):
        r, x, f, _st = step('yuv2rgb709', y | (128 << 8) | (128 << 16), 0, 0, 0)
        value = (WL * (y - 16) + HALF) >> QSH
        want = min(255, max(0, value))
        clamped = int(value < 0 or value > 255)
        if f or [byte_of(r, k) for k in range(3)] != [want] * 3:
            neutral_bad += 1
        neutral_bad += int(_field(x, 16, 1) != clamped)
        neutral_bad += int(_field(x, 20, 1) != 1 or _field(x, 22, 1) != 1)
        checks += 1
    assert neutral_bad == 0, 'yuv2rgb709: neutral chroma must give three equal codes'
    checks += 1

    # Published sparsity: the R row carries no Cb term and the B row no Cr term,
    # so those inputs cannot move those outputs even one bit.
    sparse_bad = 0
    for y in (0, 16, 100, 235, 255):
        for cr in (0, 16, 128, 240, 255):
            first = step('yuv2rgb709', y | (100 << 8) | (cr << 16), 0, 0, 0)
            second = step('yuv2rgb709', y | (150 << 8) | (cr << 16), 0, 0, 0)
            sparse_bad += int(byte_of(first[0], 0) != byte_of(second[0], 0))
            third = step('yuv2rgb709', y | (100 << 8) | (cr << 16), 0, 0, 0)
            fourth = step('yuv2rgb709', y | (100 << 8) | (min(255, cr ^ 37) << 16), 0, 0, 0)
            sparse_bad += int(byte_of(third[0], 2) != byte_of(fourth[0], 2))
    assert sparse_bad == 0, 'yuv2rgb709: a channel responded to a term its row does not have'
    checks += 1

    # Exact rational bound over the code cube axes: in-gamut output within one
    # LSB of the published rational inverse, and a rail clamp whenever the exact
    # value is provably outside 0..255.  This is BT.709's own inverse matrix,
    # written as rationals, not the kernel's fixed point.
    def exact_channel(y, cb, cr, channel):
        chroma = ((F(0), 2 * (1 - KR)),
                  (-2 * KB * (1 - KB) / KG, -2 * KR * (1 - KR) / KG),
                  (2 * (1 - KB), F(0)))[channel]
        return 255 * (F(y - 16, 219) + chroma[0] * F(cb - 128, 224)
                      + chroma[1] * F(cr - 128, 224))

    rail_bad = bound_bad = oow_bad = 0
    for y in range(0, 256, 1):
        for cb in (0, 15, 16, 17, 100, 128, 155, 239, 240, 241, 255):
            for cr in (0, 16, 128, 240, 255):
                r, x, f, _st = step('yuv2rgb709', y | (cb << 8) | (cr << 16), 0, 0, 0)
                assert f == 0
                for channel in range(3):
                    exact = exact_channel(y, cb, cr, channel)
                    got = byte_of(r, channel)
                    if exact <= -1:
                        rail_bad += int(got != 0 or _field(x, 16, 1) != 1)
                    elif exact >= 256:
                        rail_bad += int(got != 255 or _field(x, 16, 1) != 1)
                    elif F(1) <= exact <= F(254):
                        bound_bad += int(abs(F(got) - exact) >= 1)
                legal = (Y_LIMITS[0] <= y <= Y_LIMITS[1]
                         and C_LIMITS[0] <= cb <= C_LIMITS[1]
                         and C_LIMITS[0] <= cr <= C_LIMITS[1])
                oow_bad += int(_field(x, 24, 1) != int(not legal))
    assert rail_bad == 0, 'yuv2rgb709: outside-gamut input did not clamp to the rail and flag'
    assert bound_bad == 0, 'yuv2rgb709: in-gamut output is more than one LSB from BT.709'
    assert oow_bad == 0, 'yuv2rgb709: the studio-window status bit mis-reported the codes'
    checks += 3

    # The decoder really is the inverse of the encoder: a colour that survives
    # both quantisations comes back within the double-rounding bound.  Grey is
    # the provable case (the chroma rows annihilate), so it must be within one
    # LSB for all 256 levels, and the eight published RGB corners within one.
    def round_trip(colour):
        a, b, cc = (pack4([colour[i]] * 4) for i in range(3))
        r, x, f, _s = step('rgb2yuv709', a, b, cc, 0)
        assert f == 0
        y, cbs, crs = byte_of(r, 0), x & 0xFF, (x >> 8) & 0xFF
        out, xo, fo, _s = step('yuv2rgb709', y | (cbs << 8) | (crs << 16), 0, 0, 0)
        assert fo == 0
        return [byte_of(out, k) for k in range(3)], (y, cbs, crs), xo

    rt_bad = rt_grey = 0
    for colour in RGB_CORNERS + RGB_STUDIO:
        back, _codes, _xo = round_trip(colour)
        rt_bad += max(abs(got - want) for got, want in zip(back, colour)) > 1
    for code in range(256):
        back, _codes, _xo = round_trip((code, code, code))
        rt_grey += max(abs(got - code) for got in back) > 1
    assert rt_bad == 0, 'yuv2rgb709/rgb2yuv709: a published colour does not survive the round trip'
    assert rt_grey == 0, 'rgb2yuv709/yuv2rgb709 pair: grey is not reproduced within double rounding'
    checks += 2

    # Reserved fields: every set bit of b[31:16] or of c alone must reject the
    # beat as (result, aux, fault) = (0, 0, 1) with the state left untouched.
    reserved_bad = 0
    for bit in range(16, 32):
        r, x, f, st = step('yuv2rgb709', 63 | (102 << 8) | (240 << 16), 1 << bit, 0, 0x1234)
        reserved_bad += int((r, x, f, st) != (0, 0, 1, 0x1234))
    for bit in range(32):
        r, x, f, st = step('yuv2rgb709', 63 | (102 << 8) | (240 << 16), 0, 1 << bit, 0xABCD)
        reserved_bad += int((r, x, f, st) != (0, 0, 1, 0xABCD))
    assert reserved_bad == 0, 'yuv2rgb709: a reserved input field was accepted'
    checks += 1

    # Slot wiring: pixel 1 shares the beat with pixel 0 and its G and B spill
    # into aux[7:0] / aux[15:8].  Swapping the two pixels through the same beat
    # must hand back the same three bytes for each colour, one spread across
    # result+aux and the other packed in result[23:0].  No single-pixel test
    # can see this, and a lane mis-wire breaks it immediately.
    p0 = (63, 102, 240)          # decodes hot: R hits the 255 rail and clamps
    p1 = (250, 10, 200)          # both codes sit outside their studio window
    a0 = p0[0] | (p0[1] << 8) | (p0[2] << 16) | (p1[0] << 24)
    b0 = p1[1] | (p1[2] << 8)
    a1 = p1[0] | (p1[1] << 8) | (p1[2] << 16) | (p0[0] << 24)
    b1 = p0[1] | (p0[2] << 8)
    r, x, f, _s = step('yuv2rgb709', a0, b0, 0, 0)
    rs, xs, fs, _s = step('yuv2rgb709', a1, b1, 0, 0)
    assert f == 0 and fs == 0
    assert [rs & 0xFF, (rs >> 8) & 0xFF, (rs >> 16) & 0xFF] == [r >> 24, x & 0xFF, (x >> 8) & 0xFF], \
        'yuv2rgb709: pixel 1 bytes are not the same colour in the swapped beat'
    assert [r & 0xFF, (r >> 8) & 0xFF, (r >> 16) & 0xFF] == [rs >> 24, xs & 0xFF, (xs >> 8) & 0xFF], \
        'yuv2rgb709: pixel 0 bytes are not the same colour in the swapped beat'
    # ... and each pixel keeps its own clamp / achromatic / neutral / out-of-
    # window status when it moves slot: slot 1 reports them at aux[18]/[21]/
    # [23]/[25], slot 0 at aux[16]/[20]/[22]/[24].
    assert [_field(x, b, 1) for b in (18, 21, 23, 25)] == \
           [_field(xs, b, 1) for b in (16, 20, 22, 24)], \
        'yuv2rgb709: pixel 1 status did not follow the pixel into the second slot'
    assert [_field(xs, b, 1) for b in (18, 21, 23, 25)] == \
           [_field(x, b, 1) for b in (16, 20, 22, 24)], \
        'yuv2rgb709: pixel 0 status did not follow the pixel into the second slot'
    checks += 4

    # Clamped monotonicity: clamping a monotone cone keeps it monotone, so every
    # output byte is non-decreasing in Y, R in Cr, B in Cb and G in neither.
    for channel in (0, 1, 2):
        series = [byte_of(step('yuv2rgb709', y | (128 << 8) | (128 << 16), 0, 0, 0)[0], channel)
                  for y in range(256)]
        assert series == sorted(series), 'yuv2rgb709: output %d is not monotone in Y' % channel
        checks += 1
    r_series = [byte_of(step('yuv2rgb709', 128 | (128 << 8) | (cr << 16), 0, 0, 0)[0], 0)
                for cr in range(256)]
    assert r_series == sorted(r_series), 'yuv2rgb709: R is not monotone in Cr'
    b_series = [byte_of(step('yuv2rgb709', 128 | (cb << 8) | (128 << 16), 0, 0, 0)[0], 2)
                for cb in range(256)]
    assert b_series == sorted(b_series), 'yuv2rgb709: B is not monotone in Cb'
    g_series = [byte_of(step('yuv2rgb709', 128 | (cb << 8) | (128 << 16), 0, 0, 0)[0], 1)
                for cb in range(256)]
    assert g_series == sorted(g_series, reverse=True), 'yuv2rgb709: G is not monotone in Cb'
    checks += 3

    # -- 3. yuv420_pack: the block geometry is arithmetic, not a memory map ---
    # A 4x4 luma block is 8 macropixel beats, a 32x8 luma frame is 8 blocks wide
    # by 2 block rows, so exactly 128 beats per frame: every counter claim below
    # is closed-form geometry that a wrong block walk breaks on the first frame.
    name = 'yuv420_pack'
    rows = []
    for n in range(256):
        ycbcr = ((30 + n % 100), 16 + (n * 3) % 200, 60 + n % 70, 20 + (n * 5) % 200)
        rows.append((pack4(ycbcr), ((n % 8) >> 1) & 1, 1 << 31 if n == 0 else 0))
    seen = _v_run(name, rows)
    walk_bad = 0
    for n, (r, x, f, st) in enumerate(seen):
        idx = _field(x, 0, 3)
        walk_bad += int(f or idx != n % 8 or _field(x, 8, 4) != (n // 8) % BLK_X
                        or _field(x, 16, 3) != (n // 8) // BLK_X % BLK_Y)
        lane = ((n % 8) >> 1) & 1                             # 0 stores, 1 commits
        walk_bad += int(_field(x, 3, 1) != lane)               # row parity
        walk_bad += int(_field(x, 4, 1) != int(lane == 0))     # chroma stored
        walk_bad += int(_field(x, 5, 1) != int(lane == 1))     # chroma committed
        walk_bad += int(_field(x, 6, 1) != int(n % 8 in (3, 7)))           # row pair
        walk_bad += int(_field(x, 7, 1) != int(n % 8 == 7))                # block
        walk_bad += int(_field(x, 24, 1) != int(n % 128 == 127))           # frame
        walk_bad += int(_field(x, 31, 1) != int(n % 8 not in (3, 7)))      # pending
        walk_bad += int(_field(st, ST3_FRAME, 8) != (n + 1) // 128)        # frames
        # On a storing beat the 4:2:0 chroma cannot be known yet, so result's
        # upper half must read zero; on a committing beat it must be the average.
        walk_bad += int((r >> 16 != 0) != bool(lane))
    assert walk_bad == 0, 'yuv420_pack: block/frame walk or the store/commit split is wrong'
    checks += 2

    # The decimator is MPEG-2 frame coding: ceil((top + bottom) / 2).  That is
    # order independent and lands within one code of either input, which no
    # weighting or rounding mistake can survive.
    avg_bad = 0
    for n, (r, x, f, st) in enumerate(seen):
        if not ((n % 8) >> 1) & 1:
            continue                                    # storing beat: nothing to compare
        # The macropixel stored two beats earlier shares this lane's slot,
        # because idx runs 0,1 (top row) then 2,3 (bottom row) per row pair.
        for channel, low in ((1, 16), (3, 24)):
            top = byte_of(rows[n - 2][0], channel)
            bot = byte_of(rows[n][0], channel)
            avg = (top + bot + 1) >> 1
            avg_bad += int(_field(r, low, 8) != avg)
            avg_bad += int(not min(top, bot) <= avg <= max(top, bot))
            avg_bad += int(2 * avg - (top + bot) not in (0, 1))          # round half up
            avg_bad += int((top + bot + 1) >> 1 != (bot + top + 1) >> 1)  # order free
        odd = any(((byte_of(rows[n - 2][0], ch) + byte_of(rows[n][0], ch)) & 1)
                  for ch in (1, 3))
        differs = any(((byte_of(rows[n - 2][0], ch) + byte_of(rows[n][0], ch) + 1) >> 1
                       != byte_of(rows[n - 2][0], ch)) for ch in (1, 3))
        avg_bad += int(_field(x, 25, 1) != odd)
        avg_bad += int(_field(x, 26, 1) != differs)
    assert avg_bad == 0, 'yuv420_pack: the 2:1 chroma average is not round-half-up'
    checks += 1

    # Restart semantics on c[31]: the pending top-row chroma from before the
    # restart must be gone, or the very next committed quad averages it in.
    # Two storing beats leave slot 0 holding (240, 235); after a restart the
    # first committed quad must average the post-restart pair (16, 20), not the
    # stale one -- (240 + 20 + 1) >> 1 = 130 would be the poisoned answer.
    stream = [(pack4((100, 240, 120, 235)), 0, 0), (pack4((100, 200, 120, 200)), 0, 0),
              (pack4((100, 16, 120, 20)), 0, 1 << 31), (pack4((100, 30, 120, 40)), 0, 0),
              (pack4((100, 20, 120, 24)), 1, 0)]
    beats = _v_run(name, stream)
    assert beats[2][2] == 0 and _field(beats[2][1], 0, 3) == 0, \
        'yuv420_pack: the restart beat was not accepted at block index 0'
    assert (beats[4][2], _field(beats[4][1], 0, 3)) == (0, 2)
    poisoned = int(_field(beats[4][0], 16, 8) != 18 or _field(beats[4][0], 24, 8) != 22)
    assert poisoned == 0, 'yuv420_pack: c[31] did not clear the pending chroma accumulator'
    checks += 1
    # Restart also resets the block addressing to (0,0) and the frame counter.
    r, x, f, st = step(name, pack4((100, 128, 120, 128)), 0, (1 << 31) | 0, 0xFEDCBA9876)
    assert (f, _field(x, 0, 3), _field(x, 8, 4), _field(x, 16, 3), _field(st, ST3_FRAME, 8)) == \
        (0, 0, 0, 0, 0), 'yuv420_pack: restart left block address or frame count behind'
    checks += 1

    # Rejected beats: reserved input fields and the feeder-declared field
    # parity.  A parity fault keeps the accumulator (so the pair still lines up)
    # but a restart request on the same beat is still honoured.
    keep = step(name, pack4((100, 128, 120, 128)), 0, 1 << 3, 0x99)
    assert keep == (0, 0, 1, 0x99), 'yuv420_pack: c[30:1] must fault with the state kept'
    keep = step(name, pack4((100, 128, 120, 128)), 1 << 5, 0, 0x99)
    assert keep == (0, 0, 1, 0x99), 'yuv420_pack: b[31:1] must fault with the state kept'
    good = step(name, pack4((100, 128, 120, 128)), 1, 0, 0x10)      # idx 0 wants parity 0
    assert good[2] == 1 and good[3] == 0x10, 'yuv420_pack: wrong field parity must fault'
    honoured = step(name, pack4((100, 128, 120, 128)), 1, 1 << 31, 0x10)
    assert honoured[2] == 1 and honoured[3] == 0, \
        'yuv420_pack: a restart request on a parity fault beat was dropped'
    checks += 3
    # Studio-window legality is reported, never fatal: chroma outside 16..240
    # sets aux[27] and still commits, because the feeder may be lossy.
    legal_bad = 0
    for cb, cr in ((16, 16), (240, 240), (15, 128), (128, 241), (0, 255), (17, 239)):
        r, x, f, st = step(name, pack4((100, cb, 120, cr)), 0, 1 << 31, 0)
        legal_bad += int(f != 0 or _field(x, 27, 1) != int(cb < 16 or cb > 240 or cr < 16
                                                           or cr > 240))
        legal_bad += int(_field(x, 28, 1) != int(100 == 120))
    assert legal_bad == 0, 'yuv420_pack: the luma/ chroma legality bits mis-reported'
    checks += 1

    # -- 4. yuv422_unpack: byte-lane routing and a counter that is a delay ----
    name = 'yuv422_unpack'
    # The two format conventions are two byte-lane permutations of the same
    # macropixel.  Both tables are derived here from the component names in the
    # core spec -- YUYV packs Y0 U Y1 V and UYVY packs U Y0 V Y1 into
    # a[7:0] a[15:8] a[23:16] a[31:24] -- against a result that is always
    # [Y0 Cb Cr Y1] from lane 0 up.  A duplicated or missing lane index trips
    # the bijectivity/rotation asserts below, so a bad table can never be
    # masked by a kernel that happens to agree with it, and can never be
    # re-derived from the model mirror.
    SRC = {'yuyv': {'Y0': 0, 'Cb': 1, 'Y1': 2, 'Cr': 3},        # Y0 U  Y1 V
           'uyvy': {'Cb': 0, 'Y0': 1, 'Cr': 2, 'Y1': 3}}        # U  Y0 V  Y1
    OUT = ('Y0', 'Cb', 'Cr', 'Y1')                              # result lane order
    MAP = {fmt: [SRC[fmt][comp] for comp in OUT] for fmt in SRC}
    assert sorted(MAP['yuyv']) == [0, 1, 2, 3], \
        'yuv422_unpack: the YUYV byte-lane table is not a permutation'
    assert sorted(MAP['uyvy']) == [0, 1, 2, 3], \
        'yuv422_unpack: the UYVY byte-lane table is not a permutation'
    checks += 1
    assert MAP['yuyv'] == [0, 1, 3, 2] and MAP['uyvy'] == [1, 0, 2, 3], \
        'yuv422_unpack: a byte-lane table no longer matches the declared packing'
    checks += 1
    # The single rotation that turns a YUYV macropixel into a UYVY one is the
    # exchange of both byte pairs, (0 1)(2 3): Y0<->Cb and Y1<->Cr.  It must be
    # a bijection and its own inverse, and it must conjugate the two maps
    # exactly: UYVY(w) == YUYV(rotate(w)) for every word.
    ROT = (1, 0, 3, 2)
    assert sorted(ROT) == [0, 1, 2, 3], \
        'yuv422_unpack: the Y/Cb Cr/Y1 exchange is not a permutation of four lanes'
    assert [ROT[ROT[k]] for k in range(4)] == [0, 1, 2, 3], \
        'yuv422_unpack: the byte-pair exchange is not an involution'
    assert [ROT[m] for m in MAP['yuyv']] == MAP['uyvy'], \
        'yuv422_unpack: the two lane maps are not the declared rotation apart'
    checks += 1

    def swap_pairs(word):
        return sum(byte_of(word, ROT[k]) << (8 * k) for k in range(4))

    # Drive the core with the two tables.  Every byte of these words sits inside
    # the studio chroma window 16..240, so under BOTH maps the beat is legal and
    # a legality rejection can never be counted as a routing error.  (0xFF801F20
    # used to be in this list: its YUYV Cr is 255, which the core rejects by
    # design, so the routed result is legitimately zero -- that behaviour is
    # covered by the dedicated illegal-chroma block below.)
    route_bad = 0
    for word in (0x44332211, 0x11223344, 0x8F7E6D5C, 0x10A0F050, 0x20304050):
        lanes = {lane: byte_of(word, lane) for lane in range(4)}
        yuyv = step(name, word, 0, 1 << 31, 0)                  # phase 0
        toggle = step(name, word, 0, 1 << 31 | 1, 0)            # phase 0, flips for next
        uyvy = step(name, word, 0, 0, toggle[3])                # now phase 1
        swapped = step(name, swap_pairs(word), 0, 1 << 31, 0)[0]
        route_bad += int(yuyv[2] or toggle[2] or uyvy[2])       # legality, not routing
        for beat, fmt in ((yuyv, 'yuyv'), (uyvy, 'uyvy')):
            route_bad += int([byte_of(beat[0], k) for k in range(4)]
                             != [lanes[lane] for lane in MAP[fmt]])
            # the 4:2:2 to 4:4:4 expansion duplicates this map's Cb/Cr into
            # aux[7:0]/aux[15:8], from the same table as the result.
            route_bad += int([byte_of(beat[1], 0), byte_of(beat[1], 1)]
                             != [lanes[MAP[fmt][1]], lanes[MAP[fmt][2]]])
        # ... and the UYVY reading of a word is the YUYV reading of its rotation.
        route_bad += int([byte_of(swapped, k) for k in range(4)]
                         != [byte_of(uyvy[0], k) for k in range(4)])
        # the phase reported per beat is the one that was in effect; c[0] only
        # re-times the following beat.
        route_bad += int(_field(yuyv[1], 24, 1) != 0
                         or _field(toggle[1], 24, 1) != 0
                         or _field(uyvy[1], 24, 1) != 1)
    assert route_bad == 0, 'yuv422_unpack: the YUYV/UYVY byte-lane maps are not permutations'
    checks += 1

    # Hand-computed pins, so a table edited to match the kernel cannot survive:
    # 0x44332211 is Y0=0x11 U=0x22 Y1=0x33 V=0x44 under YUYV, so
    # result = [Y0 Cb Cr Y1] = 0x33442211; read as UYVY it is
    # Cb=0x11 Y0=0x22 Cr=0x33 Y1=0x44, so result = 0x44331122 -- which is also
    # the YUYV reading of the rotated word 0x33441122.
    pin_y = step(name, 0x44332211, 0, 1 << 31, 0)
    pin_u = step(name, 0x44332211, 0, 0, 1)                     # phase 1, no restart
    assert (pin_y[2], pin_u[2]) == (0, 0), 'yuv422_unpack: a pinned macropixel was rejected'
    assert (pin_y[0], pin_u[0]) == (0x33442211, 0x44331122), \
        'yuv422_unpack: the pinned YUYV/UYVY results for 0x44332211 changed'
    assert swap_pairs(0x44332211) == 0x33441122, 'yuv422_unpack: byte-pair exchange'
    assert step(name, 0x33441122, 0, 1 << 31, 0)[0] == 0x44331122, \
        'yuv422_unpack: rotating the input does not reproduce the UYVY result'
    checks += 1

    # The macropixel counter is a pure delay line: it reports the index of the
    # beat that is being retired, holds index+1 afterwards, and the wrap strobe
    # fires on the beat whose own index was 127 -- never a beat earlier or later.
    legal = pack4((0x41, 0x80, 0x42, 0x80))
    seen = _v_run(name, [(legal, 0, 1 << 31 if n == 0 else 0) for n in range(260)])
    delay_bad = 0
    for n, (r, x, f, st) in enumerate(seen):
        delay_bad += int(f != 0 or _field(x, 16, 7) != n % 128)
        delay_bad += int(_field(st, 1, 7) != (n + 1) % 128)             # state is one ahead
        delay_bad += int(_field(x, 30, 1) != int(n % 128 == 127))       # wrap strobe
        delay_bad += int(_field(x, 31, 1) != int(n == 0))               # restart strobe
        # the 4:2:2 to 4:4:4 expansion duplicates the pair onto pixel 1
        delay_bad += int(byte_of(x, 0) != byte_of(r, 1) or byte_of(x, 1) != byte_of(r, 2))
    assert delay_bad == 0, 'yuv422_unpack: macropixel index is not a one-beat delay counter'
    checks += 1

    # Illegal chroma rejects the beat *and* leaves the delay counter and the
    # byte-lane phase untouched, so the feeder can re-send the same macropixel.
    held = _field(seen[9][3], 0, 8)
    for cb, cr in ((0, 128), (128, 0), (15, 128), (128, 241), (241, 241), (255, 255)):
        r, x, f, st = step(name, pack4((0x41, cb, 0x42, cr)), 0, 1, seen[9][3])
        assert (r, x, f) == (0, 0, 1), 'yuv422_unpack: chroma %d/%d outside 16..240 accepted' % (cb, cr)
        assert st == _set_field(seen[9][3], 1, 7, (_field(seen[9][3], 1, 7)) & 0x7F), \
            'yuv422_unpack: a rejected beat moved the macropixel counter'
        checks += 1
    # ... and the phase toggle is only taken on an accepted beat.
    r, x, f, st = step(name, pack4((0x41, 0, 0x42, 128)), 0, 1, held)
    assert f == 1 and (st & 1) == (held & 1), 'yuv422_unpack: a rejected beat toggled the phase'
    checks += 1

    # Status bits from the definition of the codes, over every lane position and
    # both phases: equal luma pair, neutral chroma, luma outside 16..235, and a
    # chroma code sitting exactly on the 16 or 240 edge.  The phase in effect is
    # a register, so it is driven through state[0] with c=0 -- asserting c[0] on
    # a phase-0 beat would only re-time the *following* beat.  Every vector here
    # carries chroma inside 16..240 under both maps, so a rejection is a real
    # bug rather than the legality rule firing; `if f` below fails loudly if one
    # ever drifts out of the legal window.
    bits_bad = 0
    for phase in (0, 1):
        results = []
        for y0, cb, y1, cr in ((0x41, 0x80, 0x41, 0x80), (0x0F, 0x10, 0x40, 0x80),
                               (0x40, 0x80, 0xEB, 0xF0), (0x40, 0x10, 0x41, 0xF0),
                               (0x10, 0x80, 0xF0, 0x80), (0xFF, 0x80, 0x00, 0x80)):
            word = y0 | (cb << 8) | (y1 << 16) | (cr << 24)
            if phase:
                word = swap_pairs(word)               # so the codes land as intended
            r, x, f, st = step(name, word, 0, 0, phase)
            if f:
                bits_bad += 1
                continue
            results.append(r)
            lumas = [byte_of(r, 0), byte_of(r, 3)]
            bits_bad += int(_field(x, 25, 1) != int(lumas[0] == lumas[1]))
            bits_bad += int(_field(x, 26, 1) != int(cb == 128 and cr == 128))
            bits_bad += int(_field(x, 27, 1) != int(any(v < 16 or v > 235 for v in lumas)))
            bits_bad += int(_field(x, 28, 1) != int(cb in (16, 240)))
            bits_bad += int(_field(x, 29, 1) != int(cr in (16, 240)))
            bits_bad += int(_field(x, 24, 1) != phase)
            # Both conventions must expand to the *same* 4:4:4 macropixel: only
            # the byte lanes move, never a component value.
            bits_bad += int([byte_of(r, 0), byte_of(r, 1), byte_of(r, 2), byte_of(r, 3)]
                            != [y0, cb, cr, y1])
        if phase:
            # and the rotated-word result must equal the straight-word result.
            bits_bad += int(results != straight)
        else:
            straight = list(results)
    assert bits_bad == 0, 'yuv422_unpack: a legality or equality status bit mis-reported'
    checks += 1

    # Reserved fields: b must be zero and c[30:1] must be zero; either one
    # faults with the whole state kept.
    for bit in range(32):
        r, x, f, st = step(name, legal, 1 << bit, 0, 0x2A55)
        assert (r, x, f, st) == (0, 0, 1, 0x2A55), ('yuv422_unpack: b bit', bit)
        if bit not in (0, 31):
            r, x, f, st = step(name, legal, 0, 1 << bit, 0x2A55)
            assert (r, x, f, st) == (0, 0, 1, 0x2A55), ('yuv422_unpack: c bit', bit)
        checks += 1
    return checks

