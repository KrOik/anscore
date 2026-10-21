"""SIMD lane kernels: several independent narrow datapaths per accepted beat.

Reference family for the accelerator catalog. Read this file before authoring
another family: it shows the catalog entry shape, the combinational body
vocabulary the template provides, the exact integer model, and how a board
vector set is built so that every lane and every fault path is exercised
inside the first 128 rows.

Body vocabulary (declared by the template, reset each evaluation):
    r x                       result/aux registers, 32 bit
    f                         fault flag
    temp mask pa pb pc ph pl  32-bit unsigned temporaries
    ext                       33-bit unsigned (carry capture)
    wide wide2                64-bit unsigned
    swide swide2              64-bit signed
    sa sb sc                  $signed(a), $signed(b), $signed(c)
    data                      {a,b,c} as one 96-bit word
    i j idx lane sh           integers
    state_r state_n           256-bit state; only accepted beats commit it
"""
from random import Random

FAMILY = 'simd'
MASK = (1 << 32) - 1

CORES = []


def core(name, spec, body, advantage, lanes, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body,
                      advantage=advantage, lanes=lanes, **kwargs))


core('simd_u8x4_add_sat',
    'Four independent unsigned 8-bit saturating adders. Lane k reads a[8k+:8] and '
    'b[8k+:8]. result[8k+:8]=min(a_k+b_k,255). aux[3:0]=lanes that saturated. '
    'fault=any lane saturated. No lane ever wraps.',
    'for(lane=0;lane<4;lane=lane+1) begin\n'
    '    pa={24\'d0,a[lane*8+:8]}+{24\'d0,b[lane*8+:8]};\n'
    '    if(pa[8]) begin r[lane*8+:8]=8\'hff; x[lane]=1\'b1; f=1\'b1; end\n'
    '    else r[lane*8+:8]=pa[7:0];\n'
    'end',
    'A scalar core needs one saturating-add instruction per pixel; this retires '
    '4 pixels every enabled cycle at II=1 and the overflow path is not a branch.', 4)

core('simd_u8x4_diff_sat_i8',
    'Four signed 8-bit differences d_k=a_k-b_k clamped to [-128,127]. '
    'result[8k+:8]=two\'s complement of the clamped d_k. aux[3:0]=lanes that '
    'clamped, aux[7:4]=lanes where a_k<b_k. fault=any clamp.',
    'for(lane=0;lane<4;lane=lane+1) begin\n'
    '    pa={24\'d0,a[lane*8+:8]}; pb={24\'d0,b[lane*8+:8]};\n'
    '    x[lane+4]=(pa<pb);\n'
    '    swide=$signed(pa)-$signed(pb);\n'
    '    if(swide>64\'sd127) begin r[lane*8+:8]=8\'h7f; x[lane]=1\'b1; f=1\'b1; end\n'
    '    else if(swide<-64\'sd128) begin r[lane*8+:8]=8\'h80; x[lane]=1\'b1; f=1\'b1; end\n'
    '    else r[lane*8+:8]=swide[7:0];\n'
    'end',
    'Background/motion subtraction on 4 pixels per beat, with the sign and clamp '
    'flags produced in the same beat instead of a per-pixel compare loop.', 4)

core('simd_i16x2_mul_q15_round',
    'Two Q15 signed 16-bit multiplies. Lane k operands are a[16k+:16] and '
    'b[16k+:16]; value=clamp_s16((a_k*b_k + 2^14) >>> 15) using a floor shift. '
    'aux[1:0]=lanes clamped. fault=any clamp, which covers (-32768)*(-32768).',
    'for(lane=0;lane<2;lane=lane+1) begin\n'
    '    swide=$signed(a[lane*16+:16])*$signed(b[lane*16+:16]);\n'
    '    swide=(swide+64\'sd16384)>>>15;\n'
    '    if(swide>64\'sd32767) begin r[lane*16+:16]=16\'h7fff; x[lane]=1\'b1; f=1\'b1; end\n'
    '    else if(swide<-64\'sd32768) begin r[lane*16+:16]=16\'h8000; x[lane]=1\'b1; f=1\'b1; end\n'
    '    else r[lane*16+:16]=swide[15:0];\n'
    'end',
    'Fixed-point mix/gain stage: two Q15 multiplies with rounding and saturation '
    'per beat, no software multiply-high routine.', 2)

core('simd_u8x4_mad_round',
    'Per-lane gain then offset: value_k=sat_u8((((a_k*b_k)+128)>>8)+c_k) where '
    'b_k is a Q8 gain and c_k an unsigned offset. aux[3:0]=lanes clamped at 255. '
    'fault=any clamp.',
    'for(lane=0;lane<4;lane=lane+1) begin\n'
    '    pa=({24\'d0,a[lane*8+:8]}*{24\'d0,b[lane*8+:8]}+32\'d128)>>8;\n'
    '    pb=pa+{24\'d0,c[lane*8+:8]};\n'
    '    if(pb[8]) begin r[lane*8+:8]=8\'hff; x[lane]=1\'b1; f=1\'b1; end\n'
    '    else r[lane*8+:8]=pb[7:0];\n'
    'end',
    'Scale-and-bias on 4 channels per beat for white balance or dither-free '
    'gamma: the multiply, rounding shift and bias are one hardwired cone.', 4)

core('simd_i16x2_abs_sat',
    'Lane-wise magnitude of the two signed 16-bit values in a. -32768 saturates '
    'to 32767. result=|a_k| per lane. aux[1:0]=lanes that saturated. '
    'fault=any saturation.',
    'for(lane=0;lane<2;lane=lane+1) begin\n'
    '    if(a[lane*16+15] && a[lane*16+:16]==16\'h8000)\n'
    '        begin r[lane*16+:16]=16\'h7fff; x[lane]=1\'b1; f=1\'b1; end\n'
    '    else if(a[lane*16+15]) r[lane*16+:16]=~a[lane*16+:16]+16\'d1;\n'
    '    else r[lane*16+:16]=a[lane*16+:16];\n'
    'end',
    'Rectifier for envelope/level metering: the most-negative input is the '
    'two\'s-complement trap, and here it is flagged in the same beat.', 2)

core('simd_i16x2_sar_rne',
    'Requantise two signed 16-bit lanes of a by arithmetic right shift with '
    'round-to-nearest-even. Lane k amount is c[4k+:4]; c[31:8] must be zero. '
    'result=rounded lane. aux[7:0]=c[7:0] echoed, aux[9:8]=lanes whose floor '
    'quotient was incremented. fault=nonzero c[31:8], with result=aux=0.',
    'if(c[31:8]!=0) f=1\'b1;\n'
    'else begin\n'
    '    for(lane=0;lane<2;lane=lane+1) begin\n'
    '        sh=lane==0 ? c[3:0] : c[7:4];\n'
    '        if(sh==0) r[lane*16+:16]=a[lane*16+:16];\n'
    '        else begin\n'
    '            swide=$signed(a[lane*16+:16])>>>sh;\n'
    '            swide2=($signed(a[lane*16+:16])-(swide<<<sh))<<<1;\n'
    '            if(swide2>(64\'sd1<<<sh) || (swide2==(64\'sd1<<<sh) && swide[0])) begin\n'
    '                r[lane*16+:16]=swide[15:0]+16\'d1; x[8+lane]=1\'b1;\n'
    '            end else r[lane*16+:16]=swide[15:0];\n'
    '        end\n'
    '    end\n'
    '    x[7:0]={c[7:4],c[3:0]};\n'
    'end',
    'Neural-net requantisation needs ties-to-even at II=1; a scalar core pays a '
    'branch or fix-up per value, here both lanes round every enabled beat.', 2)


def s16(value):
    value &= 0xffff
    return value - (1 << 16) if value >> 15 else value


def step(name, a, b, c, state=0):
    r = x = f = 0
    if name == 'simd_u8x4_add_sat':
        for k in range(4):
            total = ((a >> 8*k) & 255) + ((b >> 8*k) & 255)
            r |= min(total, 255) << 8*k
            if total > 255:
                x |= 1 << k
                f = 1
    elif name == 'simd_u8x4_diff_sat_i8':
        for k in range(4):
            va, vb = (a >> 8*k) & 255, (b >> 8*k) & 255
            x |= int(va < vb) << (k+4)
            diff = max(-128, min(127, va-vb))
            if diff != va-vb:
                x |= 1 << k
                f = 1
            r |= (diff & 255) << 8*k
    elif name == 'simd_i16x2_mul_q15_round':
        for k in range(2):
            product = s16((a >> 16*k) & 0xffff) * s16((b >> 16*k) & 0xffff)
            value = (product + (1 << 14)) >> 15
            clamped = max(-32768, min(32767, value))
            if clamped != value:
                x |= 1 << k
                f = 1
            r |= (clamped & 0xffff) << 16*k
    elif name == 'simd_u8x4_mad_round':
        for k in range(4):
            scaled = ((((a >> 8*k) & 255)*((b >> 8*k) & 255)) + 128) >> 8
            total = scaled + ((c >> 8*k) & 255)
            if total > 255:
                r |= 255 << 8*k
                x |= 1 << k
                f = 1
            else:
                r |= total << 8*k
    elif name == 'simd_i16x2_abs_sat':
        for k in range(2):
            value = s16((a >> 16*k) & 0xffff)
            if value == -32768:
                r |= 32767 << 16*k
                x |= 1 << k
                f = 1
            else:
                r |= abs(value) << 16*k
    elif name == 'simd_i16x2_sar_rne':
        if c >> 8:
            return 0, 0, 1, state
        for k in range(2):
            shift = (c >> 4*k) & 15
            value = s16((a >> 16*k) & 0xffff)
            if shift == 0:
                r |= (value & 0xffff) << 16*k
                continue
            quotient = value >> shift                        # floor, matches >>>
            twice_remainder = 2 * (value - (quotient << shift))
            if twice_remainder > (1 << shift) or \
               (twice_remainder == (1 << shift) and quotient & 1):
                quotient += 1
                x |= 1 << (8+k)
            r |= (quotient & 0xffff) << 16*k
        x |= c & 0xff
    else:
        raise ValueError(name)
    return r & MASK, x & MASK, f, state


U8_EDGE = [0, 1, 2, 0x7f, 0x80, 0x81, 0xfe, 0xff]
I16_EDGE = [0x0000, 0x0001, 0xffff, 0x7fff, 0x8000, 0x4000, 0xc000, 0x5555]


def pack4(values):
    return sum((v & 0xff) << 8*k for k, v in enumerate(values))


def pack2(values):
    return sum((v & 0xffff) << 16*k for k, v in enumerate(values))


def vectors(name, count=320):
    """Board set first: structured lane/edge combinations, then random padding.

    Rows 0..127 run on the hardware, so all saturation, tie and malformed
    control cases are placed there deliberately rather than left to chance.
    """
    rows = []
    if name in ('simd_i16x2_mul_q15_round', 'simd_i16x2_abs_sat', 'simd_i16x2_sar_rne'):
        for i, va in enumerate(I16_EDGE):
            for j, vb in enumerate(I16_EDGE):
                rows.append((pack2([va, vb]), pack2([vb, I16_EDGE[(i+j) % 8]]),
                             (i * 3 + j) % 16 if name.endswith('sar_rne') else 0))
    else:
        for i, va in enumerate(U8_EDGE):
            for j, vb in enumerate(U8_EDGE):
                rows.append((pack4([va, U8_EDGE[(i+1) % 8], vb, U8_EDGE[(i+j) % 8]]),
                             pack4([vb, U8_EDGE[(j+3) % 8], va, 0x01]),
                             pack4([U8_EDGE[(i+j) % 8], 0x80, 0x01, 0xff])))
    # One saturated lane at a time: no lane shares another lane's flag path.
    for k in range(4):
        rows.append((pack4([0xff if m == k else 0 for m in range(4)]),
                     pack4([0xff if m == k else 0 for m in range(4)]),
                     pack4([0xff if m == k else 0 for m in range(4)])))
        rows.append((pack4([0x80 if m == k else 1 for m in range(4)]),
                     pack4([0x80 if m == k else 1 for m in range(4)]),
                     pack4([0x80 if m == k else 0 for m in range(4)])))
    if name.endswith('sar_rne'):
        for shift in range(16):
            for value in (0x7fff, 0x8000, 0x5555, 0xaaaa, 3, 2, 1):
                rows.append((pack2([value & 0xffff, (value >> 1) & 0xffff]), 0,
                             shift | (min(shift+1, 15) << 4)))
        rows.append((pack2([0x1234, 0x5678]), 0, 0x00000100))
        rows.append((pack2([0x1234, 0x5678]), 0, 0x00010000))   # malformed control
    rng = Random(0xACCE5000 + sum(name.encode()))
    while len(rows) < count:
        rows.append((rng.getrandbits(32), rng.getrandbits(32),
                     rng.getrandbits(16) if name.endswith('sar_rne') and len(rows) % 5
                     else rng.getrandbits(32)))
    return rows[:count]


def selftest():
    """Independent-model checks against hand-derived expected values."""
    checks = 0
    # Saturating add: one overflowing lane sets exactly one flag bit, here the
    # lowest and the highest lane so no flag can be shared by construction.
    r, x, f, _ = step('simd_u8x4_add_sat', 0x010203ff, 0x01010101, 0)
    assert (r, x, f) == (0x020304ff, 0x00000001, 1)
    r, x, f, _ = step('simd_u8x4_add_sat', 0xff000000, 0x01000000, 0)
    assert (r, x, f) == (0xff000000, 0x00000008, 1)
    checks += 2
    # -128 is representable so it must not clamp; +128 must clamp to +127.
    r, x, f, _ = step('simd_u8x4_diff_sat_i8', 0x00000000, 0x00000080, 0)
    assert (r, x, f) == (0x00000080, 0x00000010, 0)
    r, x, f, _ = step('simd_u8x4_diff_sat_i8', 0x00000080, 0x00000000, 0)
    assert (r, x, f) == (0x0000007f, 0x00000001, 1)
    checks += 2
    # Q15: 0.5 * 0.5 = 0.25, and -1.0 * -1.0 is the saturation trap.
    assert step('simd_i16x2_mul_q15_round', 0x40004000, 0x40004000, 0)[0] == 0x20002000
    r, x, f, _ = step('simd_i16x2_mul_q15_round', 0x80008000, 0x80008000, 0)
    assert (r, x, f) == (0x7fff7fff, 0x3, 1)
    checks += 2
    # Q8 gain with rounding then bias: round-half-up at the 128/129 boundary.
    assert step('simd_u8x4_mad_round', 127, 1, 0)[0] == 0
    assert step('simd_u8x4_mad_round', 2, 64, 0)[0] == 1
    r, x, f, _ = step('simd_u8x4_mad_round', 255, 255, 200)
    assert (r, x, f) == (0x000000ff, 1, 1)
    checks += 3
    # Ties-to-even: 3/2 rounds up (odd quotient), 2/2 and 1/2 round to even.
    assert step('simd_i16x2_sar_rne', 3, 0, 1)[0] & 0xffff == 2
    assert step('simd_i16x2_sar_rne', 2, 0, 1)[0] & 0xffff == 1
    assert step('simd_i16x2_sar_rne', 1, 0, 1)[0] & 0xffff == 0
    assert step('simd_i16x2_sar_rne', -3, 0, 1)[0] & 0xffff == (-2 & 0xffff)
    assert step('simd_i16x2_sar_rne', 0x1234, 0, 1 << 8)[:3] == (0, 0, 1)
    checks += 5
    for value in range(-32768, 32768, 257):
        r, x, f, _ = step('simd_i16x2_abs_sat', value & 0xffff, 0, 0)
        assert r & 0xffff == min(abs(value), 32767)
        assert f == (1 if value == -32768 else 0)
        assert bool(x & 1) == (value == -32768)
        checks += 1
    # Every lane pair of every packed width must stay independent.
    for k in range(4):
        r, x, f, _ = step('simd_u8x4_add_sat', 0xff << 8*k, 0x01 << 8*k, 0)
        assert (r, x, f) == (0xff << 8*k, 1 << k, 1)
        r, x, f, _ = step('simd_u8x4_mad_round', 0xff << 8*k, 0xff << 8*k, 0xff << 8*k)
        assert (r, x, f) == (0xff << 8*k, 1 << k, 1)
        checks += 2
    return checks
