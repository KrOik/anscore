"""Image / vision front-end kernels: a fixed pixel window per accepted beat.

Family file for the accelerator catalog. Each core consumes one packed pixel
window (or one window pair) per accepted beat and produces the filtered,
ranked, histogrammed or dithered result in that same beat, so every kernel is
a hardwired cone rather than a per-pixel instruction loop.

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

Arithmetic honesty: no `*`, no `/`, no inferred multiplier or divider. Filter
taps are written as explicit shift-and-add forms ([1,2,1] is x+(x<<1)+z,
[1,4,6,4,1] is (t<<2)+(t<<1) for the 6 tap), the divide-by-3 uses the
additive-inverse identity 255 = 3*85 with 85*S written as
(S<<6)+(S<<4)+(S<<2)+S, and the Bayer 4x4 threshold is bit-interleaved instead
of table-read.
"""
from random import Random

FAMILY = 'image'
MASK = (1 << 32) - 1

CORES = []


def core(name, spec, body, advantage, lanes, **kwargs):
    # Every kernel here is combinational: one accepted beat in, one response out
    # in the same enabled cycle, so latency is 1 by construction.
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body,
                      advantage=advantage, lanes=lanes, latency=1, **kwargs))


# --------------------------------------------------------------------------
# 1. Exact 3x3 Sobel gradient magnitude of one packed window.
# --------------------------------------------------------------------------
core('img_sobel_mag_u8',
    'Sobel 3x3 gradient magnitude of one packed window. Tap packing: row0 = '
    'p00=a[7:0], p01=a[15:8], p02=a[23:16]; row1 = p10,p11,p12 from b; row2 = '
    'p20,p21,p22 from c. a[31:24], b[31:24], c[31:24] are padding and must be '
    'zero. Exact integer (1,2,1) weights as shifts and adds only: '
    'Gx=(p02+2*p12+p22)-(p00+2*p10+p20) and Gy=(p20+2*p21+p22)-(p00+2*p01+p02), '
    'both magnitudes formed by compare-then-subtract so no signed datapath is '
    'needed. result[7:0]=min(|Gx|+|Gy|,255). aux[0]=Gx<0, aux[1]=Gy<0, '
    'aux[2]=the magnitude was clipped to 255; aux[31:3] are always zero. '
    'fault=any nonzero padding byte in a, b or c, with result=aux=0. No state.',
    "if(a[31:24]!=0 || b[31:24]!=0 || c[31:24]!=0) f=1'b1;\n"
    'else begin\n'
    "    pa={24'd0,a[7:0]}+({24'd0,b[7:0]}<<1)+{24'd0,c[7:0]};\n"
    "    pb={24'd0,a[23:16]}+({24'd0,b[23:16]}<<1)+{24'd0,c[23:16]};\n"
    "    pc={24'd0,a[7:0]}+({24'd0,a[15:8]}<<1)+{24'd0,a[23:16]};\n"
    "    ph={24'd0,c[7:0]}+({24'd0,c[15:8]}<<1)+{24'd0,c[23:16]};\n"
    '    x[0]=(pa>pb);\n'
    '    x[1]=(pc>ph);\n'
    '    temp=(pa>pb) ? (pa-pb) : (pb-pa);\n'
    '    mask=(pc>ph) ? (pc-ph) : (ph-pc);\n'
    "    ext=temp+mask;\n"
    "    if(ext>33'd255) begin r[7:0]=8'hff; x[2]=1'b1; end\n"
    "    else r[7:0]=ext[7:0];\n"
    'end',
    'A scalar core pays a load, two shifted adds, a subtract, an absolute value '
    'and a clip per pixel; this cone retires a whole 3x3 Sobel window every '
    'enabled beat at II=1 and hands the gradient signs out beside the '
    'magnitude, so edge direction costs nothing.', 1)


# --------------------------------------------------------------------------
# 2. Rank-1 median filter, four independent byte lanes.
# --------------------------------------------------------------------------
core('img_median3_u8x4',
    'Per-lane median of three unsigned bytes (rank 1 of 3), four lanes deep. '
    'Lane k reads A=a[8k+:8], B=b[8k+:8], C=c[8k+:8] and writes '
    'result[8k+:8]=median(A,B,C) as max(min(A,B),min(max(A,B),C)) - three '
    'comparators per lane, no adder, no sort. aux[3:0]=lanes where at least '
    'two of the three inputs are equal (a tie, so the median is also the min '
    'or the max). aux[7:4]=lanes where all three inputs are equal. aux[31:8] '
    'is always zero. No fault condition: every input word is a legal triple '
    'and a median of bytes can never overflow.',
    'for(lane=0;lane<4;lane=lane+1) begin\n'
    "    pa={24'd0,a[(lane<<3)+:8]};\n"
    "    pb={24'd0,b[(lane<<3)+:8]};\n"
    "    pc={24'd0,c[(lane<<3)+:8]};\n"
    '    if(pa<pb) begin ph=pa; pl=pb; end else begin ph=pb; pl=pa; end\n'
    '    if(pl<pc) temp=pl; else temp=pc;\n'
    '    if(ph<temp) r[(lane<<3)+:8]=temp[7:0]; else r[(lane<<3)+:8]=ph[7:0];\n'
    "    if(pa==pb || pb==pc || pa==pc) x[lane]=1'b1;\n"
    "    if(pa==pb && pb==pc) x[lane+4]=1'b1;\n"
    'end',
    'Salt-and-pepper rank filtering costs three compares and two branches per '
    'pixel in firmware; four lanes of the min/max network settle in one '
    'cycle, so the sensor pipeline moves 4 pixels per enabled beat with the '
    'tie flags produced in the same beat.', 4, faultless=True)


# --------------------------------------------------------------------------
# 3. 3-tap horizontal box average, exact divide by 3, four lanes.
# --------------------------------------------------------------------------
core('img_box_blur_div3_u8x4',
    'Four independent 3-tap horizontal box averages with exact division by 3. '
    'Lane k sums S=a[8k+:8]+b[8k+:8]+c[8k+:8] (0..765), then divides by 3 with '
    'the additive-inverse form floor(S/3)=floor(85*S/255), 255=3*85 and '
    '85*S=(S<<6)+(S<<4)+(S<<2)+S: with A=P>>8 and B=P&255, '
    'Q=A+(1 when A+B>=255) equals floor(S/3) exactly for S<=765. The residual '
    'R=S-2Q-Q is 0, 1 or 2 and result[8k+:8]=Q+(1 when R==2), i.e. round to '
    'nearest with the 2/3 case rounding up (a 1/3 tie cannot exist for an odd '
    'divisor), which equals (S+1)/3 by floor. aux[3:0]=lanes rounded up '
    '(R==2), aux[7:4]=lanes whose sum was an exact multiple of 3 (R==0), '
    'aux[31:8] always zero. No fault condition: all three input words are '
    'data.',
    'for(lane=0;lane<4;lane=lane+1) begin\n'
    "    pa={24'd0,a[(lane<<3)+:8]}+{24'd0,b[(lane<<3)+:8]}+{24'd0,c[(lane<<3)+:8]};\n"
    '    pb=(pa<<6)+(pa<<4)+(pa<<2)+pa;\n'
    "    pc=(pb>>8)+(pb&32'd255);\n"
    '    temp=pb>>8;\n'
    "    if(pc>=32'd255) temp=temp+32'd1;\n"
    '    mask=pa-(temp<<1)-temp;\n'
    "    if(mask==32'd2) begin temp=temp+32'd1; x[lane]=1'b1; end\n"
    "    if(mask==32'd0) x[lane+4]=1'b1;\n"
    '    r[(lane<<3)+:8]=temp[7:0];\n'
    'end',
    'An integer divide by 3 costs a scalar core a multiply-high plus fix-up or '
    'a library call per pixel; here the reciprocal is hardwired and four '
    '3-pixel sums are averaged, rounded and rounding-flagged in one beat.', 4,
    faultless=True)


# --------------------------------------------------------------------------
# 4. One-row 5-tap [1,4,6,4,1]/16 filter with edge address selection.
# --------------------------------------------------------------------------
core('img_gaussian5_edge_u8',
    'One-row 5-tap [1,4,6,4,1]/16 smoothing of a 4-pixel line segment with '
    'edge-pixel address handling. Packing: the four centres are x0=a[7:0], '
    'x1=a[15:8], x2=a[23:16], x3=a[31:24]; the four extension samples come in '
    'on b: e[-2]=b[7:0], e[-1]=b[15:8], e[+4]=b[23:16], e[+5]=b[31:24] (all '
    'four bytes used). c[0] selects the left edge address and c[1] the right '
    'edge address: 0 = use the supplied line-buffer sample, 1 = reflect about '
    'the edge with duplication, i.e. e[-1]=x0, e[-2]=x1, e[+4]=x3, e[+5]=x2. '
    'c[31:8] must be zero. The weights are exact shift-and-add only: a weight of '
    '4 is (t<<2) and a weight of 6 is (t<<1)+(t<<2), so no multiplier is '
    'inferred. Output byte k is result[8k+:8]=(sum_k+8)>>4, rounded once by the '
    '+8; the tap window for lane k is the 5 consecutive samples of '
    '[e[-2],e[-1],x0,x1,x2,x3,e[+4],e[+5]] starting at index k. The weights sum '
    'to 16, so sum_k<=4080 and (sum_k+8)>>4 never leaves 8 bits. '
    'aux[3:0]=lanes whose sixteenth-residual rounded the value up '
    '(sum_k&15 >= 8), aux[4]=left reflect mode used, aux[5]=right reflect mode '
    'used, aux[31:6] always zero. fault=any nonzero c[31:8], result=aux=0.',
    "if(c[31:8]!=0) f=1'b1;\n"
    'else begin\n'
    "    pa={24'd0,a[7:0]}; pb={24'd0,a[15:8]};\n"
    "    pc={24'd0,a[23:16]}; ph={24'd0,a[31:24]};\n"
    "    pl=(c[0]!=0) ? pb : {24'd0,b[7:0]};\n"
    "    temp=(c[0]!=0) ? pa : {24'd0,b[15:8]};\n"
    '    ext=pl+(temp<<2)+(pa<<1)+(pa<<2)+(pb<<2)+pc;\n'
    "    x[0]=ext[3]; ext=ext+33'd8; r[7:0]=ext[11:4];\n"
    '    ext=temp+(pa<<2)+(pb<<1)+(pb<<2)+(pc<<2)+ph;\n'
    "    x[1]=ext[3]; ext=ext+33'd8; r[15:8]=ext[11:4];\n"
    "    mask=(c[1]!=0) ? ph : {24'd0,b[23:16]};\n"
    '    ext=pa+(pb<<2)+(pc<<1)+(pc<<2)+(ph<<2)+mask;\n'
    "    x[2]=ext[3]; ext=ext+33'd8; r[23:16]=ext[11:4];\n"
    "    temp=(c[1]!=0) ? pc : {24'd0,b[31:24]};\n"
    '    ext=pb+(pc<<2)+(ph<<1)+(ph<<2)+(mask<<2)+temp;\n'
    "    x[3]=ext[3]; ext=ext+33'd8; r[31:24]=ext[11:4];\n"
    "    x[4]=c[0]; x[5]=c[1];\n"
    'end',
    'A separable 5-tap with mirror addressing costs a scalar core a branch per '
    'end pixel plus five multiply-accumulates; here the edge address is a 2:1 '
    'tap mux and all four weighted sums, their rounding and the residual flags '
    'complete in one beat.', 4)


# --------------------------------------------------------------------------
# 5. Bayer green-plane interpolation for two non-green centres.
# --------------------------------------------------------------------------
core('img_bayer_dual_lane',
    'Bayer 2x4 unpack plus a directional green-pair decision for two non-green '
    'centres. Packing: a = line-buffer row0 in (G R G R) phase, '
    'a[7:0]=t0 green, a[15:8]=t1 red = lane0 centre, a[23:16]=t2 green, '
    'a[31:24]=t3 red (tapped by the following beat, unused here); b = row1 in '
    '(B G B G) phase, b[7:0]=u0 blue, b[15:8]=u1 green, b[23:16]=u2 blue = '
    'lane1 centre, b[31:24]=u3 green; c[7:0]=the row-above green under t1, '
    'c[15:8]=the row-below green under u2, c[31:16] must be zero. Lane0 green '
    'taps: left t0, right t2, above c[7:0], below u1. Lane1 green taps: left '
    'u1, right u3, above t2, below c[15:8]. With centre C and greens Gu,Gd,Gl,Gr '
    'the directional scores are Sv=2*|Gu-Gd|+|Gu+Gd-2C| and '
    'Sh=2*|Gl-Gr|+|Gl+Gr-2C| (2C as C<<1, magnitudes by compare-then-subtract). '
    'Vertical wins iff Sv<Sh, horizontal iff Sh<Sv, otherwise the isotropic '
    'four-green mean is used. result[7:0]=lane0 green estimate, '
    'result[15:8]=lane1 green estimate, result[23:16]=lane0 centre sample and '
    'result[31:24]=lane1 centre sample (the chroma carried out with it). '
    'Estimate = (Gu+Gd+1)>>1 vertical, (Gl+Gr+1)>>1 horizontal, '
    '(Gu+Gd+Gl+Gr+2)>>2 on a tie. aux[0]=lane0 vertical won, aux[1]=lane0 '
    'horizontal won, aux[3:2]=the same two-bit code for lane1, so a tie sets '
    'both bits of its lane; aux[31:4] always zero. fault=nonzero c[31:16], '
    'with result=aux=0.',
    "if(c[31:16]!=0) f=1'b1;\n"
    'else begin\n'
    '    for(lane=0;lane<2;lane=lane+1) begin\n'
    '        if(lane==0) begin\n'
    "            pa={24'd0,a[15:8]}; pb={24'd0,a[7:0]};\n"
    "            pc={24'd0,a[23:16]}; ph={24'd0,c[7:0]}; pl={24'd0,b[15:8]};\n"
    '        end else begin\n'
    "            pa={24'd0,b[23:16]}; pb={24'd0,b[15:8]};\n"
    "            pc={24'd0,b[31:24]}; ph={24'd0,a[23:16]}; pl={24'd0,c[15:8]};\n"
    '        end\n'
    '        temp=(ph<pl) ? (pl-ph) : (ph-pl);\n'
    '        mask=(pc<pb) ? (pb-pc) : (pc-pb);\n'
    '        ph=ph+pl;\n'
    '        pl=pa<<1;\n'
    '        ext=temp<<1;\n'
    '        temp=(ph<pl) ? (pl-ph) : (ph-pl);\n'
    '        ext=ext+temp;\n'
    '        pc=pc+pb;\n'
    '        wide=mask<<1;\n'
    '        temp=(pc<pl) ? (pl-pc) : (pc-pl);\n'
    '        wide=wide+{32\'d0,temp};\n'
    "        if(ext<wide) begin temp=(ph+32'd1)>>1; x[(lane<<1)]=1'b1; end\n"
    "        else if(wide<ext) begin temp=(pc+32'd1)>>1; x[(lane<<1)+1]=1'b1; end\n"
    "        else begin temp=(ph+pc+32'd2)>>2;\n"
    "            x[(lane<<1)]=1'b1; x[(lane<<1)+1]=1'b1;\n"
    '        end\n'
    '        r[(lane<<3)+:8]=temp[7:0];\n'
    '        if(lane==0) r[23:16]=pa; else r[31:24]=pa;\n'
    '    end\n'
    'end',
    'Green-plane demosaicing costs a scalar core two absolute-difference pairs, '
    'a centre-consistency term and a three-way branch per pixel; two Bayer sites '
    'are graded, selected and averaged in one beat and the winning direction is '
    'reported next to the pixel.', 2)


# --------------------------------------------------------------------------
# 6. 16-bin saturating histogram held in the full 256-bit state.
# --------------------------------------------------------------------------
core('img_histogram_bin16_update',
    '16-bin histogram accumulated in state: state[(k*16)+:16] is bin k, so the '
    'array occupies exactly 16*16=256 bits. Each beat folds 8 pixels, one '
    '32-bit word per half plane, with bin index = pixel>>4 for a[7:0], '
    'a[15:8], a[23:16], a[31:24], b[7:0], b[15:8], b[23:16], b[31:24]. Control '
    'c: c[31]=restart (every bin cleared before the increments), c[30]=preload '
    '(every bin set to the byte broadcast {pv,pv} with pv=c[23:16], so pv=0xff '
    'arms the 65535 ceiling), c[7:4]=bin to read out, and c[3:0], c[15:8] and '
    'c[29:24] must be zero; restart beats preload. result[15:0]=bin c[7:4] as '
    'of the start of '
    'this beat, result[31:16]=that bin after this beat, so one beat reads a bin '
    'out and re-arms it. aux[15:0]=bins that hit the 16-bit ceiling and were '
    'held at 65535, aux[31:16]=bins that went from empty to non-empty this '
    'beat. fault=any bin overflow, or malformed control (then result=aux=0 and '
    'state is left exactly as it was). All 16 bins are compared against all 8 '
    'pixel nibbles and incremented in the same beat.',
    "if((c & 32'h3F00_FF0F)!=0) f=1'b1;\n"
    'else begin\n'
    "    sh=((c>>4)&32'hf)<<4;\n"
    '    r[15:0]=state_r[sh+:16];\n'
    '    for(idx=0;idx<16;idx=idx+1) begin\n'
    "        temp=(a[7:4]==idx)+(a[15:12]==idx)+(a[23:20]==idx)+(a[31:28]==idx)\n"
    "            +(b[7:4]==idx)+(b[15:12]==idx)+(b[23:20]==idx)+(b[31:28]==idx);\n"
    '        if(c[31]) mask=0;\n'
    '        else if(c[30]) mask={c[23:16],c[23:16]};\n'
    '        else mask=state_r[(idx<<4)+:16];\n'
    "        if(mask==0 && temp!=0) x[16+idx]=1'b1;\n"
    '        pa=mask+temp;\n'
    "        if(pa>32'h0000_ffff) begin\n"
    "            state_n[(idx<<4)+:16]=16'hffff; x[idx]=1'b1; f=1'b1;\n"
    '        end else state_n[(idx<<4)+:16]=pa[15:0];\n'
    '    end\n'
    '    r[31:16]=state_n[sh+:16];\n'
    'end',
    'A histogram step is a read-modify-write plus a store-forward stall per '
    'pixel in firmware; here 16 bins are matched against 8 pixel nibbles and '
    'incremented, saturated and flagged in a single enabled beat, with a '
    'zero-latency read-out port on any one bin.', 8, stateful=True)


# --------------------------------------------------------------------------
# 7. Ordered Bayer 4x4 dither to 2 bits per pixel, with error feedback.
# --------------------------------------------------------------------------
core('img_dither_bayer4x4',
    'Ordered 4x4 Bayer dither to 2 bits per pixel on four lanes, with the pixel '
    'phase kept in state. state[7:0]=x and state[15:8]=y are the coordinates of '
    'lane0 of this beat; lane k sits at (x+k, y) and the whole 2x2 phase, hence '
    'the 4x4 matrix entry, is fixed per lane by that counter. Every accepted '
    'beat advances x by 4 and increments y when x wraps past 255. c[31]=1 '
    'restarts the phase at (0,0) BEFORE this beat, so the beat is evaluated on '
    'the reset phase; every other bit of c, c[30:0], must be zero, otherwise '
    'fault with result=aux=0 and no phase advance. Threshold selection is '
    'bit-interleaved '
    'from row=y&3 and col=(x+k)&3: with t=col^row the 4-bit matrix entry is '
    '{t[0],row[0],t[1],row[1]}, which reproduces ((0,8,2,10),(12,4,14,6), '
    '(3,11,1,9),(15,7,13,5)). Pixel p=a[8k+:8] is compensated by the residual '
    'fed back on b[8k+:8] as a two\'s-complement byte, v=p+b_k is clamped to '
    '0..255, then num=(v<<2)+(M<<4), level=num>>8 saturated down to 3 and '
    'result[2k+:2]=level. result[11:8]=per-lane clamp flags, '
    'result[15:12]=per-lane level-saturation flags, result[23:16]=the next x, '
    'result[31:24]=the next y. aux[8k+:8]=(num&255)-128 as a two\'s-complement '
    'byte, the quantisation error to carry into the next beat.',
    "if((c & 32'h7FFF_FFFF)!=0) f=1'b1;\n"
    'else begin\n'
    '    if(c[31]) begin pa=0; pb=0; end\n'
    '    else begin pa=state_r[7:0]; pb=state_r[15:8]; end\n'
    "    ph=pb & 32'd3;\n"
    '    for(lane=0;lane<4;lane=lane+1) begin\n'
    "        pl=(pa+lane)&32'd3;\n"
    '        temp=pl^ph;\n'
    '        mask={temp[0],ph[0],temp[1],ph[1]};\n'
    "        swide=$signed({{24{b[(lane<<3)+7]}},b[(lane<<3)+:8]})\n"
    "            +$signed({24'd0,a[(lane<<3)+:8]});\n"
    "        if(swide<64'sd0) begin pc=0; r[8+lane]=1'b1; end\n"
    "        else if(swide>64'sd255) begin pc=255; r[8+lane]=1'b1; end\n"
    '        else pc=swide[7:0];\n'
    "        pl=(pc<<2)+(mask<<4);\n"
    '        temp=pl>>8;\n'
    "        if(temp>32'd3) begin temp=32'd3; r[12+lane]=1'b1; end\n"
    '        r[(lane<<1)+:2]=temp[1:0];\n'
    "        mask=pl[7:0]-32'd128;\n"
    '        x[(lane<<3)+:8]=mask[7:0];\n'
    '    end\n'
    "    temp=pa+32'd4;\n"
    "    if(temp[8]) mask=pb+32'd1; else mask=pb;\n"
    "    state_n[7:0]=temp[7:0]; state_n[15:8]=mask[7:0];\n"
    "    r[23:16]=temp[7:0]; r[31:24]=mask[7:0];\n"
    'end',
    'Dithered 4-level quantisation costs a scalar core a matrix load, a '
    'sign-extended accumulate and two branches per pixel; this cone walks the '
    'phase counters, compensates 4 pixels, quantises them and emits the '
    'residuals to feed back, 4 pixels per enabled beat.', 4, stateful=True)


# ==========================================================================
# Independent integer models.
# ==========================================================================

# The published 4x4 ordered-dither matrix, used by the model as a table lookup
# while the RTL derives the same entry by bit interleaving.
BAYER4x4 = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))

SOBEL_FLAT = [0, 1, 2, 85, 128, 170, 254, 255]
G5_VALUES = [0, 1, 7, 8, 64, 100, 127, 128, 170, 192, 247, 254, 255]
MED_VALUES = [0, 1, 2, 127, 128, 254, 255]


def byte_of(value, index):
    return (value >> (8 * index)) & 0xFF


def s8(value):
    value &= 0xFF
    return value - (1 << 8) if value >> 7 else value


def pack4(values):
    return sum((v & 0xFF) << (8 * k) for k, v in enumerate(values))


def step(name, a, b, c, state=0):
    r = x = f = 0
    if name == 'img_sobel_mag_u8':
        if (a >> 24) or (b >> 24) or (c >> 24):
            return 0, 0, 1, state
        top = [byte_of(a, k) for k in range(3)]
        mid = [byte_of(b, k) for k in range(3)]
        bot = [byte_of(c, k) for k in range(3)]
        gx = (top[2] + 2 * mid[2] + bot[2]) - (top[0] + 2 * mid[0] + bot[0])
        gy = (bot[0] + 2 * bot[1] + bot[2]) - (top[0] + 2 * top[1] + top[2])
        magnitude = abs(gx) + abs(gy)
        r = magnitude if magnitude <= 255 else 255
        x = (1 if gx < 0 else 0) | (2 if gy < 0 else 0) | (4 if magnitude > 255 else 0)
    elif name == 'img_median3_u8x4':
        for k in range(4):
            trio = (byte_of(a, k), byte_of(b, k), byte_of(c, k))
            r |= sorted(trio)[1] << (8 * k)
            if len(set(trio)) < 3:
                x |= 1 << k
            if len(set(trio)) == 1:
                x |= 1 << (k + 4)
    elif name == 'img_box_blur_div3_u8x4':
        for k in range(4):
            total = byte_of(a, k) + byte_of(b, k) + byte_of(c, k)
            quotient, remainder = divmod(total, 3)
            if remainder == 2:
                quotient += 1
                x |= 1 << k
            if remainder == 0:
                x |= 1 << (k + 4)
            r |= quotient << (8 * k)
    elif name == 'img_gaussian5_edge_u8':
        if c >> 8:
            return 0, 0, 1, state
        centre = [byte_of(a, k) for k in range(4)]
        if c & 1:
            left = [centre[1], centre[0]]                 # e[-2], e[-1] mirrored
        else:
            left = [byte_of(b, 0), byte_of(b, 1)]         # e[-2], e[-1] supplied
        if c & 2:
            right = [centre[3], centre[2]]                # e[+4], e[+5] mirrored
        else:
            right = [byte_of(b, 2), byte_of(b, 3)]        # e[+4], e[+5] supplied
        extended = left + centre + right
        weights = (1, 4, 6, 4, 1)
        for k in range(4):
            total = sum(weights[j] * extended[k + j] for j in range(5))
            r |= ((total + 8) // 16) << (8 * k)
            if (total % 16) >= 8:
                x |= 1 << k
        x |= (c & 3) << 4
    elif name == 'img_bayer_dual_lane':
        if c >> 16:
            return 0, 0, 1, state
        taps = ((byte_of(a, 1), byte_of(a, 0), byte_of(a, 2),
                 byte_of(c, 0), byte_of(b, 1)),
                (byte_of(b, 2), byte_of(b, 1), byte_of(b, 3),
                 byte_of(a, 2), byte_of(c, 1)))
        for k in range(2):
            centre, gl, gr, gu, gd = taps[k]
            score_v = 2 * abs(gu - gd) + abs(gu + gd - 2 * centre)
            score_h = 2 * abs(gl - gr) + abs(gl + gr - 2 * centre)
            if score_v < score_h:
                estimate = (gu + gd + 1) // 2
                x |= 1 << (2 * k)
            elif score_h < score_v:
                estimate = (gl + gr + 1) // 2
                x |= 1 << (2 * k + 1)
            else:
                estimate = (gu + gd + gl + gr + 2) // 4
                x |= 3 << (2 * k)
            r |= estimate << (8 * k)
            r |= centre << (16 + 8 * k)
    elif name == 'img_histogram_bin16_update':
        if c & 0x3F00FF0F:
            return 0, 0, 1, state
        report = (c >> 4) & 15
        bins = [(state >> (16 * k)) & 0xFFFF for k in range(16)]
        before = bins[report]
        if c >> 31:
            bins = [0] * 16
        elif c & (1 << 30):
            preload = (c >> 16) & 0xFF
            bins = [(preload << 8) | preload] * 16
        hits = [0] * 16
        for pixel in [byte_of(a, k) for k in range(4)] + \
                     [byte_of(b, k) for k in range(4)]:
            hits[pixel >> 4] += 1
        for k in range(16):
            if bins[k] == 0 and hits[k]:
                x |= 1 << (16 + k)
            total = bins[k] + hits[k]
            if total > 0xFFFF:
                bins[k] = 0xFFFF
                x |= 1 << k
                f = 1
            else:
                bins[k] = total
        r = before | (bins[report] << 16)
        state = sum(bins[k] << (16 * k) for k in range(16))
    elif name == 'img_dither_bayer4x4':
        if c & 0x7FFF_FFFF:
            return 0, 0, 1, state
        if c >> 31:
            pos_x = pos_y = 0
        else:
            pos_x = state & 0xFF
            pos_y = (state >> 8) & 0xFF
        for k in range(4):
            threshold = BAYER4x4[pos_y & 3][(pos_x + k) & 3]
            value = byte_of(a, k) + s8(byte_of(b, k))
            if value < 0 or value > 255:
                r |= 1 << (8 + k)
                value = 0 if value < 0 else 255
            number = (value << 2) + (threshold << 4)
            level = number >> 8
            if level > 3:
                level = 3
                r |= 1 << (12 + k)
            r |= level << (2 * k)
            x |= (((number & 0xFF) - 128) & 0xFF) << (8 * k)
        next_x = pos_x + 4
        next_y = pos_y + (1 if next_x > 255 else 0)
        next_x &= 0xFF
        next_y &= 0xFF
        r |= next_x << 16 | next_y << 24
        state = (state & ~0xFFFF) | next_x | (next_y << 8)
    else:
        raise ValueError(name)
    return r & MASK, x & MASK, f, state


# ==========================================================================
# Vector builders: rows 0..127 are structured and run verbatim on the board.
# ==========================================================================

def _sobel_rows():
    rows = []
    # Flat windows: exact zero magnitude, no sign bit.
    for value in SOBEL_FLAT:
        window = pack4([value] * 3)
        rows.append((window, window, window))
    # Malformed padding, one window position at a time.
    rows.append((1 << 24, 0, 0))
    rows.append((0, 1 << 24, 0))
    rows.append((0, 0, 1 << 24))
    rows.append((0xFF << 24, 0x01 << 24, 0))
    rows.append((0, 0, 0x80 << 24))
    rows.append((pack4([8, 8, 8]), pack4([8, 8, 8]), 1 << 24))
    # Rising vertical edge sweep: Gx=+4e, Gy=0, magnitude 4e (never clipped).
    for e in range(1, 57):
        window = pack4([0, 0, e])
        rows.append((window, window, window))
    # Falling vertical edge sweep: same magnitudes, aux[0] set -> new triples.
    for e in range(1, 57):
        window = pack4([e, 0, 0])
        rows.append((window, window, window))
    # Crossing corners: negative gradients that clip.
    for e in (56, 85, 127, 170, 212, 255):
        rows.append((pack4([e, 0, 0]), pack4([0, 0, 0]), pack4([0, 0, 0])))
    # Asymmetric corners: both gradients nonzero, one sign each.
    for e in (32, 64, 96, 128, 192, 255):
        rows.append((pack4([e, e, 0]), pack4([e, 0, 0]), pack4([0, 0, 0])))
    return rows


def _median_rows():
    rows = []
    # Dense small-domain product on all four lanes at once.
    for i, u in enumerate(MED_VALUES):
        for j, v in enumerate(MED_VALUES):
            w = MED_VALUES[(i + j * 3) % 7]
            z = MED_VALUES[(i + j) % 7]
            rows.append((pack4([u, v, w, z]),
                         pack4([v, w, u, MED_VALUES[(2 * j + 1) % 7]]),
                         pack4([w, u, v, MED_VALUES[(i + 2 * j) % 7]])))
    # Ramp sweep: every lane holds a different monotone trio, so the four
    # medians and both tie fields all move from row to row.
    for t in range(56):
        rows.append((pack4([(t * 3) & 0xFF, 255 - t, (t * 11) & 0xFF, t]),
                     pack4([(t * 5) & 0xFF, t, 128 + (t & 0x7F), (t * 7) & 0xFF]),
                     pack4([t, (t * 9) & 0xFF, 200 - t, 255 - (t & 0x3F)])))
    # Second dense product pass with a different index mixing so the ties and
    # the strict-ordering cases both repeat on every lane.
    for i, u in enumerate(MED_VALUES):
        for j, v in enumerate(MED_VALUES):
            w = MED_VALUES[(2 * i + j) % 7]
            rows.append((pack4([u, v, w, MED_VALUES[(i * j + 3) % 7]]),
                         pack4([v, w, u, MED_VALUES[(i + 4 * j) % 7]]),
                         pack4([w, u, v, MED_VALUES[(5 * i + j) % 7]])))
    # One lane sweeping while the other three are pinned, per lane.
    for k in range(4):
        for i in range(7):
            v = MED_VALUES[i]
            rows.append((pack4([v if m == k else 0 for m in range(4)]),
                         pack4([v if m == k else 255 for m in range(4)]),
                         pack4([v if m == k else 128 for m in range(4)])))
    # Two-equal ties and three-equal ties in every lane.
    for pair in ((0, 0, 1), (1, 1, 0), (128, 128, 0), (255, 255, 0),
                 (0, 128, 128), (255, 128, 128)):
        rows.append((pack4([pair[0]] * 4), pack4([pair[1]] * 4),
                     pack4([pair[2]] * 4)))
    return rows


def _div3_rows():
    rows = []
    # Every seventh 3-pixel sum, decomposed so that all three bytes differ.
    for s in range(0, 766, 7):
        low = min(255, s)
        middle = min(255, s - low)
        high = s - low - middle
        rows.append((pack4([low, high, middle, s & 0xFF]),
                     pack4([middle, low, high, (s >> 3) & 0xFF]),
                     pack4([high, middle, low, (s >> 1) & 0xFF])))
    # One lane sweeping its full sum range while the others stay at zero.
    for k in range(4):
        for t in range(0, 766, 29):
            low = min(255, t)
            middle = min(255, t - low)
            high = t - low - middle
            rows.append((pack4([low if m == k else 0 for m in range(4)]),
                         pack4([middle if m == k else 0 for m in range(4)]),
                         pack4([high if m == k else 0 for m in range(4)])))
    # Rounding boundaries: sums 0..11 and the 254/255/256 and 764/765 seams.
    for t in list(range(12)) + [253, 254, 255, 256, 257, 511, 512, 763, 764, 765]:
        low = min(255, t)
        middle = min(255, t - low)
        high = t - low - middle
        rows.append((pack4([low, 255, t & 0xFF, 0]),
                     pack4([middle, 0, (t * 3) & 0xFF, 255]),
                     pack4([high, 0, (t >> 1) & 0xFF, 0])))
    return rows


def _g5_rows():
    rows = []
    # Constant rows under all four edge-address modes: the extension bytes hold
    # the same level as the centres, so every lane is a fixed point.
    for value in G5_VALUES:
        for mode in (0, 1, 2, 3):
            rows.append((pack4([value] * 4), pack4([value] * 4), mode))
    # Malformed control byte: response is zeroed and no tap is filtered.
    for junk in (0x00000100, 0x0000FF00, 1 << 31, 0x01000000):
        rows.append((pack4([16, 32, 48, 64]), 0, junk))
    # Constant centres with inconsistent supplied extensions: modes 0 and 2 must
    # pick b up, while the mirrored modes 1 and 3 ignore it.
    for value in G5_VALUES:
        for mode in (0, 1, 2, 3):
            rows.append((pack4([value] * 4), pack4([0, 255, 128, 0]), mode))
    # Linear ramps with consistent supplied neighbours: exact pass-through.
    for base in range(0, 56):
        rows.append((pack4([base + k for k in range(4)]),
                     pack4([base, base + 1, base + 4, base + 5]), 0))
    # Same ramps on the mirror path: only the interior pixels stay exact.
    for base in range(0, 56):
        rows.append((pack4([base + k for k in range(4)]),
                     pack4([base, base + 1, base + 4, base + 5]), 3))
    # Hard steps and impulses through both addressings.
    for edge in (1, 2, 3, 7, 8, 32, 64, 100, 127, 128, 170, 254, 255):
        rows.append((pack4([0, 0, edge, edge]), pack4([255, 0, edge, 255]), 0))
        rows.append((pack4([edge, 255, 255, edge]), pack4([edge, 1, 0, 255]), 1))
    # Mixed addressing: only the left edge is reflected, so lanes 0 and 1 see
    # the mirror taps while lanes 2 and 3 see the supplied line buffer.
    for edge in (1, 2, 3, 7, 8, 32, 64, 100, 127, 128, 170, 254, 255):
        rows.append((pack4([edge, 0, 0, edge]), pack4([0, edge, edge, 0]), 1))
        rows.append((pack4([0, edge, edge, 0]), pack4([edge, 0, 0, edge]), 2))
    return rows


def _bayer_rows():
    rows = []
    # Smooth / vertical-edge / horizontal-edge blocks per green level.
    for g in (0, 1, 8, 64, 127, 128, 192, 254, 255):
        rows.append((pack4([g, g // 2, g, (3 * g) % 256]),
                     pack4([g // 3, g, g // 2, g]), pack4([g, g, 0, 0])))
        rows.append((pack4([g, 255 - g, g, g // 4]),
                     pack4([g, 255 - g, 255 - g, g]), pack4([g, 0, 0, 0])))
        rows.append((pack4([0, g, 255, g]),
                     pack4([g, 128, g, 0]), pack4([255, 0, 0, 0])))
    # Malformed control words: everything above c[15] must be zero.
    for junk in (0x00010000, 0x00FF0000, 1 << 31, 1 << 16, 0x80008000):
        rows.append((pack4([1, 2, 3, 4]), pack4([5, 6, 7, 8]), junk))
    # Tie grid: identical green pairs, forcing the isotropic path.
    for centre in (0, 16, 128, 240, 255):
        for g in (0, 16, 128, 240, 255):
            rows.append((pack4([g, centre, g, centre]),
                         pack4([centre, g, centre, g]), pack4([g, g, 0, 0])))
    # Asymmetric gradients driving one direction only.
    for k in range(28):
        rows.append((pack4([k * 4 % 256, 200 - k, (k * 7) % 256, 9]),
                     pack4([3, (k * 5) % 256, 128 + k, (k * 9) % 256]),
                     pack4([255 - k, k, 0, 0])))
    # Directional crossover sweep: Sv-Sh changes sign partway through, so the
    # three-way select and the estimate both move on every row.
    for d in range(48):
        rows.append((pack4([d, 100, 200 - d, 0]),
                     pack4([0, d, 150, 90]), pack4([128, 64, 0, 0])))
    # Centre sweep on both lanes with fixed green rings: exercises the
    # centre-consistency term |Gx+Gy-2C| alone.
    for centre in range(0, 48):
        v = centre * 5 % 256
        rows.append((pack4([64, v, 192, centre]),
                     pack4([32, 128, v, 160]), pack4([96, centre, 0, 0])))
    # Single-green dropout and impulse patterns: one tap missing or one tap
    # pinned at full scale, on both lanes.
    for pattern in ((0, 255, 128), (128, 255, 0), (0, 0, 255), (255, 0, 0)):
        for v in (0, 32, 96, 160, 224, 255):
            rows.append((pack4([v, pattern[0], v, pattern[1]]),
                         pack4([pattern[2], v, 255 - v, v]),
                         pack4([v, 255 - v, 0, 0])))
    return rows


def _hist_rows():
    rows = []
    # Frame start: clear the array and read bin 0.
    rows.append((0, 0, 1 << 31))
    # Every bin opened once by 8 identical pixels: distinct aux newly-active bit.
    for i in range(16):
        pixels = pack4([(i << 4) | i] * 4)
        rows.append((pixels, pixels, i << 4))
    # Malformed control words: result=aux=0 and the array must not move.
    for junk in (0x00000001, 0x00000100, 0x01000000, 0x10000000, 0x20000010,
                 0x3F000000):
        rows.append((pack4([16, 32, 48, 64]), pack4([64, 48, 32, 16]), junk))
    # Preload sweep: the after-read-out count is the broadcast pattern 257*pv,
    # so all 64 of these responses differ by construction.
    for pv in range(64):
        rows.append((0, 0, (1 << 30) | (pv << 16) | ((pv & 15) << 4)))
    # Preload plus a known number of hits landing in the reported bin.
    for pv in range(64, 96):
        hits = (pv % 8) + 1
        pixels = pack4([(pv << 4) if k < hits else 0 for k in range(4)])
        rows.append((pixels, 0, (1 << 30) | (pv << 16) | ((pv & 15) << 4)))
    # Overflow: arm every bin to 65535, then hit one of them.
    for k in range(8):
        rows.append((0, 0, (1 << 30) | (255 << 16) | (k << 4)))
        pixels = pack4([k << 4] * 4)
        rows.append((pixels, pixels, (k << 4)))
    # Restart while the array is saturated: report the stale count, fold this
    # beat's pixels into a zeroed array.
    rows.append((pack4([0xF0, 0x0F, 0x55, 0xAA]),
                 pack4([0xF0, 0xF0, 0x0F, 0x0F]), (1 << 31) | (15 << 4)))
    # Spread and duplicate-heavy patterns after a fresh clear.
    for i in range(12):
        rows.append((pack4([((i + j) & 15) << 4 for j in range(4)]),
                     pack4([(3 * i & 15) << 4, (i & 15) << 4,
                            (3 * i & 15) << 4, (3 * i & 15) << 4]),
                     (1 << 31) if i == 0 else ((i & 15) << 4)))
    # Accumulation walk: the same eight pixels folded repeatedly into bin 5, so
    # the read-out port shows a strictly rising count.
    for _ in range(24):
        rows.append((pack4([0x50, 0x51, 0x5F, 0x55]), 0, 5 << 4))
    # Malformed control words once more, this time over live pixel data.
    for junk in (0x0000000F, 0x0000FF00, 0x3F000000, 0x20000000):
        rows.append((pack4([0x01, 0x23, 0x45, 0x67]),
                     pack4([0x89, 0xAB, 0xCD, 0xEF]), junk))
    # High preload sweep past the board set: broadcast patterns 96..159.
    for pv in range(96, 160):
        rows.append((0, 0, (1 << 30) | (pv << 16) | ((pv & 15) << 4)))
    return rows


def _dither_rows():
    rows = []
    # Six frames, each restarting the phase and walking a rising pixel ramp.
    for base in (0, 16, 64, 128, 192, 240):
        rows.append((pack4([base + k for k in range(4)]), 0, 1 << 31))
        for beat in range(7):
            level = base + 4 * beat
            rows.append((pack4([level + k for k in range(4)]),
                         pack4([0, 0, 0, (beat * 17) & 0xFF]), 0))
    # Malformed control words: no level, no phase advance.
    for junk in (0x00000001, 0x00000100, 0x01000000, 0x40000000,
                 0x00FF0000, 0x20000008):
        rows.append((pack4([1, 2, 3, 4]), pack4([5, 6, 7, 8]), junk))
    # Line wrap: 66 beats at 4 pixels per beat walk x past 255 so the y counter
    # must carry, and the next line starts at x=4 again.
    rows.append((pack4([7, 7, 7, 7]), 0, 1 << 31))
    for beat in range(66):
        rows.append((pack4([120, 130, 140, 150]),
                     pack4([0x7F, 0x81, beat & 0x7F, 0]), 0))
    # Feedback and ceiling probes: clamp flags and level saturation.
    for v in (0, 8, 64, 128, 192, 248, 255):
        rows.append((pack4([v] * 4), pack4([0x80, 0x7F, 0xFF, 0x01]), 1 << 31))
        rows.append((pack4([255, 0, 255, 0]), pack4([0x01, 0xFF, 0x7F, 0x81]), 0))
    return rows


_BUILDERS = {
    'img_sobel_mag_u8': _sobel_rows,
    'img_median3_u8x4': _median_rows,
    'img_box_blur_div3_u8x4': _div3_rows,
    'img_gaussian5_edge_u8': _g5_rows,
    'img_bayer_dual_lane': _bayer_rows,
    'img_histogram_bin16_update': _hist_rows,
    'img_dither_bayer4x4': _dither_rows,
}

# The random tail stays mostly on the legal input subspace so rows past the
# board set exercise data paths, not only the fault path; the periodic
# full-width rows below still re-test the malformed-control branch.
_TAIL_MASKS = {
    'img_sobel_mag_u8': (0x00FFFFFF, 0x00FFFFFF, 0x00FFFFFF),
    'img_gaussian5_edge_u8': (MASK, MASK, 0x00000003),
    'img_bayer_dual_lane': (MASK, MASK, 0x0000FFFF),
    'img_histogram_bin16_update': (MASK, MASK, 0xC000_00F0),
    'img_dither_bayer4x4': (MASK, MASK, 0x80000000),
}

_TAIL_FAULT_STRIDE = {'img_sobel_mag_u8': 17, 'img_gaussian5_edge_u8': 19,
                      'img_bayer_dual_lane': 23, 'img_histogram_bin16_update': 29,
                      'img_dither_bayer4x4': 31}


def vectors(name, count=320):
    """Board set first, then a seeded random tail."""
    rows = list(_BUILDERS[name]())
    rng = Random(0x19A0E000 + sum(name.encode()))
    masks = _TAIL_MASKS.get(name, (MASK, MASK, MASK))
    stride = _TAIL_FAULT_STRIDE.get(name)
    while len(rows) < count:
        if stride and (len(rows) - 128) % stride == 0:
            rows.append((rng.getrandbits(32), rng.getrandbits(32),
                         rng.getrandbits(32)))
            continue
        rows.append((rng.getrandbits(32) & masks[0],
                     rng.getrandbits(32) & masks[1],
                     rng.getrandbits(32) & masks[2]))
    return rows[:count]


# ==========================================================================
# Reference checks against hand-derived values.
# ==========================================================================

def selftest():
    """Hand-derived expectations for the independent integer models."""
    checks = 0

    # --- Sobel -------------------------------------------------------------
    # A flat window has exactly zero gradient and no sign bit.
    assert step('img_sobel_mag_u8', 0x555555, 0x555555, 0x555555)[:3] == (0, 0, 0)
    checks += 1
    # Vertical edge, right side brighter by e: Gx = (e+2e+e) - 0 = 4e, Gy = 0.
    window = pack4([0, 0, 20])
    assert step('img_sobel_mag_u8', window, window, window)[:3] == (80, 0, 0)
    checks += 1
    # The same edge reversed: Gx = -80, so only aux[0] is set.
    window = pack4([20, 0, 0])
    assert step('img_sobel_mag_u8', window, window, window)[:3] == (80, 1, 0)
    checks += 1
    # Horizontal edge, bottom brighter by e: Gy = (e+2e+e) = 120, Gx = 0.
    assert step('img_sobel_mag_u8', pack4([0, 0, 0]), pack4([0, 0, 0]),
                pack4([30, 30, 30]))[:3] == (120, 0, 0)
    checks += 1
    # Bottom darker: Gy = -120, so only aux[1] is set.
    assert step('img_sobel_mag_u8', pack4([30, 30, 30]), pack4([0, 0, 0]),
                pack4([0, 0, 0]))[:3] == (120, 2, 0)
    checks += 1
    # Both gradients negative: Gx = -(20+40+20) = -60, Gy = -60 -> 120, signs 3.
    assert step('img_sobel_mag_u8', pack4([20, 20, 0]), pack4([20, 0, 0]),
                pack4([0, 0, 0]))[:3] == (120, 3, 0)
    checks += 1
    # Full bottom row against an empty top row: Gx = 0, Gy = 1020 -> clipped.
    assert step('img_sobel_mag_u8', pack4([0, 0, 0]), pack4([0, 0, 0]),
                pack4([255, 255, 255]))[:3] == (255, 4, 0)
    checks += 1
    # Clipped corner case, hand-evaluated: top=[255,255,255], mid=[255,0,0],
    # bottom=[0,0,0]. Gx = (255+0+0)-(255+510+0) = -510 and
    # Gy = 0-(255+510+255) = -1020, so |Gx|+|Gy| = 1530 -> clipped to 255 with
    # both gradient signs plus the clip flag: aux = 0b111.
    r, x, f, _ = step('img_sobel_mag_u8', pack4([255, 255, 255]),
                      pack4([255, 0, 0]), pack4([0, 0, 0]))
    assert (r, x, f) == (255, 7, 0)
    checks += 1
    # Border of the clipping region: |Gx| = 4e and |Gy| = 0, so the largest
    # unclipped single-gradient magnitude is e = 63 (252) and e = 64 (256)
    # already clips.
    assert step('img_sobel_mag_u8', *(pack4([0, 0, 63]),) * 3)[:2] == (252, 0)
    assert step('img_sobel_mag_u8', *(pack4([0, 0, 64]),) * 3)[:2] == (255, 4)
    checks += 2
    # Padding words zero the response and raise fault.
    assert step('img_sobel_mag_u8', 1 << 24, 0, 0)[:3] == (0, 0, 1)
    assert step('img_sobel_mag_u8', 0, 0, 0x80000000)[:3] == (0, 0, 1)
    assert step('img_sobel_mag_u8', 0, 0x01000000, 0)[:3] == (0, 0, 1)
    checks += 3
    # Flat identity: any constant 3x3 window has zero magnitude and no signs.
    for value in SOBEL_FLAT:
        window = pack4([value] * 3)
        assert step('img_sobel_mag_u8', window, window, window)[:3] == (0, 0, 0)
        checks += 1
    # Analytic sweep: magnitude 4e with no clip while 4e <= 252.
    for e in range(1, 63):
        window = pack4([0, 0, e])
        r, x, f, _ = step('img_sobel_mag_u8', window, window, window)
        assert (r, x, f) == (4 * e, 0, 0)
        window = pack4([e, 0, 0])
        r, x, f, _ = step('img_sobel_mag_u8', window, window, window)
        assert (r, x, f) == (4 * e, 1, 0)
        checks += 2

    # --- Median of 3 -------------------------------------------------------
    # Hand medians, checked in all six permutations so a mis-wired comparator
    # cannot hide behind one lucky ordering, plus the tie/identity flags.
    hand_median = {(0, 0, 1): 0, (0, 1, 1): 1, (1, 2, 3): 2, (0, 255, 128): 128,
                   (127, 128, 129): 128, (255, 255, 254): 255, (2, 2, 2): 2,
                   (5, 3, 9): 5, (10, 10, 9): 10, (0, 0, 0): 0,
                   (255, 0, 128): 128, (86, 85, 253): 86, (1, 254, 127): 127}
    for (u, v, w), expected in hand_median.items():
        for order in ((u, v, w), (u, w, v), (v, u, w), (v, w, u),
                      (w, u, v), (w, v, u)):
            r, x, f, _ = step('img_median3_u8x4', order[0], order[1], order[2])
            assert r == expected and f == 0
            assert (x & 1) == (1 if len({u, v, w}) < 3 else 0)
            assert ((x >> 4) & 1) == (1 if len({u, v, w}) == 1 else 0)
            checks += 1
    # Exhaustive over a small domain; lanes 1..3 see only zeros and are pinned.
    for u in range(4):
        for v in range(4):
            for w in range(4):
                r, x, _, _ = step('img_median3_u8x4', u, v, w)
                assert r & 0xFF == sorted((u, v, w))[1]
                assert (r >> 8) == 0
                assert (x >> 1) & 7 == 7            # zero triples always tie
                checks += 1
    # Lane independence: a hot lane must not disturb a cold one.
    r, x, _, _ = step('img_median3_u8x4', 0x03020100, 0x04040404, 0x01020304)
    assert r == 0x03020304
    assert x & 0xF == 0x05                           # lanes 0 and 2 tie
    assert x & 0xF0 == 0
    checks += 1

    # --- Exact divide by 3 -------------------------------------------------
    # Every reachable 3-pixel sum, against the (S+1)//3 floor form, which is a
    # different expression from the model's divmod/round-up rule.
    for s in range(766):
        low = min(255, s)
        middle = min(255, s - low)
        high = s - low - middle
        r, x, f, _ = step('img_box_blur_div3_u8x4', low, middle, high)
        quotient, remainder = divmod(s, 3)
        assert r & 0xFF == (s + 1) // 3 == quotient + (1 if remainder == 2 else 0)
        assert (x & 1) == (1 if remainder == 2 else 0)
        assert (x >> 4) & 1 == (1 if remainder == 0 else 0)
        assert 0 <= r & 0xFF <= 255
        checks += 1
    # Hand values and lane independence.
    assert step('img_box_blur_div3_u8x4', 255, 255, 255)[0] == 0xFF
    assert step('img_box_blur_div3_u8x4', 1, 1, 1)[0] == 1
    assert step('img_box_blur_div3_u8x4', 0, 0, 2)[0] == 1
    assert step('img_box_blur_div3_u8x4', 0, 0, 1)[0] == 0
    assert step('img_box_blur_div3_u8x4', 255, 255, 254)[0] == 255
    checks += 5
    for k in range(4):
        r, x, _, _ = step('img_box_blur_div3_u8x4', 250 << (8 * k),
                          5 << (8 * k), 0)
        # Only lane k has a nonzero triple; the three idle lanes sum to 0,
        # which is an exact multiple of 3, so their aux[7:4] bits are set.
        assert r == 85 << (8 * k) and x == 0xF0
        checks += 1

    # --- 5-tap Gaussian with edge addressing -------------------------------
    # Hand-derived mirror case: x = [0,0,255,255] reflected at both ends,
    # e[-2]=x1=0, e[-1]=x0=0, e[+4]=x3=255, e[+5]=x2=255.
    # sums 255, 1275, 2805, 3825 -> (255+8)>>4=16, 80, 175, 239;
    # residuals 15, 11, 5, 1 -> round-up flags 0b0011, plus mode echo 0b11<<4.
    r, x, f, _ = step('img_gaussian5_edge_u8', pack4([0, 0, 255, 255]), 0, 3)
    assert (r, x, f) == (pack4([16, 80, 175, 239]), 0x03 | 0x30, 0)
    checks += 1
    # Constant rows are fixed points of a /16 filter in all four addressings,
    # because the extension bytes carry the same level as the centres.
    for value in G5_VALUES:
        for mode in (0, 1, 2, 3):
            r, x, f, _ = step('img_gaussian5_edge_u8', pack4([value] * 4),
                              pack4([value] * 4), mode)
            assert r == pack4([value] * 4) and f == 0
            assert (x & 0xF) == 0 and (x >> 4) & 3 == mode
            checks += 1
    # Supplied extensions really are used in mode 0: centres 16 with
    # e[-2]=0, e[-1]=255, e[+4]=128, e[+5]=0 gives sums 1196, 495, 368, 688 ->
    # 75, 31, 23, 43 with the residual round-up on lanes 0 and 1 only.
    r, x, f, _ = step('img_gaussian5_edge_u8', pack4([16] * 4),
                      pack4([0, 255, 128, 0]), 0)
    assert (r, x, f) == (pack4([75, 31, 23, 43]), 0x03, 0)
    checks += 1
    # The same word mirrored ignores b entirely, so it is the fixed point again.
    r, x, f, _ = step('img_gaussian5_edge_u8', pack4([16] * 4),
                      pack4([0, 255, 128, 0]), 3)
    assert (r, x, f) == (pack4([16] * 4), 0x30, 0)
    checks += 1
    # A linear ramp with consistent supplied neighbours passes through exactly:
    # taps 10,20,30,40,50 -> (10+80+180+160+50+8)>>4 = 30 = x0.
    r, x, f, _ = step('img_gaussian5_edge_u8', pack4([30, 40, 50, 60]),
                      pack4([10, 20, 70, 80]), 0)
    assert (r, x, f) == (pack4([30, 40, 50, 60]), 0, 0)
    checks += 1
    # The same ramp mirrored instead of supplied: sums 550, 650, 790, 890 ->
    # 34, 41, 49, 56 with round-up flags on lanes 1 and 3.
    r, x, f, _ = step('img_gaussian5_edge_u8', pack4([30, 40, 50, 60]),
                      pack4([10, 20, 70, 80]), 3)
    assert (r, x, f) == (pack4([34, 41, 49, 56]), 0x0A | 0x30, 0)
    checks += 1
    # Control word must be zero above bit 1.
    assert step('img_gaussian5_edge_u8', 0, 0, 0x00000100)[:3] == (0, 0, 1)
    assert step('img_gaussian5_edge_u8', 0, 0, 1 << 31)[:3] == (0, 0, 1)
    checks += 2

    # --- Bayer green interpolation ----------------------------------------
    # Lane0: C=40, Gl=100, Gr=200, Gu=120, Gd=180 ->
    #   Sv = 2*60 + |300-80| = 120+220 = 340 < Sh = 2*100 + 220 = 420
    #   -> vertical, estimate = (120+180+1)//2 = 150.
    # Lane1: C=30, Gl=180, Gr=190, Gu=200, Gd=210 ->
    #   Sv = 20+350 = 370 > Sh = 20+310 = 330 -> horizontal,
    #   estimate = (180+190+1)//2 = 185.
    r, x, f, _ = step('img_bayer_dual_lane', pack4([100, 40, 200, 0]),
                      pack4([0, 180, 30, 190]), pack4([120, 210, 0, 0]))
    assert (r, x, f) == (150 | (185 << 8) | (40 << 16) | (30 << 24), 0x1 | 0x8, 0)
    checks += 1
    # Uniform green field: identical pairs -> tie -> isotropic mean 64.
    r, x, f, _ = step('img_bayer_dual_lane', pack4([64, 200, 64, 200]),
                      pack4([200, 64, 200, 64]), pack4([64, 64, 0, 0]))
    assert (r, x, f) == (64 | (64 << 8) | (200 << 16) | (200 << 24), 0x0F, 0)
    checks += 1
    # A hard vertical green split must lose to a flat horizontal pair:
    # Sv = 2*100 + |100-20| = 280 > Sh = 0 + |200-20| = 180 -> horizontal,
    # estimate = (100+100+1)//2 = 100.
    r, x, _, _ = step('img_bayer_dual_lane', pack4([100, 10, 100, 0]),
                      pack4([0, 100, 0, 0]), 0)
    assert (r & 0xFF, x & 3) == (100, 0x2)
    checks += 1
    # Centre echo and control-word fault.
    r, _, f, _ = step('img_bayer_dual_lane', pack4([11, 22, 33, 44]),
                      pack4([55, 66, 77, 88]), pack4([99, 111, 0, 0]))
    assert (r >> 16) & 0xFF == 22 and (r >> 24) & 0xFF == 77 and f == 0
    assert step('img_bayer_dual_lane', 0, 0, 1 << 16)[:3] == (0, 0, 1)
    assert step('img_bayer_dual_lane', 0, 0, 1 << 31)[:3] == (0, 0, 1)
    checks += 3

    # --- 16-bin histogram --------------------------------------------------
    # Restart beat: the array is cleared first, then a and b are folded in. Two
    # zero words are eight pixels of value 0, i.e. eight hits in bin 0, and bin
    # 0 reads out as 0 before / 8 after with its newly-opened aux bit set.
    r, x, f, state = step('img_histogram_bin16_update', 0, 0, 1 << 31)
    assert (r, x, f, state) == (8 << 16, 1 << 16, 0, 8)
    checks += 1
    # Hand-counted distribution: a = 0x0F,0x10,0x1F,0x20 and
    # b = 0x20,0x25,0x30,0x00 put 2, 2, 3, 1 pixels in bins 0..3, so bin 0 goes
    # 8 -> 10 (already open, no aux bit) while bins 1..3 open: aux 0xE<<16.
    r, x, f, state = step('img_histogram_bin16_update',
                          pack4([0x0F, 0x10, 0x1F, 0x20]),
                          pack4([0x20, 0x25, 0x30, 0x00]), 0, state)
    assert (r & 0xFFFF, (r >> 16) & 0xFFFF, f, x) == (8, 10, 0, 0x000E0000)
    for k, want in enumerate((10, 2, 3, 1)):
        assert (state >> (16 * k)) & 0xFFFF == want
    assert (state >> (16 * 4)) & 0xFFFF == 0
    checks += 1
    # Eight different bins in one fresh beat: exactly one hit each, hand counted.
    r, x, f, state = step('img_histogram_bin16_update',
                          pack4([0x00, 0x11, 0x22, 0x33]),
                          pack4([0x44, 0x55, 0x66, 0x77]), 1 << 31)
    assert (r & 0xFFFF, (r >> 16) & 0xFFFF, f) == (0, 1, 0)
    assert x == 0x00FF0000
    assert all(((state >> (16 * k)) & 0xFFFF) == (1 if k < 8 else 0)
               for k in range(16))
    checks += 1
    # Read-out of bin 5 while bin 0 accumulates eight more zeros.
    r, x, f, state = step('img_histogram_bin16_update', 0, 0, 5 << 4, state)
    assert (r & 0xFFFF, (r >> 16) & 0xFFFF, f, x) == (1, 1, 0, 0)
    assert (state & 0xFFFF) == 9 and (state >> 16) & 0xFFFF == 1
    checks += 1
    # Preload arms every bin with the broadcast pattern {pv,pv}, and the eight
    # zeros still land in bin 0 on top of it.
    r, x, f, state = step('img_histogram_bin16_update', 0, 0,
                          (1 << 30) | (0x40 << 16) | (5 << 4), state)
    assert all(((state >> (16 * k)) & 0xFFFF) == (0x4048 if k == 0 else 0x4040)
               for k in range(16))
    assert (r & 0xFFFF, (r >> 16) & 0xFFFF, x, f) == (1, 0x4040, 0, 0)
    checks += 1
    # Ceiling: arm 65535 in every bin, then hit bin 7 with 6 pixels and bin 0
    # with 2 - both saturate, both report an overflow bit and the beat faults.
    r, x, f, state = step('img_histogram_bin16_update', pack4([0x70] * 4),
                          pack4([0x70, 0x70, 0, 0]),
                          (1 << 30) | (255 << 16) | (7 << 4), state)
    assert f == 1 and (x & ((1 << 7) | 1)) == ((1 << 7) | 1)
    assert (state >> (16 * 7)) & 0xFFFF == 0xFFFF and (r >> 16) & 0xFFFF == 0xFFFF
    assert r & 0xFFFF == 0x4040
    checks += 1
    # Restart reports the stale count and re-opens bin 0 on the fresh array.
    r, x, f, state = step('img_histogram_bin16_update', 0, 0,
                          (1 << 31) | (7 << 4), state)
    assert (r, x, f, state) == (0xFFFF, 1 << 16, 0, 8)
    checks += 1
    # Malformed control: zero response and the array is left exactly as it was.
    for junk in (0x00000001, 0x01000000, 0x0000FF00, 0x20000000):
        assert step('img_histogram_bin16_update', 0xFF, 0xFF, junk, 0x1234)[:4] \
            == (0, 0, 1, 0x1234)
        checks += 1

    # --- Ordered Bayer 4x4 dither -----------------------------------------
    # The bit-interleaved selection the RTL uses must equal the published
    # 4x4 matrix, which the model reads as a table.
    for row in range(4):
        for col in range(4):
            t = col ^ row
            derived = ((t & 1) << 3) | ((row & 1) << 2) | \
                      (((t >> 1) & 1) << 1) | (row >> 1)
            assert derived == BAYER4x4[row][col], (row, col)
            checks += 1
    # Restart places the beat on row 0, cols 0..3 -> thresholds 0,8,2,10.
    # v=0 -> num = 16*M = 0,128,32,160 -> levels all 0, residual = (num&255)-128.
    r, x, f, state = step('img_dither_bayer4x4', 0, 0, 1 << 31)
    assert (r & 0xFF, r >> 16, f, state) == (0x00, 0x0004, 0, 4)
    assert x == ((-128 & 0xFF) | (0 << 8) | ((32 - 128) & 0xFF) << 16 |
                 (32 << 24))
    checks += 1
    # The phase advances 4 pixels per beat: the 64th beat (x entering at 252)
    # wraps past 255 and carries into y, and the 65th starts the new line.
    state = 0
    for beat in range(65):
        r, x, f, state = step('img_dither_bayer4x4', pack4([128] * 4), 0, 0, state)
        assert f == 0
        if beat == 63:
            assert state == (1 << 8) and (r >> 16) & 0xFF == 0
    assert state == (4 | (1 << 8))
    assert (r >> 16) & 0xFF == 4 and (r >> 24) & 0xFF == 1
    checks += 1
    # Restart then v=255: num = 1020+16M = 1020,1148,1052,1180 -> raw levels
    # 3,4,4,4, so all lanes report level 3 and lanes 1..3 report saturation.
    r, x, f, _ = step('img_dither_bayer4x4', pack4([255] * 4), 0, 1 << 31)
    assert (r & 0xFF) == 0xFF and (r >> 12) & 0xF == 0b1110
    checks += 1
    # Error feedback: 200+127 clamps high, 20-128 clamps low,
    # 100+0 with M=2 -> num=432 -> level 1, 100+0 with M=10 -> num=560 -> level 2.
    r, x, f, _ = step('img_dither_bayer4x4', pack4([200, 20, 100, 100]),
                      pack4([0x7F, 0x80, 0, 0]), 1 << 31)
    assert (r >> 8) & 0xF == 0b0011
    assert r & 0x3 == 3 and (r >> 2) & 0x3 == 0
    assert (r >> 4) & 0x3 == 1 and (r >> 6) & 0x3 == 2
    checks += 1
    # Malformed control: no level, no phase advance.
    assert step('img_dither_bayer4x4', 0, 0, 0x00000100)[:4] == (0, 0, 1, 0)
    checks += 1
    return checks
