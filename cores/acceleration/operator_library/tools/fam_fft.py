"""FFT and spectral building blocks: butterflies, twiddle address math, CORDIC.

Every product in this family is a hand-instanced GW5A MULT12X12 signed slice,
never a Verilog `*`: `synth_gowin -noalu` will not infer the hard block from an
asterisk, and an inferred 12x12 costs hundreds of LUTs of combinatorial depth
that 50 MHz cannot close.  The Python model below computes the same product with
exact integers, which is the independent definition of what the slice returns,
so `sim/mult12x12_model.v` must be on every simulation file list (OSS CAD Suite
ships the cell with an empty body) and synthesis never reads it.

Fixed point: samples are signed 12-bit and twiddles are Q1.10 (unity magnitude
= 1024 counts), so one slice plus a 10-bit requantise shift is one real product.
The address-math, add/sub and magnitude cores use no multiplier at all, which is
exactly why they hold II=1 next to the slices.  CORDIC rotation is deliberately
multiplier-free too: twelve signed shift/add micro-rotations and an integer
atan(2^-i) table, which selftest() re-derives with math.atan.

Template body vocabulary (re-initialised on every evaluation):
    r x f temp mask pa pb pc ph pl ext wide wide2 swide swide2 sa sb sc data
    i j idx lane sh state_r state_n
Anything else lives in `decl`, which is module scope and may hold the slice
instances and functions -- that is how the multipliers and the bit-reverse cell
are attached.
"""
import math
from itertools import product
from random import Random

FAMILY = 'fft'
MASK = (1 << 32) - 1
MODEL = 'sim/mult12x12_model.v'

CORES = []


def core(name, spec, body, advantage, lanes, decl='', stateful=False, rom=None):
    entry = dict(name=name, family=FAMILY, spec=spec, body=body, decl=decl,
                 advantage=advantage, lanes=lanes, stateful=stateful,
                 sim_extra=[MODEL])
    if rom:
        entry['rom'] = rom
    CORES.append(entry)


def slice_decl(out, xa, xb):
    """One combinational MULT12X12: `out` is the signed 24-bit product."""
    return (f'wire [23:0] {out}_raw;\n'
            f'wire signed [23:0] {out} = $signed({out}_raw);\n'
            f'MULT12X12 u_{out} (.DOUT({out}_raw), .A({xa}), .B({xb}), '
            f".CLK(2'b00), .CE(2'b00), .RESET(2'b00));\n")


def sreg(*names):
    """Signed 12-bit slice operand / sample registers."""
    return 'reg signed [11:0] ' + ', '.join(names) + ';\n'


def sreg_n(width, *names):
    """Signed registers of an arbitrary width (sign-extension staging)."""
    return 'reg signed [%d:0] ' % (width - 1) + ', '.join(names) + ';\n'


def ureg_n(width, *names):
    """Unsigned registers of an arbitrary width."""
    return 'reg [%d:0] ' % (width - 1) + ', '.join(names) + ';\n'


def s_bits(value, width):
    value &= (1 << width) - 1
    return value - (1 << width) if value >> (width - 1) else value


def s12(value):
    return s_bits(value, 12)


def s14(value):
    return s_bits(value, 14)


def s15(value):
    return s_bits(value, 15)


def s16(value):
    return s_bits(value, 16)


def s18(value):
    return s_bits(value, 18)


def ub(word, pos, width):
    """Unsigned field extract: mirrors `word[pos+width-1:pos]`."""
    return (word >> pos) & ((1 << width) - 1)


def sb(word, pos, width):
    """Signed field extract: mirrors `$signed(word[pos+width-1:pos])`."""
    return s_bits(word >> pos, width)


def round_shift(value, shift):
    """Round half up then arithmetic shift: identical to signed `>>>`."""
    return value if shift == 0 else (value + (1 << (shift - 1))) >> shift


def clamp12(value):
    clamped = max(-2048, min(2047, value))
    return clamped, clamped != value


def clamp14(value):
    clamped = max(-8192, min(8191, value))
    return clamped, clamped != value


def clamp18(value):
    clamped = max(-131072, min(131071, value))
    return clamped, clamped != value


def field(state, pos, width):
    return s_bits(state >> pos, width)


def put(value, pos, width):
    return (value & ((1 << width) - 1)) << pos


def axis_product(re, im, t):
    """Multiply (re+im*i) by the t-th axis twiddle 1, -j, -1, +j exactly."""
    return ((re, im), (im, -re), (-re, -im), (-im, re))[t]


def gauss(u, v, wr, wi):
    """Gauss three-product complex multiply on signed operands.

    Returns (re_exact, im_exact, pre_add_clipped): re = P1-P2,
    im = P3-P1-P2 with P1=u*wr, P2=v*wi, P3=(u+v)*(wr+wi).  The two pre-adds
    have to fit one slice operand, so they saturate and raise a flag;
    |u+v| <= 2047 and |wr+wi| <= 2047 is the headroom this kernel asks of its
    caller.  With (wr,wi)=(1024,0) and no pre-add clipping it is the exact
    identity map.
    """
    su, clip_a = clamp12(u + v)
    sw, clip_b = clamp12(wr + wi)
    p1 = u * wr
    p2 = v * wi
    p3 = su * sw
    return p1 - p2, p3 - p1 - p2, int(clip_a or clip_b)


def br_bits(value, width):
    out = 0
    for bit in range(width):
        out = (out << 1) | ((value >> bit) & 1)
    return out


def quadrant_pair(q, cos, sin):
    """Reconstruct (re, im) of a first-quadrant twiddle in any quadrant.

    Exactly the swap/negate rule twiddle_index16 emits: swap=q[0], negate
    re=q[0]^q[1], negate im=q[1].  Hand-checked against the four quarter turns
    (q=1 -> (-sin, +cos), q=2 -> (-cos, -sin), q=3 -> (+sin, -cos)), so a
    quarter-period table plus three wire signs covers the full circle with no
    arithmetic.
    """
    swap = q & 1
    neg_re = ((q >> 1) ^ swap) & 1
    neg_im = (q >> 1) & 1
    pre_re = sin if swap else cos
    pre_im = cos if swap else sin
    wr = -pre_re if neg_re else pre_re
    wi = -pre_im if neg_im else pre_im
    return wr, wi


# atan(2^-i) in units of pi/8192, i = 0..11.  Hand-derived CORDIC convergence
# table; selftest() re-derives every entry with math.atan so a transcription
# slip in either direction fails loudly.
CORDIC_TAB = [2048, 1209, 639, 324, 163, 81, 41, 20, 10, 5, 3, 1]


def cordic_tab():
    return [int(round(math.atan(2.0 ** -i) * 8192.0 / math.pi)) for i in range(12)]


def cordic_gain(iters):
    """Uncompensated CORDIC gain A(i) = prod sqrt(1 + 4^-k), k = 0..i-1."""
    gain = 1.0
    for k in range(iters):
        gain *= math.sqrt(1.0 + 4.0 ** -k)
    return gain


# -----------------------------------------------------------------------------
# 1. r2_bfly_s12: one radix-2 butterfly node, two slices, II=1.
# -----------------------------------------------------------------------------
R2_DECL = (sreg('q_xr', 'q_xi', 'q_yr', 'q_yi', 'q_dr', 'q_di', 'q_gr')
           + "reg signed [12:0] q_sr, q_si, q_dr13, q_di13, q_br, q_bm;\n"
           + "reg signed [25:0] q_rs, q_is;\n"
           + "reg [2:0] q_ax;\n"
           + "reg q_cr, q_ci, q_or, q_oi;\n"
           + slice_decl('q_p0', 'q_dr', 'q_gr')
           + slice_decl('q_p1', 'q_di', 'q_gr'))

core('r2_bfly_s12',
    "Radix-2 butterfly node: (x+y, (x-y)*W) with W restricted to the four axis "
    "values 1,-j,-1,+j scaled by a Q1.10 gain, so two MULT12X12 slices cover "
    "the whole twiddled leg at II=1. a[11:0]=x.re, a[23:12]=x.im, b[11:0]=y.re, "
    "b[23:12]=y.im (signed 12), a[31:24]=b[31:24]=0. c[11:0]=gain g signed "
    "Q1.10 (1024=unity), c[14:12]=axis code t (0=1, 1=-j, 2=-1, 3=+j), "
    "c[31:15]=0; any other bit pattern is a malformed beat (result=aux=0, "
    "fault=1). result[12:0]=(x+y).re and result[25:13]=(x+y).im signed 13 (the "
    "sum of two signed 12-bit values never overflows 13 bits), "
    "result[26]=(x-y)*W clipped to the slice width, result[31:29]=t. "
    "aux[11:0] and aux[23:12] are the re/im of round_half_up((x-y)*W*g)>>10 "
    "clipped to signed 12, aux[24]=re saturated, aux[25]=im saturated, "
    "aux[26]=difference clipped, aux[31:27]=0. fault=1 on a malformed beat, a "
    "clipped difference or a saturated output lane.",
    "q_xr=a[11:0]; q_xi=a[23:12]; q_yr=b[11:0]; q_yi=b[23:12];\n"
    "q_gr=c[11:0]; q_ax=c[14:12];\n"
    "q_sr=q_xr+q_yr; q_si=q_xi+q_yi;\n"
    "q_dr13=q_xr-q_yr; q_di13=q_xi-q_yi;\n"
    "q_cr=1'b0; q_ci=1'b0; q_or=1'b0; q_oi=1'b0;\n"
    "if(a[31:24]!=0 || b[31:24]!=0 || c[31:15]!=0) f=1'b1;\n"
    "else begin\n"
    "    case(q_ax)\n"
    "        3'd0: begin q_br=q_dr13; q_bm=q_di13; end\n"
    "        3'd1: begin q_br=q_di13; q_bm=-q_dr13; end\n"
    "        3'd2: begin q_br=-q_dr13; q_bm=-q_di13; end\n"
    "        default: begin q_br=-q_di13; q_bm=q_dr13; end\n"
    "    endcase\n"
    "    if(q_br>13'sd2047) begin q_dr=12'h7ff; q_cr=1'b1; end\n"
    "    else if(q_br<-13'sd2048) begin q_dr=12'h800; q_cr=1'b1; end\n"
    "    else q_dr=q_br[11:0];\n"
    "    if(q_bm>13'sd2047) begin q_di=12'h7ff; q_ci=1'b1; end\n"
    "    else if(q_bm<-13'sd2048) begin q_di=12'h800; q_ci=1'b1; end\n"
    "    else q_di=q_bm[11:0];\n"
    "    swide=q_p0+24'sd512; swide=swide>>>10; q_rs=swide;\n"
    "    if(q_rs>26'sd2047) begin q_or=1'b1; q_rs=26'sd2047; end\n"
    "    else if(q_rs<-26'sd2048) begin q_or=1'b1; q_rs=-26'sd2048; end\n"
    "    else q_rs=q_rs;\n"
    "    x[11:0]=q_rs[11:0];\n"
    "    swide=q_p1+24'sd512; swide=swide>>>10; q_is=swide;\n"
    "    if(q_is>26'sd2047) begin q_oi=1'b1; q_is=26'sd2047; end\n"
    "    else if(q_is<-26'sd2048) begin q_oi=1'b1; q_is=-26'sd2048; end\n"
    "    else q_is=q_is;\n"
    "    x[23:12]=q_is[11:0];\n"
    "    x[24]=q_or; x[25]=q_oi; x[26]=q_cr|q_ci; x[31:27]=5'd0;\n"
    "    r[12:0]=q_sr; r[25:13]=q_si; r[26]=q_cr|q_ci; r[28:27]=2'd0;\n"
    "    r[31:29]=q_ax;\n"
    "    f=q_or|q_oi|q_cr|q_ci;\n"
    "end",
    "One butterfly node per beat through two hard slices at II=1: the sum leg "
    "and the twiddled difference leg leave together, so a stage of N/2 "
    "butterflies is N/2 beats with no per-sample multiply-accumulate loop and "
    "no rounding feedback path. The same node in software is two multiplies "
    "plus a shift in sequence; here the axis rotation is a wire swap and only "
    "the gain costs silicon.", 2, R2_DECL)

# -----------------------------------------------------------------------------
# 2. r4_bfly_s12: streaming radix-4 node.  One input pair -> one output leg per
#    beat, so a radix-4 butterfly is four beats and needs no wider port.  The
#    untwiddled pair costs no multiplier at all.
# -----------------------------------------------------------------------------
R4_DECL = (sreg('q_ur', 'q_ui', 'q_vr', 'q_vi', 'q_wr', 'q_wi', 'q_dr', 'q_di')
           + sreg_n(13, 'q_pr', 'q_pi')
           + sreg_n(14, 'q_a0r', 'q_a0i', 'q_a2r', 'q_a2i', 'q_l1r', 'q_l1i')
           + "reg q_md, q_sgn, q_cr, q_ci, q_fr, q_fi;\n"
           + slice_decl('q_p0', 'q_dr', 'q_wr')
           + slice_decl('q_p1', 'q_di', 'q_wi')
           + slice_decl('q_p2', 'q_di', 'q_wr')
           + slice_decl('q_p3', 'q_dr', 'q_wi'))

core('r4_bfly_s12',
    "Streaming radix-4 butterfly node: one input pair and one output leg per "
    "beat at II=1, so a radix-4 butterfly is four beats and needs no wider "
    "port. a[11:0]=u.re, a[23:12]=u.im, b[11:0]=v.re, b[23:12]=v.im (signed "
    "12), a[31:24]=b[31:24]=0. c[11:0]=w.re and c[23:12]=w.im signed Q1.10 "
    "(unity=1024), c[24]=mode (0=untwiddled pair, 1=twiddled pair), c[25]=sign "
    "code, c[31:26]=0; anything else is a malformed beat (result=aux=0, "
    "fault=1). mode 0 emits the two even legs: result[13:0]=(u+v).re, "
    "result[27:14]=(u+v).im, aux[13:0]=(u-v).re, aux[27:14]=(u-v).im, all "
    "signed 14 and exact, no slice fires. mode 1 forms "
    "d=(u.re+(-1)^s*v.im, u.im-(-1)^s*v.re), clips d to signed 12 raising "
    "aux[28]/aux[29], then multiplies by w with four MULT12X12 slices and "
    "requantises round_half_up(d*w)>>10 into result[13:0]/result[27:14] "
    "(always signed 12-representable) with result[28]/result[29] saturation "
    "flags; aux carries the pre-clip d pair so a following stage can reuse it. "
    "result[30]=aux[30]=mode, result[31]=sign code, aux[31]=0. fault=1 on a "
    "malformed beat or any clip/saturation.",
    "q_ur=a[11:0]; q_ui=a[23:12]; q_vr=b[11:0]; q_vi=b[23:12];\n"
    "q_wr=c[11:0]; q_wi=c[23:12]; q_md=c[24]; q_sgn=c[25];\n"
    "q_cr=1'b0; q_ci=1'b0; q_fr=1'b0; q_fi=1'b0;\n"
    "if(a[31:24]!=0 || b[31:24]!=0 || c[31:26]!=0) f=1'b1;\n"
    "else begin\n"
    "    if(!q_md) begin\n"
    "        q_a0r=q_ur+q_vr; q_a0i=q_ui+q_vi;\n"
    "        q_a2r=q_ur-q_vr; q_a2i=q_ui-q_vi;\n"
    "        r[13:0]=q_a0r; r[27:14]=q_a0i; r[28]=1'b0; r[29]=1'b0;\n"
    "        r[30]=q_md; r[31]=q_sgn;\n"
    "        x[13:0]=q_a2r; x[27:14]=q_a2i; x[28]=1'b0; x[29]=1'b0;\n"
    "        x[30]=q_md; x[31]=1'b0;\n"
    "    end else begin\n"
    "        if(q_sgn) begin q_pr=q_ur-q_vi; q_pi=q_ui+q_vr; end\n"
    "        else begin q_pr=q_ur+q_vi; q_pi=q_ui-q_vr; end\n"
    "        if(q_pr>13'sd2047) begin q_dr=12'h7ff; q_cr=1'b1; end\n"
    "        else if(q_pr<-13'sd2048) begin q_dr=12'h800; q_cr=1'b1; end\n"
    "        else q_dr=q_pr[11:0];\n"
    "        if(q_pi>13'sd2047) begin q_di=12'h7ff; q_ci=1'b1; end\n"
    "        else if(q_pi<-13'sd2048) begin q_di=12'h800; q_ci=1'b1; end\n"
    "        else q_di=q_pi[11:0];\n"
    "        swide=q_p0-q_p1; swide=swide+64'sd512; swide=swide>>>10;\n"
    "        if(swide>64'sd2047) begin q_fr=1'b1; swide=64'sd2047; end\n"
    "        else if(swide<-64'sd2048) begin q_fr=1'b1; swide=-64'sd2048; end\n"
    "        q_l1r=swide[13:0];\n"
    "        swide2=q_p2+q_p3; swide2=swide2+64'sd512; swide2=swide2>>>10;\n"
    "        if(swide2>64'sd2047) begin q_fi=1'b1; swide2=64'sd2047; end\n"
    "        else if(swide2<-64'sd2048) begin q_fi=1'b1; swide2=-64'sd2048; end\n"
    "        q_l1i=swide2[13:0];\n"
    "        r[13:0]=q_l1r; r[27:14]=q_l1i; r[28]=q_fr; r[29]=q_fi;\n"
    "        r[30]=q_md; r[31]=q_sgn;\n"
    "        x[13:0]=q_pr; x[27:14]=q_pi; x[28]=q_cr; x[29]=q_ci;\n"
    "        x[30]=q_md; x[31]=1'b0;\n"
    "        f=q_fr|q_fi|q_cr|q_ci;\n"
    "    end\n"
    "end",
    "A radix-4 stage is twice the butterfly density of a radix-2 stage for the "
    "same number of beats: the untwiddled leg pair is pure add/sub (zero "
    "multiplier, zero DSP) and only the odd leg pair consumes slices, so the "
    "DSP-per-point of the stage drops below one while LUT-per-point stays flat. "
    "Software pays a full complex multiply for every leg; here half of the "
    "radix-4 outputs are wire swaps and adds.", 2, R4_DECL)

# -----------------------------------------------------------------------------
# 3. twiddle_index16: schedule index -> first-quadrant ROM address + signs.
# -----------------------------------------------------------------------------
core('twiddle_index16',
    "Twiddle index generator: turns (L, s, j) of an FFT schedule into a "
    "first-quadrant (cos,sin) ROM address plus the swap/negate signs that "
    "reconstruct W^e in any quadrant, with XOR, shift and add only - no "
    "multiplier and no modulo divide. a[3:0]=L (log2 N, 2..12), a[7:4]=s, "
    "a[19:8]=j, a[31:20]=0; b[0]=1 requests the conjugate exponent for an "
    "inverse transform, b[31:1]=0; c[0]=mode (0=Stockham radix-2 row: "
    "e=(j mod 2^(L-s-1))*2^s with s<L and j<N/2; 1=radix-4 in-place DIF pass: "
    "e=(j mod 2^(L-2s-2))*2^(2s) with L even, s<L/2 and j<N/4), c[31:1]=0. "
    "Anything else, including out-of-range L, s or j, is a malformed beat "
    "(result=aux=0, fault=1). result[11:0]=ROM address (e mod 2^(L-2)), "
    "result[13:12]=quadrant q, result[14]=swap re/im, result[15]=negate re, "
    "result[16]=negate im, result[17]=inverse echo, result[18]=mode echo, "
    "result[31:19]=0. aux[11:0]=exponent e, aux[15:12]=s, aux[19:16]=L, "
    "aux[23:20]=log2 of the ROM depth (L-2), aux[31:24]=0.",
    "if(a[31:20]!=0 || b[31:1]!=0 || c[31:1]!=0 || a[3:0]<4'd2 || a[3:0]>4'd12)\n"
    "    f=1'b1;\n"
    "else begin\n"
    "    sh={28'd0, a[3:0]}; idx={28'd0, a[7:4]}; pa=a[19:8];\n"
    "    pl=32'd1<<sh;\n"
    "    pb=32'd0;\n"
    "    if(c[0]==1'b0) begin\n"
    "        if(idx>=sh || pa>=(pl>>1)) f=1'b1;\n"
    "        else begin\n"
    "            mask=(32'd1<<(sh-idx-1))-32'd1;\n"
    "            pb=(pa & mask)<<idx;\n"
    "        end\n"
    "    end else begin\n"
    "        if((sh&32'd1)!=32'd0 || {1'b0,idx}>=(sh>>1) || pa>=(pl>>2)) f=1'b1;\n"
    "        else begin\n"
    "            mask=(32'd1<<(sh-idx-idx-2))-32'd1;\n"
    "            pb=(pa & mask)<<(idx+idx);\n"
    "        end\n"
    "    end\n"
    "    if(!f) begin\n"
    "        if(b[0]) pb=(pl-pb)&(pl-32'd1);\n"
    "        pc=pb>>(sh-2);\n"
    "        ph=pb&((32'd1<<(sh-2))-32'd1);\n"
    "        temp=sh-2;\n"
    "        r={13'd0, c[0], b[0], pc[1], (pc[0]^pc[1]), pc[0], pc[1:0],\n"
    "           ph[11:0]};\n"
    "        x={temp[3:0], a[3:0], a[7:4], pb[11:0]};\n"
    "    end\n"
    "end",
    "One beat turns any stage/row of a 4096-point schedule into a ROM address "
    "and three sign bits, so a quarter-turn table of 2^(L-2) entries serves the "
    "whole transform instead of a full-period table four times the size. The "
    "work is two masks, two shifts and one XOR: no multiply, no divide and no "
    "compare loop, which is what lets it sit at II=1 beside the slices.", 1)

# -----------------------------------------------------------------------------
# 4. cordic_rotate: twelve unrolled micro-rotations, pure signed shift/add.
# -----------------------------------------------------------------------------
CORDIC_CASE = ''.join("            4'd%d: q_atan = 16'sd%d;\n" % (i, CORDIC_TAB[i])
                      for i in range(12))
CORDIC_DECL = (sreg('q_x0', 'q_y0')
               + sreg_n(14, 'q_th')
               + sreg_n(17, 'q_x', 'q_y', 'q_tx', 'q_ty')
               + sreg_n(16, 'q_z')
               + sreg_n(14, 'q_ox', 'q_oy')
               + ureg_n(4, 'q_it', 'q_k')
               + "reg [1:0] q_pre;\n"
               + "reg q_sr, q_si;\n"
               + "function signed [15:0] q_atan;\n"
               + "    input [3:0] k;\n"
               + "    begin\n"
               + "        case (k)\n"
               + CORDIC_CASE
               + "            default: q_atan = 16'sd0;\n"
               + "        endcase\n"
               + "    end\n"
               + "endfunction\n")

core('cordic_rotate',
    "Rotation-mode CORDIC: rotate the signed 12-bit vector (x,y) by an angle "
    "without a single multiplier or table lookup beyond twelve constants. "
    "a[11:0]=x, a[23:12]=y signed 12, a[31:24]=0; b[13:0]=theta signed in "
    "units of pi/8192 (|theta|<=8191, i.e. up to about +-180 deg), b[31:14]=0; "
    "c[3:0]=iteration count 1..12, c[31:4]=0. Any other pattern, or a count of "
    "0 or >12, is a malformed beat (result=aux=0, fault=1). One quarter-turn "
    "pre-rotation runs first when |theta|>4096 so the residual always lies "
    "inside the 4544-count convergence range of the atan(2^-i) table. The "
    "CORDIC gain is NOT compensated: the outputs are the input rotated and "
    "scaled by A(i)=prod sqrt(1+4^-k), exact up to truncation of the >>k "
    "shifts. result[13:0]=x' and result[27:14]=y' signed 14 (A*|(x,y)| never "
    "reaches 2^13, so the clamp and its flags result[28]/result[29] are "
    "belt-and-braces), result[31:30]=pre-rotation code 0=none 1=+90 2=-90. "
    "aux[15:0]=residual angle error in the same units (signed 16), "
    "aux[19:16]=iterations, aux[23:20]=pre-rotation code, aux[31:24]=0. "
    "fault=1 on a malformed beat or a clamped lane.",
    "q_x0=a[11:0]; q_y0=a[23:12]; q_th=b[13:0]; q_it=c[3:0];\n"
    "q_sr=1'b0; q_si=1'b0;\n"
    "if(a[31:24]!=0 || b[31:14]!=0 || c[31:4]!=0 || q_it==4'd0 || q_it>4'd12)\n"
    "    f=1'b1;\n"
    "else begin\n"
    "    q_x=q_x0; q_y=q_y0; q_z=q_th; q_pre=2'd0;\n"
    "    if(q_z>16'sd4096) begin\n"
    "        q_tx=q_x; q_x=-q_y; q_y=q_tx; q_z=q_z-16'sd4096; q_pre=2'd1;\n"
    "    end else if(q_z<-16'sd4096) begin\n"
    "        q_tx=q_x; q_x=q_y; q_y=-q_tx; q_z=q_z+16'sd4096; q_pre=2'd2;\n"
    "    end\n"
    "    for(q_k=4'd0; q_k<4'd12; q_k=q_k+4'd1) begin\n"
    "        q_tx=q_x>>>q_k; q_ty=q_y>>>q_k;\n"
    "        q_x=(q_k<q_it) ? ((q_z<16'sd0) ? q_x+q_ty : q_x-q_ty) : q_x;\n"
    "        q_y=(q_k<q_it) ? ((q_z<16'sd0) ? q_y-q_tx : q_y+q_tx) : q_y;\n"
    "        q_z=(q_k<q_it) ? ((q_z<16'sd0) ? q_z+q_atan(q_k) : q_z-q_atan(q_k)) : q_z;\n"
    "    end\n"
    "    if(q_x>17'sd8191) begin q_ox=14'h1fff; q_sr=1'b1; end\n"
    "    else if(q_x<-17'sd8192) begin q_ox=14'h2000; q_sr=1'b1; end\n"
    "    else q_ox=q_x[13:0];\n"
    "    if(q_y>17'sd8191) begin q_oy=14'h1fff; q_si=1'b1; end\n"
    "    else if(q_y<-17'sd8192) begin q_oy=14'h2000; q_si=1'b1; end\n"
    "    else q_oy=q_y[13:0];\n"
    "    r[13:0]=q_ox; r[27:14]=q_oy; r[28]=q_sr; r[29]=q_si; r[31:30]=q_pre;\n"
    "    x[15:0]=q_z[15:0]; x[19:16]=q_it; x[23:20]={2'd0, q_pre};\n"
    "    x[31:24]=8'd0;\n"
    "    f=q_sr|q_si;\n"
    "end",
    "Twelve sign-select shift-add micro-rotations unroll into one combinational "
    "beat at II=1 and occupy zero DSP cells, so a rotation costs no multiplier "
    "slot next to the butterfly slices. Software pays a data-dependent branch "
    "per iteration for the sign decision, which serialises and mispredicts; the "
    "signed shift/add cone here does neither.", 2, CORDIC_DECL)

# -----------------------------------------------------------------------------
# 5. complex_add_sat: two-lane complex add and subtract, shifted operand.
# -----------------------------------------------------------------------------
CADD_DECL = (sreg('q_xr', 'q_xi', 'q_yr', 'q_yi', 'q_or', 'q_oi', 'q_pr', 'q_pi')
             + sreg_n(14, 'q_yr14', 'q_yi14', 'q_zr', 'q_zi',
                      'q_sr', 'q_si', 'q_dr', 'q_di')
             + ureg_n(4, 'q_k')
             + "reg q_ar, q_ai, q_br, q_bi;\n")

core('complex_add_sat',
    "Complex add/sub with sample-width saturation: the sum and the difference "
    "of two signed 12-bit complex values, with the second operand "
    "arithmetic-shifted (floor, no rounding) by a per-beat amount. a[11:0]=x.re, "
    "a[23:12]=x.im, b[11:0]=y.re, b[23:12]=y.im signed 12, a[31:24]=b[31:24]=0; "
    "c[3:0]=shift k (0..15), c[31:4]=0. Any nonzero reserved bit is a "
    "malformed beat (result=aux=0, fault=1). With y'=y>>>k elementwise, "
    "result[11:0]=clamp12(x.re+y'.re), result[23:12]=clamp12(x.im+y'.im), "
    "result[24]=re clamped, result[25]=im clamped, result[27:26]=0, "
    "result[31:28]=k. aux mirrors the difference x-y' in the same layout "
    "(aux[24]/aux[25] clamping flags, aux[31:28]=k). fault=1 on a malformed "
    "beat or any clamped lane; a clamped lane never wraps. No multiplier is "
    "instantiated: the whole cone is shift, add and compare.",
    "q_xr=a[11:0]; q_xi=a[23:12]; q_yr=b[11:0]; q_yi=b[23:12]; q_k=c[3:0];\n"
    "q_ar=1'b0; q_ai=1'b0; q_br=1'b0; q_bi=1'b0;\n"
    "if(a[31:24]!=0 || b[31:24]!=0 || c[31:4]!=0) f=1'b1;\n"
    "else begin\n"
    "    q_yr14=q_yr; q_yi14=q_yi;\n"
    "    q_zr=q_yr14>>>q_k; q_zi=q_yi14>>>q_k;\n"
    "    q_sr=q_xr+q_zr; q_si=q_xi+q_zi;\n"
    "    q_dr=q_xr-q_zr; q_di=q_xi-q_zi;\n"
    "    if(q_sr>14'sd2047) begin q_or=12'h7ff; q_ar=1'b1; end\n"
    "    else if(q_sr<-14'sd2048) begin q_or=12'h800; q_ar=1'b1; end\n"
    "    else q_or=q_sr[11:0];\n"
    "    if(q_si>14'sd2047) begin q_oi=12'h7ff; q_ai=1'b1; end\n"
    "    else if(q_si<-14'sd2048) begin q_oi=12'h800; q_ai=1'b1; end\n"
    "    else q_oi=q_si[11:0];\n"
    "    if(q_dr>14'sd2047) begin q_pr=12'h7ff; q_br=1'b1; end\n"
    "    else if(q_dr<-14'sd2048) begin q_pr=12'h800; q_br=1'b1; end\n"
    "    else q_pr=q_dr[11:0];\n"
    "    if(q_di>14'sd2047) begin q_pi=12'h7ff; q_bi=1'b1; end\n"
    "    else if(q_di<-14'sd2048) begin q_pi=12'h800; q_bi=1'b1; end\n"
    "    else q_pi=q_di[11:0];\n"
    "    r[11:0]=q_or; r[23:12]=q_oi; r[24]=q_ar; r[25]=q_ai;\n"
    "    r[27:26]=2'd0; r[31:28]=q_k;\n"
    "    x[11:0]=q_pr; x[23:12]=q_pi; x[24]=q_br; x[25]=q_bi;\n"
    "    x[27:26]=2'd0; x[31:28]=q_k;\n"
    "    f=q_ar|q_ai|q_br|q_bi;\n"
    "end",
    "A spectral adder/compressor tree needs both the sum and the difference of "
    "the same complex pair every beat: four 12-bit saturating lanes and one "
    "programmable shift retire in a single beat at II=1 with no divide, no "
    "rounding feedback loop and no per-lane branch, which a scalar core pays "
    "four times per sample pair.", 4, CADD_DECL)

# -----------------------------------------------------------------------------
# 6. cmul_q15: Gauss three-product complex multiply, three slices.
# -----------------------------------------------------------------------------
CMUL_DECL = (sreg('q_zr', 'q_zi', 'q_wr', 'q_wi', 'q_su', 'q_sw')
             + sreg_n(13, 'q_u13', 'q_w13')
             + "reg q_cj, q_uclip, q_wclip, q_rsat, q_isat;\n"
             + slice_decl('q_p1', 'q_zr', 'q_wr')
             + slice_decl('q_p2', 'q_zi', 'q_wi')
             + slice_decl('q_p3', 'q_su', 'q_sw'))

core('cmul_q15',
    "Exact complex multiply by Gauss' three-product identity, so three "
    "MULT12X12 slices do the work of four: re=P1-P2, im=P3-P1-P2 with "
    "P1=zr*wr, P2=zi*wi, P3=(zr+zi)*(wr+wi). a[11:0]=z.re, a[23:12]=z.im, "
    "b[11:0]=w.re, b[23:12]=w.im, all signed 12 on the family Q1.10 scale "
    "(unity=1024), a[31:24]=b[31:24]=0; c[0]=1 conjugates the second operand "
    "(the inverse-FFT / matched-filter direction) by negating the requantised "
    "imaginary leg after rounding, c[31:1]=0. Any other pattern is a malformed "
    "beat (result=aux=0, fault=1). Both legs are requantised with "
    "round_half_up(...)>>10 and clamped to signed 12: result[11:0]=re, "
    "result[23:12]=im, result[24]=re clamped, result[25]=im clamped, "
    "result[26]=the zr+zi pre-add saturated, result[27]=the wr+wi pre-add "
    "saturated, result[31:28]=0. aux[11:0]=the signed 12 pre-add u=zr+zi "
    "actually fed to slice P3, aux[23:12]=the pre-add w=wr+wi actually fed to "
    "P3, aux[24]=conjugate echo, aux[31:25]=0. fault=1 on a malformed beat, "
    "either pre-add saturation or either output clamp; the identity is exact "
    "only while both pre-adds fit one slice operand, which is what the flags "
    "report.",
    "q_zr=a[11:0]; q_zi=a[23:12]; q_wr=b[11:0]; q_wi=b[23:12]; q_cj=c[0];\n"
    "q_uclip=1'b0; q_wclip=1'b0; q_rsat=1'b0; q_isat=1'b0;\n"
    "if(a[31:24]!=0 || b[31:24]!=0 || c[31:1]!=0) f=1'b1;\n"
    "else begin\n"
    "    q_u13=q_zr+q_zi;\n"
    "    if(q_u13>13'sd2047) begin q_su=12'h7ff; q_uclip=1'b1; end\n"
    "    else if(q_u13<-13'sd2048) begin q_su=12'h800; q_uclip=1'b1; end\n"
    "    else q_su=q_u13[11:0];\n"
    "    q_w13=q_wr+q_wi;\n"
    "    if(q_w13>13'sd2047) begin q_sw=12'h7ff; q_wclip=1'b1; end\n"
    "    else if(q_w13<-13'sd2048) begin q_sw=12'h800; q_wclip=1'b1; end\n"
    "    else q_sw=q_w13[11:0];\n"
    "    swide=q_p1-q_p2; swide=swide+64'sd512; swide=swide>>>10;\n"
    "    if(swide>64'sd2047) begin q_rsat=1'b1; swide=64'sd2047; end\n"
    "    else if(swide<-64'sd2048) begin q_rsat=1'b1; swide=-64'sd2048; end\n"
    "    r[11:0]=swide[11:0];\n"
    "    swide2=q_p3-q_p1; swide2=swide2-q_p2; swide2=swide2+64'sd512;\n"
    "    swide2=swide2>>>10;\n"
    "    if(q_cj) swide2=-swide2;\n"
    "    if(swide2>64'sd2047) begin q_isat=1'b1; swide2=64'sd2047; end\n"
    "    else if(swide2<-64'sd2048) begin q_isat=1'b1; swide2=-64'sd2048; end\n"
    "    r[23:12]=swide2[11:0];\n"
    "    r[24]=q_rsat; r[25]=q_isat; r[26]=q_uclip; r[27]=q_wclip;\n"
    "    r[31:28]=4'd0;\n"
    "    x[11:0]=q_su; x[23:12]=q_sw; x[24]=q_cj; x[31:25]=7'd0;\n"
    "    f=q_rsat|q_isat|q_uclip|q_wclip;\n"
    "end",
    "Three slices per complex product instead of four is a 25% cut in the "
    "scarcest resource of a spectral engine, and the conjugate direction is a "
    "sign on the requantised imaginary leg rather than a second pass or a "
    "reload of the twiddle. A software equivalent pays four multiplies plus a "
    "fix-up branch per sample; this pays three slices in one beat.", 2,
    CMUL_DECL)

# -----------------------------------------------------------------------------
# 7. mag_approx_s12: shift-add magnitude with analytic error bounds.
# -----------------------------------------------------------------------------
MAG_DECL = (sreg('q_re', 'q_im')
            + ureg_n(12, 'q_ar', 'q_ai', 'q_hi', 'q_lo')
            + ureg_n(13, 'q_t0', 'q_t1', 'q_t2', 'q_t3', 'q_m', 'q_up')
            + ureg_n(4, 'q_tier')
            + "reg q_swap, q_sre, q_sim, q_zero, q_equal, q_over;\n")

core('mag_approx_s12',
    "Multiplier-free magnitude approximation of a signed 12-bit complex value "
    "with analytic error bounds, for power/log metrics and tone detectors. "
    "a[11:0]=re, a[23:12]=im signed 12, a[31:24]=0; b must be 0 (nonzero b is "
    "a malformed beat); c[3:0]=approximation tier 0..3, c[31:4]=0. With "
    "hi=max(|re|,|im|) and lo=min(|re|,|im|) the tiers are "
    "0: hi+(lo>>1) (a proven upper bound on |z|, over-estimates by at most "
    "sqrt(5/4)), 1: hi+(lo>>1)-(lo>>3) (the classic half-minus-eighth rule, "
    "worst error about -2.8% at 45 deg and +6.8% at lo/hi=0.375), 2: hi+(lo>>2), "
    "3: hi+(lo>>2)+(lo>>4). All shifts act on non-negative magnitudes so no "
    "rounding ambiguity exists. result[11:0]=the tier estimate (never exceeds "
    "3070, so it is unsigned 12-representable), result[12]=|im|>|re|, "
    "result[13]=re negative, result[14]=im negative, result[15]=zero input, "
    "result[16]=|re|==|im| (exact 45 deg), result[18:17]=tier, result[31:19]=0. "
    "aux[11:0]=hi (a proven lower bound on |z|), aux[23:12]=hi+(lo>>1) (a "
    "proven upper bound), aux[24]=bounds valid, aux[26:25]=tier, aux[31:27]=0. "
    "fault=1 on a malformed beat or an estimate leaving the unsigned 12 window.",
    "q_re=a[11:0]; q_im=a[23:12]; q_tier=c[3:0];\n"
    "q_swap=1'b0; q_sre=1'b0; q_sim=1'b0; q_zero=1'b0; q_equal=1'b0; q_over=1'b0;\n"
    "if(a[31:24]!=0 || b!=32'd0 || c[31:4]!=0 || q_tier>4'd3) f=1'b1;\n"
    "else begin\n"
    "    q_sre=q_re[11]; q_sim=q_im[11];\n"
    "    q_ar=q_re[11] ? (~q_re + 12'd1) : q_re;\n"
    "    q_ai=q_im[11] ? (~q_im + 12'd1) : q_im;\n"
    "    if(q_ar>=q_ai) begin q_hi=q_ar; q_lo=q_ai; q_swap=1'b0; end\n"
    "    else begin q_hi=q_ai; q_lo=q_ar; q_swap=1'b1; end\n"
    "    q_zero=(q_ar==12'd0 && q_ai==12'd0);\n"
    "    q_equal=(q_ar==q_ai);\n"
    "    q_t0=q_hi+(q_lo>>1);\n"
    "    q_t1=q_hi+(q_lo>>1)-(q_lo>>3);\n"
    "    q_t2=q_hi+(q_lo>>2);\n"
    "    q_t3=q_hi+(q_lo>>2)+(q_lo>>4);\n"
    "    case(q_tier)\n"
    "        4'd0: q_m=q_t0;\n"
    "        4'd1: q_m=q_t1;\n"
    "        4'd2: q_m=q_t2;\n"
    "        default: q_m=q_t3;\n"
    "    endcase\n"
    "    q_up=q_hi+(q_lo>>1);\n"
    "    q_over=(q_m>13'd4095);\n"
    "    r[11:0]=q_m[11:0]; r[12]=q_swap; r[13]=q_sre; r[14]=q_sim;\n"
    "    r[15]=q_zero; r[16]=q_equal; r[18:17]=q_tier[1:0]; r[31:19]=13'd0;\n"
    "    x[11:0]=q_hi; x[23:12]=q_up[11:0]; x[24]=!q_over;\n"
    "    x[26:25]=q_tier[1:0]; x[31:27]=5'd0;\n"
    "    f=q_over;\n"
    "end",
    "Spectral energy, AGC and tone detectors need |z| or log|z|, never the "
    "exact root: this returns four tiers of shift-add bound in one beat with "
    "zero DSP and zero iterations, while a software isqrt or CORDIC magnitude "
    "costs a 12-step loop or a square root per sample. Both error bounds ride "
    "out with the estimate, so a downstream log table needs no guard band.",
    2, MAG_DECL)

# -----------------------------------------------------------------------------
# 8. stockham_addr: buffer-swapping stage address math, no multiplier.
# -----------------------------------------------------------------------------
STOCK_DECL = (ureg_n(32, 'q_base', 'q_stride', 'q_rank', 'q_leg2', 'q_leg3',
                     'q_e', 'q_bank', 'q_bmask')
              + "reg [1:0] q_md;\n"
              + "reg q_clash;\n")

core('stockham_addr',
    "Stockham stage address generator: maps (L, s, j) of one butterfly group "
    "to the read/write indices of the next buffer, with bank-clash detection "
    "and the matching twiddle exponent, using mask/shift/add only - no "
    "multiplier, no divide, no bit-reversal pass. a[3:0]=L (log2 N, 2..12), "
    "a[7:4]=s, a[19:8]=j, a[31:20]=0; b[1:0]=mode (0=radix-2 pair with stride "
    "2^s, s<L and j<N/2; 1=radix-4 leg set with legs base+k*2^s, s<L-1 and "
    "j<N/4; 2 and 3 are reserved and malformed), b[31:2]=0; c[3:0]=bank width "
    "exponent bw (operands live in 2^bw single-port banks, 0..15), c[31:4]=0. "
    "base=((j>>s)<<(s+1|s+2)) | (j & (2^s-1)), so the pairs and leg sets "
    "provably partition 0..N-1. Any other bit pattern or an out-of-range "
    "(L,s,j) is a malformed beat (result=aux=0, fault=1). mode 0: "
    "result[11:0]=src, result[23:12]=dst=src+2^s. mode 1: result[11:0] and "
    "result[23:12]=legs 0 and 1, aux[11:0] and aux[23:12]=legs 2 and 3. Shared "
    "layout: result[24]=bank clash (two operands land in the same bank, i.e. "
    "stride mod 2^bw == 0), result[25]=1 (valid beat), result[27:26]=mode, "
    "result[31:28]=s. aux[11:0]=twiddle exponent e=(j & (2^s-1))<<(L-s-1) in "
    "mode 0 and leg 2 in mode 1, aux[23:12]=2^s in mode 0 and leg 3 in mode 1, "
    "aux[27:24]=the low storage bits of the first position, aux[31:28]=bw. "
    "fault=1 on a malformed beat only.",
    "if(a[31:20]!=0 || b[31:2]!=0 || c[31:4]!=0 || a[3:0]<4'd2 || a[3:0]>4'd12)\n"
    "    f=1'b1;\n"
    "else begin\n"
    "    sh={28'd0, a[3:0]}; idx={28'd0, a[7:4]}; pa=a[19:8];\n"
    "    pl=32'd1<<sh; q_md=b[1:0]; q_bmask=(32'd1<<c[3:0])-32'd1;\n"
    "    pb=32'd0; pc=32'd0; ph=32'd0; q_base=32'd0; q_stride=32'd0;\n"
    "    q_rank=32'd0; q_leg2=32'd0; q_leg3=32'd0; q_e=32'd0; q_clash=1'b0;\n"
    "    if(q_md==2'd2 || q_md==2'd3) f=1'b1;\n"
    "    else begin\n"
    "        q_rank=(32'd1<<idx)-32'd1;\n"
    "        q_stride=32'd1<<idx;\n"
    "        if(q_md==2'd0) begin\n"
    "            if(idx>=sh || pa>=(pl>>1)) f=1'b1;\n"
    "            else begin\n"
    "                q_base=((pa>>idx)<<(idx+32'd1))|(pa&q_rank);\n"
    "                pb=q_base; pc=q_base|q_stride;\n"
    "                q_e=(pa&q_rank)<<(sh-idx-32'd1);\n"
    "                q_clash=((q_stride&q_bmask)==32'd0);\n"
    "                r[11:0]=pb[11:0]; r[23:12]=pc[11:0]; r[24]=q_clash;\n"
    "                r[25]=1'b1; r[27:26]=q_md; r[31:28]=a[7:4];\n"
    "                x[11:0]=q_e[11:0]; x[23:12]=q_stride[11:0];\n"
    "                q_bank=pb&q_bmask;\n"
    "                x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];\n"
    "            end\n"
    "        end else begin\n"
    "            if(idx>=(sh-32'd1) || pa>=(pl>>2)) f=1'b1;\n"
    "            else begin\n"
    "                q_base=((pa>>idx)<<(idx+32'd2))|(pa&q_rank);\n"
    "                pb=q_base; pc=q_base+q_stride;\n"
    "                q_leg2=q_base+(q_stride<<32'd1);\n"
    "                q_leg3=q_base+((q_stride<<32'd1)+q_stride);\n"
    "                q_clash=((q_stride&q_bmask)==32'd0);\n"
    "                r[11:0]=pb[11:0]; r[23:12]=pc[11:0]; r[24]=q_clash;\n"
    "                r[25]=1'b1; r[27:26]=q_md; r[31:28]=a[7:4];\n"
    "                x[11:0]=q_leg2[11:0]; x[23:12]=q_leg3[11:0];\n"
    "                q_bank=pb&q_bmask;\n"
    "                x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];\n"
    "            end\n"
    "        end\n"
    "    end\n"
    "end",
    "A radix-4 stage needs four addresses per beat and the bank-granularity "
    "answer decides whether the coefficient memory can serve them; here the "
    "four indices, the stride and the clash flag come out of two masks and "
    "three shifts in one beat, so the scheduler never recomputes addresses in "
    "a software loop between stages, and one cone covers both radix 2 and "
    "radix 4.", 2, STOCK_DECL)

# -----------------------------------------------------------------------------
# 9. dit_stage_map: DIT butterflies at storage positions via a bit-reverse cell.
# -----------------------------------------------------------------------------
DIT_DECL = (
    "function [11:0] q_brev;\n"
    "    input [11:0] v; input [3:0] bl; integer qk; reg [11:0] qacc;\n"
    "    begin\n"
    "        qacc = 12'd0;\n"
    "        for(qk=0; qk<12; qk=qk+1) qacc = (qk<bl) ? ((qacc<<1) | v[qk]) : qacc;\n"
    "        q_brev = qacc;\n"
    "    end\n"
    "endfunction\n"
    + ureg_n(32, 'q_pos0', 'q_pos1', 'q_stride', 'q_rank', 'q_bank')
    + "reg [1:0] q_md;\n"
    + "reg q_flag;\n")

core('dit_stage_map',
    "Decimation-in-time stage index map: gives the storage positions (the "
    "bit-reversed ones a single-buffer DIT engine really touches) for a radix-2 "
    "butterfly, a radix-4 leg set or a Forney conjugate pair, plus the twiddle "
    "exponent that feeds twiddle_index16 unchanged. a[3:0]=L (log2 N, 2..12), "
    "a[7:4]=s, a[19:8]=j, a[31:20]=0; b[1:0]=mode (0=radix-2 DIT pair, s<L and "
    "j<N/2; 1=Forney conjugate pair, j<N; 2=radix-4 DIT leg set, s<L-1 and "
    "j<N/4; 3=reserved, malformed), b[31:2]=0; c[3:0]=bank width exponent bw, "
    "c[31:4]=0. Every position passes through one 12-bit reversal over L bits, "
    "which is a bijection, so each mode's index sets provably partition "
    "0..N-1. Any other pattern is a malformed beat (result=aux=0, fault=1). "
    "mode 0: result[11:0]=rev(base), result[23:12]=rev(base+2^s), "
    "aux[11:0]=e=(j & (2^s-1))<<(L-s-1), aux[23:12]=base, aux[27:24]=the low "
    "four bits of rev(j). mode 1: result[11:0]=rev(j), "
    "result[23:12]=rev((N-j) mod N), result[24]=self-paired (j=0 or N/2, the "
    "axis twiddles), aux[11:0]=(N-j) mod N, aux[23:12]=j. mode 2: "
    "result[11:0]/result[23:12]=rev of legs 0/1, aux[11:0]/aux[23:12]=rev of "
    "legs 2/3. Shared layout: result[24]=clash or self-pair flag, result[25]=1, "
    "result[27:26]=mode, result[31:28]=s, aux[27:24]=bank of the first "
    "position, aux[31:28]=bw. fault=1 on a malformed beat only.",
    "if(a[31:20]!=0 || b[31:2]!=0 || c[31:4]!=0 || a[3:0]<4'd2 || a[3:0]>4'd12)\n"
    "    f=1'b1;\n"
    "else begin\n"
    "    sh={28'd0, a[3:0]}; idx={28'd0, a[7:4]}; pa=a[19:8];\n"
    "    pl=32'd1<<sh; q_md=b[1:0]; q_rank=(32'd1<<idx)-32'd1;\n"
    "    q_stride=32'd1<<idx; q_pos0=32'd0; q_pos1=32'd0; q_bank=32'd0;\n"
    "    pb=32'd0; pc=32'd0; ph=32'd0; temp=(32'd1<<c[3:0])-32'd1;\n"
    "    mask=32'd0; q_flag=1'b0;\n"
    "    if(q_md==2'd3 || idx>=sh) f=1'b1;\n"
    "    else if(q_md==2'd0) begin\n"
    "        if(pa>=(pl>>1)) f=1'b1;\n"
    "        else begin\n"
    "            q_pos0=((pa>>idx)<<(idx+32'd1))|(pa&q_rank);\n"
    "            q_pos1=q_pos0|q_stride;\n"
    "            mask=(pa&q_rank)<<(sh-idx-32'd1);\n"
    "            r[11:0]=q_brev(q_pos0[11:0], a[3:0]);\n"
    "            r[23:12]=q_brev(q_pos1[11:0], a[3:0]);\n"
    "            r[24]=((q_pos0^q_pos1)&temp)==32'd0; r[25]=1'b1;\n"
    "            r[27:26]=q_md; r[31:28]=a[7:4];\n"
    "            x[11:0]=mask[11:0]; x[23:12]=q_pos0[11:0];\n"
    "            x[27:24]=q_brev(pa[11:0], a[3:0])&4'hf;\n"
    "            x[31:28]=c[3:0];\n"
    "        end\n"
    "    end else if(q_md==2'd1) begin\n"
    "        if(pa>=pl) f=1'b1;\n"
    "        else begin\n"
    "            pb=q_brev(pa[11:0], a[3:0]);\n"
    "            pc=(pl-pa)&(pl-32'd1);\n"
    "            q_pos1=q_brev(pc[11:0], a[3:0]);\n"
    "            r[11:0]=pb; r[23:12]=q_pos1[11:0];\n"
    "            r[24]=(pb==q_pos1); r[25]=1'b1;\n"
    "            r[27:26]=q_md; r[31:28]=a[7:4];\n"
    "            x[11:0]=pc[11:0]; x[23:12]=pa[11:0];\n"
    "            q_bank=pa&temp; x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];\n"
    "        end\n"
    "    end else begin\n"
    "        if(idx>=(sh-32'd1) || pa>=(pl>>2)) f=1'b1;\n"
    "        else begin\n"
    "            q_pos0=((pa>>idx)<<(idx+32'd2))|(pa&q_rank);\n"
    "            pb=q_brev(q_pos0[11:0], a[3:0]);\n"
    "            pc=q_brev(q_pos0+q_stride, a[3:0]);\n"
    "            ph=q_brev(q_pos0+(q_stride<<32'd1), a[3:0]);\n"
    "            mask=q_brev(q_pos0+((q_stride<<32'd1)+q_stride), a[3:0]);\n"
    "            r[11:0]=pb; r[23:12]=pc;\n"
    "            x[11:0]=ph; x[23:12]=mask;\n"
    "            q_flag=((q_stride&temp)==32'd0);\n"
    "            r[24]=q_flag; r[25]=1'b1;\n"
    "            r[27:26]=q_md; r[31:28]=a[7:4];\n"
    "            q_bank=pb&temp; x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];\n"
    "        end\n"
    "    end\n"
    "end",
    "A single-buffer DIT engine cannot be scheduled without translating every "
    "logical butterfly into storage positions; doing it here with one "
    "bit-reversal cell, two masks and three shifts removes the separate "
    "rearrangement pass (a full extra N reads and N writes per transform) that "
    "software FFT libraries pay, and the conjugate-pair mode hands the "
    "scheduler the second-half-skipping indices for free.", 2, DIT_DECL)

# -----------------------------------------------------------------------------
# 10. chirp_mult_s12: Bluestein chirp leg -- quadrant reconstruction (no
#     multiply) plus one exact four-slice complex product.
# -----------------------------------------------------------------------------
CHIRP_DECL = (sreg('q_xr', 'q_xi', 'q_cs', 'q_sn', 'q_wr', 'q_wi')
              + sreg_n(14, 'q_wr14', 'q_wi14')
              + "reg [1:0] q_q;\n"
              + "reg [3:0] q_l;\n"
              + "reg q_cj, q_swap, q_nre, q_nim, q_clip, q_axis;\n"
              + "q_placeholder"
              + slice_decl('q_p0', 'q_xr', 'q_wr')
              + slice_decl('q_p1', 'q_xi', 'q_wi')
              + slice_decl('q_p2', 'q_xi', 'q_wr')
              + slice_decl('q_p3', 'q_xr', 'q_wi'))
CHIRP_DECL = CHIRP_DECL.replace('q_placeholder',
                                "reg q_rsat, q_isat;\n")

core('chirp_mult_s12',
    "Bluestein chirp multiply: reconstructs the full-plane chirp value from a "
    "first-quadrant (cos,sin) magnitude pair and a quadrant code -- one swap "
    "and two sign XORs, no divide -- then multiplies the sample by it and "
    "requantises. a[11:0]=x.re, a[23:12]=x.im signed 12; b[11:0]=cos, "
    "b[23:12]=sin signed Q1.10 magnitudes as stored in a quarter-period table; "
    "c[3:0]=L (log2 N, 2..12, so the quadrant is e>>(L-2)), c[5:4]=quadrant q, "
    "c[6]=conjugate (the second chirp of a Bluestein pair, or the inverse "
    "transform), c[31:7]=0; a[31:24]=b[31:24]=0. Any other pattern, or an L "
    "outside 2..12, is a malformed beat (result=aux=0, fault=1). "
    "Reconstruction follows twiddle_index16 exactly: swap=q[0], negate "
    "re=q[0]^q[1], negate im=q[1]; the conjugate flag negates the imaginary "
    "leg again. If a negation leaves the signed 12 slice window the lane is "
    "clamped and the reconstruction flag rises. The product is four "
    "MULT12X12 slices with round_half_up(...)>>10 requantise clamped to signed "
    "12. result[11:0]=re, result[23:12]=im, result[24]=re clamped, "
    "result[25]=im clamped, result[26]=twiddle reconstruction clamped, "
    "result[27]=conjugate echo, result[29:28]=q, result[30]=the twiddle landed "
    "on an axis (a zero re or im leg, i.e. the product could have been a wire "
    "swap), result[31]=0. aux[11:0]=the signed 12 w.re fed to the slices, "
    "aux[23:12]=the signed 12 w.im fed to the slices, aux[27:24]=L, "
    "aux[31:28]=0. fault=1 on a malformed beat or any clamp.",
    "q_xr=a[11:0]; q_xi=a[23:12]; q_cs=b[11:0]; q_sn=b[23:12];\n"
    "q_l=c[3:0]; q_q=c[5:4]; q_cj=c[6];\n"
    "q_clip=1'b0; q_axis=1'b0; q_rsat=1'b0; q_isat=1'b0;\n"
    "if(a[31:24]!=0 || b[31:24]!=0 || c[31:7]!=0 || q_l<4'd2 || q_l>4'd12)\n"
    "    f=1'b1;\n"
    "else begin\n"
    "    q_swap=q_q[0]; q_nre=q_q[0]^q_q[1]; q_nim=q_q[1];\n"
    "    if(q_swap) begin q_wr14=q_sn; q_wi14=q_cs; end\n"
    "    else begin q_wr14=q_cs; q_wi14=q_sn; end\n"
    "    if(q_nre) q_wr14=-q_wr14;\n"
    "    if(q_nim) q_wi14=-q_wi14;\n"
    "    if(q_cj) q_wi14=-q_wi14;\n"
    "    if(q_wr14>14'sd2047) begin q_wr=12'h7ff; q_clip=1'b1; end\n"
    "    else if(q_wr14<-14'sd2048) begin q_wr=12'h800; q_clip=1'b1; end\n"
    "    else q_wr=q_wr14[11:0];\n"
    "    if(q_wi14>14'sd2047) begin q_wi=12'h7ff; q_clip=1'b1; end\n"
    "    else if(q_wi14<-14'sd2048) begin q_wi=12'h800; q_clip=1'b1; end\n"
    "    else q_wi=q_wi14[11:0];\n"
    "    q_axis=(q_wr==12'sd0) || (q_wi==12'sd0);\n"
    "    swide=q_p0-q_p1; swide=swide+64'sd512; swide=swide>>>10;\n"
    "    if(swide>64'sd2047) begin q_rsat=1'b1; swide=64'sd2047; end\n"
    "    else if(swide<-64'sd2048) begin q_rsat=1'b1; swide=-64'sd2048; end\n"
    "    r[11:0]=swide[11:0];\n"
    "    swide2=q_p2+q_p3; swide2=swide2+64'sd512; swide2=swide2>>>10;\n"
    "    if(swide2>64'sd2047) begin q_isat=1'b1; swide2=64'sd2047; end\n"
    "    else if(swide2<-64'sd2048) begin q_isat=1'b1; swide2=-64'sd2048; end\n"
    "    r[23:12]=swide2[11:0];\n"
    "    r[24]=q_rsat; r[25]=q_isat; r[26]=q_clip; r[27]=q_cj;\n"
    "    r[29:28]=q_q; r[30]=q_axis; r[31]=1'b0;\n"
    "    x[11:0]=q_wr; x[23:12]=q_wi; x[27:24]=q_l; x[31:28]=4'd0;\n"
    "    f=q_rsat|q_isat|q_clip;\n"
    "end",
    "Bluestein needs two chirp passes over the whole sequence and the chirp "
    "value for every index must first be unfolded from a quarter-period table: "
    "this core does the unfolding with one swap and two sign XORs (zero "
    "arithmetic) and spends its four slices only on the product, so a chirp "
    "leg costs no extra ROM, no trig and no second pass, at II=1.", 2,
    CHIRP_DECL)

# -----------------------------------------------------------------------------
# Integer models.  Each one re-executes the kernel's data flow exactly as the
# template body does: field extract -> rotate/clip -> slice product -> requantise
# -> clamp -> field pack.  Nothing here reads RTL or simulator output.
# -----------------------------------------------------------------------------
def s13(value):
    return s_bits(value, 13)


def s17(value):
    return s_bits(value, 17)


def pack(value, lo, hi):
    """Mirrors `lhs[hi:lo] = rhs`: the low (hi-lo+1) two's-complement bits."""
    return (value & ((1 << (hi - lo + 1)) - 1)) << lo


def clip12(value):
    """The `if(v>2047)/else if(v<-2048)/else` clip every slice lane shares."""
    if value > 2047:
        return 2047, 1
    if value < -2048:
        return -2048, 1
    return value, 0


def _m_r2(a, b, c):
    xr, xi = sb(a, 0, 12), sb(a, 12, 12)
    yr, yi = sb(b, 0, 12), sb(b, 12, 12)
    gr, ax = sb(c, 0, 12), ub(c, 12, 3)
    if ub(a, 24, 8) or ub(b, 24, 8) or ub(c, 15, 17):
        return 0, 0, 1
    sr, si = s13(xr + yr), s13(xi + yi)
    dr, di = s13(xr - yr), s13(xi - yi)
    if ax == 1:
        br, bm = di, s13(-dr)
    elif ax == 2:
        br, bm = s13(-dr), s13(-di)
    elif ax == 3:
        br, bm = s13(-di), dr
    elif ax > 3:
        br, bm = s13(-di), dr
    else:
        br, bm = dr, di
    qr, cr = clip12(br)
    qi, ci = clip12(bm)
    re, sat_r = clip12(round_shift(qr * gr, 10))
    im, sat_i = clip12(round_shift(qi * gr, 10))
    clipped = cr | ci
    r = (pack(sr, 0, 12) | pack(si, 13, 25) | pack(clipped, 26, 26)
         | pack(ax, 29, 31))
    x = (pack(re, 0, 11) | pack(im, 12, 23) | pack(sat_r, 24, 24)
         | pack(sat_i, 25, 25) | pack(clipped, 26, 26))
    return r, x, sat_r | sat_i | clipped


def _m_r4(a, b, c):
    ur, ui = sb(a, 0, 12), sb(a, 12, 12)
    vr, vi = sb(b, 0, 12), sb(b, 12, 12)
    wr, wi = sb(c, 0, 12), sb(c, 12, 12)
    md, sg = ub(c, 24, 1), ub(c, 25, 1)
    if ub(a, 24, 8) or ub(b, 24, 8) or ub(c, 26, 6):
        return 0, 0, 1
    if not md:
        r = (pack(ur + vr, 0, 13) | pack(ui + vi, 14, 27) | pack(md, 30, 30)
             | pack(sg, 31, 31))
        x = pack(ur - vr, 0, 13) | pack(ui - vi, 14, 27) | pack(md, 30, 30)
        return r, x, 0
    pr, pi = s13(ur - vi if sg else ur + vi), s13(ui + vr if sg else ui - vr)
    dr, cr = clip12(pr)
    di, ci = clip12(pi)
    re, fr = clip12(round_shift(dr * wr - di * wi, 10))
    im, fi = clip12(round_shift(di * wr + dr * wi, 10))
    r = (pack(re, 0, 13) | pack(im, 14, 27) | pack(fr, 28, 28) | pack(fi, 29, 29)
         | pack(md, 30, 30) | pack(sg, 31, 31))
    x = (pack(pr, 0, 13) | pack(pi, 14, 27) | pack(cr, 28, 28) | pack(ci, 29, 29)
         | pack(md, 30, 30))
    return r, x, fr | fi | cr | ci


def _m_twiddle(a, b, c):
    length, s, j = ub(a, 0, 4), ub(a, 4, 4), ub(a, 8, 12)
    inv, md = ub(b, 0, 1), ub(c, 0, 1)
    if (ub(a, 20, 12) or ub(b, 1, 31) or ub(c, 1, 31)
            or length < 2 or length > 12):
        return 0, 0, 1
    total = 1 << length
    depth = length - 2
    if not md:
        if s >= length or j >= (total >> 1):
            return 0, 0, 1
        exponent = (j & ((1 << (length - s - 1)) - 1)) << s
    else:
        if (length & 1) or s >= (length >> 1) or j >= (total >> 2):
            return 0, 0, 1
        exponent = (j & ((1 << (length - 2 * s - 2)) - 1)) << (2 * s)
    if inv:
        exponent = (total - exponent) & (total - 1)
    quad = exponent >> depth
    rom = exponent & ((1 << depth) - 1)
    neg_im = (quad >> 1) & 1
    swap = quad & 1
    r = (pack(md, 18, 18) | pack(inv, 17, 17) | pack((quad >> 1) & 1, 16, 16)
         | pack(swap ^ neg_im, 15, 15) | pack(swap, 14, 14) | pack(quad, 12, 13)
         | pack(rom, 0, 11))
    x = (pack(depth, 20, 23) | pack(length, 16, 19) | pack(s, 12, 15)
         | pack(exponent, 0, 11))
    return r, x, 0


_KERNELS = {'r2_bfly_s12': _m_r2, 'r4_bfly_s12': _m_r4,
            'twiddle_index16': _m_twiddle}


def _m_cordic(a, b, c):
    x, y = sb(a, 0, 12), sb(a, 12, 12)
    theta, iters = sb(b, 0, 14), ub(c, 0, 4)
    if ub(a, 24, 8) or ub(b, 14, 18) or ub(c, 4, 28) or iters == 0 or iters > 12:
        return 0, 0, 1
    z = s16(theta)
    pre = 0
    if z > 4096:
        x, y, z, pre = s17(-y), s17(x), s16(z - 4096), 1
    elif z < -4096:
        x, y, z, pre = s17(y), s17(-x), s16(z + 4096), 2
    for k in range(iters):
        tx, ty = x >> k, y >> k
        if z < 0:
            x, y = s17(x + ty), s17(y - tx)
            z = s16(z + CORDIC_TAB[k])
        else:
            x, y = s17(x - ty), s17(y + tx)
            z = s16(z - CORDIC_TAB[k])
    ox, clip_x = clamp14(x)
    oy, clip_y = clamp14(y)
    r = (pack(ox, 0, 13) | pack(oy, 14, 27) | pack(clip_x, 28, 28)
         | pack(clip_y, 29, 29) | pack(pre, 30, 31))
    aux = (pack(z, 0, 15) | pack(iters, 16, 19) | pack(pre, 20, 23))
    return r, aux, clip_x | clip_y


def _m_cadd(a, b, c):
    xr, xi = sb(a, 0, 12), sb(a, 12, 12)
    yr, yi = sb(b, 0, 12), sb(b, 12, 12)
    k = ub(c, 0, 4)
    if ub(a, 24, 8) or ub(b, 24, 8) or ub(c, 4, 28):
        return 0, 0, 1
    zr, zi = yr >> k, yi >> k
    sum_r, flag_r = clamp12(xr + zr)
    sum_i, flag_i = clamp12(xi + zi)
    dif_r, flag_g = clamp12(xr - zr)
    dif_i, flag_h = clamp12(xi - zi)
    r = (pack(sum_r, 0, 11) | pack(sum_i, 12, 23) | pack(flag_r, 24, 24)
         | pack(flag_i, 25, 25) | pack(k, 28, 31))
    x = (pack(dif_r, 0, 11) | pack(dif_i, 12, 23) | pack(flag_g, 24, 24)
         | pack(flag_h, 25, 25) | pack(k, 28, 31))
    return r, x, flag_r | flag_i | flag_g | flag_h


def _m_cmul(a, b, c):
    zr, zi = sb(a, 0, 12), sb(a, 12, 12)
    wr, wi = sb(b, 0, 12), sb(b, 12, 12)
    cj = ub(c, 0, 1)
    if ub(a, 24, 8) or ub(b, 24, 8) or ub(c, 1, 31):
        return 0, 0, 1
    su, u_clip = clip12(zr + zi)
    sw, w_clip = clip12(wr + wi)
    p1, p2, p3 = zr * wr, zi * wi, su * sw
    re, r_sat = clip12(round_shift(p1 - p2, 10))
    rounded = round_shift(p3 - p1 - p2, 10)
    im, i_sat = clip12(-rounded if cj else rounded)
    r = (pack(re, 0, 11) | pack(im, 12, 23) | pack(r_sat, 24, 24)
         | pack(i_sat, 25, 25) | pack(u_clip, 26, 26) | pack(w_clip, 27, 27))
    x = pack(su, 0, 11) | pack(sw, 12, 23) | pack(cj, 24, 24)
    return r, x, r_sat | i_sat | u_clip | w_clip


def _m_mag(a, b, c):
    re, im = sb(a, 0, 12), sb(a, 12, 12)
    tier = ub(c, 0, 4)
    if ub(a, 24, 8) or b != 0 or ub(c, 4, 28) or tier > 3:
        return 0, 0, 1
    mag_r = (-re if re < 0 else re) & 0xFFF
    mag_i = (-im if im < 0 else im) & 0xFFF
    if mag_r >= mag_i:
        hi, lo, swap = mag_r, mag_i, 0
    else:
        hi, lo, swap = mag_i, mag_r, 1
    tiers = (hi + (lo >> 1), hi + (lo >> 1) - (lo >> 3),
             hi + (lo >> 2), hi + (lo >> 2) + (lo >> 4))
    estimate = tiers[tier]
    over = 1 if estimate > 4095 else 0
    r = (pack(estimate, 0, 11) | pack(swap, 12, 12) | pack(1 if re < 0 else 0, 13, 13)
         | pack(1 if im < 0 else 0, 14, 14) | pack(1 if not (mag_r or mag_i) else 0, 15, 15)
         | pack(1 if mag_r == mag_i else 0, 16, 16) | pack(tier, 17, 18))
    x = (pack(hi, 0, 11) | pack(tiers[0], 12, 23) | pack(1 - over, 24, 24)
         | pack(tier, 25, 26))
    return r, x, over


_KERNELS.update({'cordic_rotate': _m_cordic, 'complex_add_sat': _m_cadd,
                 'cmul_q15': _m_cmul, 'mag_approx_s12': _m_mag})


def _m_stock(a, b, c):
    length, s, j = ub(a, 0, 4), ub(a, 4, 4), ub(a, 8, 12)
    md, bw = ub(b, 0, 2), ub(c, 0, 4)
    if (ub(a, 20, 12) or ub(b, 2, 30) or ub(c, 4, 28)
            or length < 2 or length > 12):
        return 0, 0, 1
    total = 1 << length
    bank_mask = (1 << bw) - 1
    rank = (1 << s) - 1
    stride = 1 << s
    if md in (2, 3):
        return 0, 0, 1
    clash = 1 if (stride & bank_mask) == 0 else 0
    if md == 0:
        if s >= length or j >= (total >> 1):
            return 0, 0, 1
        base = ((j >> s) << (s + 1)) | (j & rank)
        first, second = base, base | stride
        tail_first, tail_second = (j & rank) << (length - s - 1), stride
    else:
        if s >= length - 1 or j >= (total >> 2):
            return 0, 0, 1
        base = ((j >> s) << (s + 2)) | (j & rank)
        first, second = base, base + stride
        tail_first, tail_second = base + 2 * stride, base + 3 * stride
    r = (pack(first, 0, 11) | pack(second, 12, 23) | pack(clash, 24, 24)
         | pack(1, 25, 25) | pack(md, 26, 27) | pack(s, 28, 31))
    x = (pack(tail_first, 0, 11) | pack(tail_second, 12, 23)
         | pack(base & bank_mask, 24, 27) | pack(bw, 28, 31))
    return r, x, 0


def _m_dit(a, b, c):
    length, s, j = ub(a, 0, 4), ub(a, 4, 4), ub(a, 8, 12)
    md, bw = ub(b, 0, 2), ub(c, 0, 4)
    if (ub(a, 20, 12) or ub(b, 2, 30) or ub(c, 4, 28)
            or length < 2 or length > 12):
        return 0, 0, 1
    total = 1 << length
    bank_mask = (1 << bw) - 1
    rank = (1 << s) - 1
    stride = 1 << s
    if md == 3 or s >= length:
        return 0, 0, 1
    if md == 0:
        if j >= (total >> 1):
            return 0, 0, 1
        pos0 = ((j >> s) << (s + 1)) | (j & rank)
        pos1 = pos0 | stride
        flag = 1 if ((pos0 ^ pos1) & bank_mask) == 0 else 0
        r = (pack(br_bits(pos0, length), 0, 11)
             | pack(br_bits(pos1, length), 12, 23) | pack(flag, 24, 24)
             | pack(1, 25, 25) | pack(0, 26, 27) | pack(s, 28, 31))
        x = (pack((j & rank) << (length - s - 1), 0, 11)
             | pack(pos0, 12, 23) | pack(br_bits(j, length) & 0xF, 24, 27)
             | pack(bw, 28, 31))
    elif md == 1:
        if j >= total:
            return 0, 0, 1
        first = br_bits(j, length)
        partner = (total - j) & (total - 1)
        second = br_bits(partner, length)
        r = (pack(first, 0, 11) | pack(second, 12, 23)
             | pack(1 if first == second else 0, 24, 24) | pack(1, 25, 25)
             | pack(1, 26, 27) | pack(s, 28, 31))
        x = (pack(partner, 0, 11) | pack(j, 12, 23)
             | pack(j & bank_mask, 24, 27) | pack(bw, 28, 31))
    else:
        if s >= length - 1 or j >= (total >> 2):
            return 0, 0, 1
        pos0 = ((j >> s) << (s + 2)) | (j & rank)
        legs = [br_bits(pos0 + k * stride, length) for k in range(4)]
        r = (pack(legs[0], 0, 11) | pack(legs[1], 12, 23)
             | pack(1 if (stride & bank_mask) == 0 else 0, 24, 24)
             | pack(1, 25, 25) | pack(2, 26, 27) | pack(s, 28, 31))
        x = (pack(legs[2], 0, 11) | pack(legs[3], 12, 23)
             | pack(legs[0] & bank_mask, 24, 27) | pack(bw, 28, 31))
    return r, x, 0


def _m_chirp(a, b, c):
    xr, xi = sb(a, 0, 12), sb(a, 12, 12)
    cos, sin = sb(b, 0, 12), sb(b, 12, 12)
    length, quad, cj = ub(c, 0, 4), ub(c, 4, 2), ub(c, 6, 1)
    if (ub(a, 24, 8) or ub(b, 24, 8) or ub(c, 7, 25)
            or length < 2 or length > 12):
        return 0, 0, 1
    real, imag = (sin, cos) if quad & 1 else (cos, sin)
    if (quad & 1) ^ ((quad >> 1) & 1):
        real = -real
    if quad >> 1:
        imag = -imag
    if cj:
        imag = -imag
    wr, clip_r = clip12(real)
    wi, clip_i = clip12(imag)
    clipped = clip_r | clip_i
    axis = 1 if wr == 0 or wi == 0 else 0
    re, r_sat = clip12(round_shift(xr * wr - xi * wi, 10))
    im, i_sat = clip12(round_shift(xi * wr + xr * wi, 10))
    r = (pack(re, 0, 11) | pack(im, 12, 23) | pack(r_sat, 24, 24)
         | pack(i_sat, 25, 25) | pack(clipped, 26, 26) | pack(cj, 27, 27)
         | pack(quad, 28, 29) | pack(axis, 30, 30))
    x = pack(wr, 0, 11) | pack(wi, 12, 23) | pack(length, 24, 27)
    return r, x, r_sat | i_sat | clipped


_KERNELS.update({'stockham_addr': _m_stock, 'dit_stage_map': _m_dit,
                 'chirp_mult_s12': _m_chirp})


def step(name, a, b, c, state=0):
    kernel = _KERNELS.get(name)
    if kernel is None:
        raise ValueError(name)
    r, x, f = kernel(a & MASK, b & MASK, c & MASK)
    return r, x, int(bool(f)), state


# -----------------------------------------------------------------------------
# Vector sets: rows 0..127 are the board set, structured and hand-designed.
# -----------------------------------------------------------------------------
def cpl(re, im):
    """Pack a signed 12-bit complex pair into one 24-bit beat field."""
    return (re & 0xFFF) | ((im & 0xFFF) << 12)


# Small integer sample pairs kept exact through every requantise in this family.
SMALL_PAIRS = [(1, 0, 0, 1), (1, 2, 3, 4), (3, -1, -2, 5), (7, 0, 0, 0),
               (-4, 6, 2, -3), (1, 1, -1, -1), (0, 8, 8, 0), (5, 5, 5, 5)]

GAINS = [1024, 512, 2047, -2048, 724, -724, 0, 1023]


def _board_rows(name):
    rows = []
    if name == 'r2_bfly_s12':
        rows.append((1 << 24, 0, 0))                                   # malformed
        rows.append((0, 0, 1 << 15))                                   # malformed
        rows.append((0, 0, cpl(0, 0) | (0 << 12)))                     # all-zero axis
        for axis in range(8):
            for xr, xi, yr, yi in SMALL_PAIRS:
                rows.append((cpl(xr, xi), cpl(yr, yi), (axis << 12) | (1024 & 0xFFF)))
        for gain in GAINS:
            for xr, xi, yr, yi in SMALL_PAIRS[:6]:
                rows.append((cpl(xr, xi), cpl(yr, yi), (0 << 12) | (gain & 0xFFF)))
        for axis in (1, 3):
            for xr, xi, yr, yi in ((2047, -2048, -2048, 2047), (2047, 2047, -2048, -2048),
                                   (-2048, 2047, 2047, -2048)):
                rows.append((cpl(xr, xi), cpl(yr, yi), (axis << 12) | (2047 & 0xFFF)))
        for gain in (-2048, 2047, 1024, -1024):
            for xr, xi, yr, yi in ((1000, 0, 0, 0), (0, 1000, 0, 0)):
                rows.append((cpl(xr, xi), cpl(yr, yi), (2 << 12) | (gain & 0xFFF)))
        rows.append((cpl(-2048, -2048), cpl(2047, 2047), (0 << 12) | (2047 & 0xFFF)))
        rows.append((cpl(2047, -2048), cpl(-2048, 2047), (1 << 12) | (-2048 & 0xFFF)))
    elif name == 'r4_bfly_s12':
        rows.append((0, 0, 1 << 26))                                    # malformed
        rows.append((1 << 24, 0, 0))                                    # malformed
        for xr, xi, yr, yi in SMALL_PAIRS:
            rows.append((cpl(xr, xi), cpl(yr, yi), cpl(1024, 0)))       # even legs
        for axis_pair in SMALL_PAIRS:
            xr, xi, yr, yi = axis_pair
            rows.append((cpl(xr, xi), cpl(yr, yi), (1 << 24) | cpl(1024, 0)))
            rows.append((cpl(xr, xi), cpl(yr, yi), (1 << 24) | (1 << 25) | cpl(1024, 0)))
        for gain in GAINS:
            for sign in (0, 1):
                for xr, xi, yr, yi in SMALL_PAIRS[:5]:
                    rows.append((cpl(xr, xi), cpl(yr, yi),
                                 (1 << 24) | (sign << 25) | cpl(gain, 512)))
        for tw in ((724, -724), (-724, 724), (0, 1024), (1024, 0), (512, 512)):
            for sign in (0, 1):
                for xr, xi, yr, yi in SMALL_PAIRS[:4]:
                    rows.append((cpl(xr, xi), cpl(yr, yi),
                                 (1 << 24) | (sign << 25) | cpl(*tw)))
        for xr, xi, yr, yi in ((2047, 2047, -2048, -2048), (-2048, 2047, 2047, -2048),
                               (2047, -2048, -2048, 2047)):
            rows.append((cpl(xr, xi), cpl(yr, yi), (1 << 24) | cpl(1024, 1024)))
            rows.append((cpl(xr, xi), cpl(yr, yi), (1 << 24) | (1 << 25) | cpl(2047, 2047)))
    elif name == 'twiddle_index16':
        rows.append((1 << 20, 0, 0))                                    # malformed
        rows.append((0, 1 << 1, 0))                                     # malformed
        rows.append((13, 0, 0))                                         # L above range
        rows.append((1, 0, 0))                                          # L below range
        rows.append((6 | (6 << 4), 0, 0))                               # s == L
        # Stockham radix-2 rows: j stays inside the mask window, so every beat
        # here yields a different (exponent, quadrant, ROM) triple.
        for length in range(2, 13):
            for stage in range(length):
                for j in range(min(3, 1 << (length - stage - 1))):
                    rows.append((length | (stage << 4) | (j << 8), 0, 0))
        # Radix-4 in-place DIF passes (even L only), same distinctness rule.
        for length in range(4, 13, 2):
            for stage in range(length >> 1):
                for j in range(min(3, 1 << (length - 2 * stage - 2))):
                    rows.append((length | (stage << 4) | (j << 8), 0, 1))
        # Conjugate (inverse-transform) exponents.
        for length in (3, 5, 7, 9, 11):
            for stage in range(length):
                for j in range(min(2, 1 << (length - stage - 1))):
                    rows.append((length | (stage << 4) | (j << 8), 1, 0))
        for length in (4, 6, 8):
            for stage in range(length >> 1):
                rows.append((length | (stage << 4) | (1 << 8), 1, 1))
    elif name == 'cordic_rotate':
        rows.append((0, 0, 0))                                          # zero count
        rows.append((0, 0, 13))                                         # count over 12
        rows.append((1 << 24, 0, 4))                                    # malformed
        vectors = [(1024, 0), (0, 1024), (-2048, 0), (0, -2048), (724, 724),
                   (-512, 256), (1, 1), (-1024, -1024)]
        angles = [0, 4096, -4096, 4097, -4097, 8191, -8192, 512, -512, 1024,
                  2048, -2048, 321, -321, 45, -45]
        for iters in (1, 2, 3, 6, 12):
            for angle in angles[:8 if iters != 12 else 16]:
                for re, im in vectors[:4]:
                    rows.append((cpl(re, im), angle & 0x3FFF, iters))
        for angle in (0, 1024, -1024, 4000, -4000, 4096, -4096, 4095):
            for re, im in vectors:
                rows.append((cpl(re, im), angle & 0x3FFF, 12))
        for iters in range(1, 13):
            rows.append((cpl(1024, 0), 1000, iters))
    elif name == 'complex_add_sat':
        rows.append((0, 0, 1 << 4))                                     # malformed
        rows.append((1 << 24, 0, 3))                                    # malformed
        pairs = [((100, 200), (300, -400)), ((1, 0), (0, 1)), ((2047, 2047), (1, 1)),
                 ((-2048, -2048), (-1, -1)), ((0, 0), (0, 0)), ((1024, -1024), (512, 512)),
                 ((-1000, 700), (300, 300)), ((7, 7), (-7, -7))]
        for k in range(16):
            for (xr, xi), (yr, yi) in pairs:
                rows.append((cpl(xr, xi), cpl(yr, yi), k))
        for extreme in ((2047, 2047, 2047, 2047), (-2048, -2048, -2048, -2048),
                        (2047, -2048, -2048, 2047), (-2048, 2047, 2047, -2048)):
            for k in (0, 1, 2, 7):
                rows.append((cpl(extreme[0], extreme[1]), cpl(extreme[2], extreme[3]), k))
        rows.append((cpl(2047, 2047), cpl(2047, 2047), 0))
        rows.append((cpl(-2048, -2048), cpl(2047, 2047), 0))
    elif name == 'cmul_q15':
        rows.append((0, 0, 1 << 1))                                     # malformed
        rows.append((0, 1 << 24, 0))                                    # malformed
        zets = [(1024, 0), (0, 1024), (724, 724), (-724, 724), (512, 256),
                (1, 1), (-2048, 1023), (1000, -1000)]
        wets = [(1024, 0), (0, 1024), (724, -724), (512, 512), (2047, 2047),
                (-2048, -2048), (256, 512), (1023, 0)]
        for conj in (0, 1):
            for zr, zi in zets:
                for wr, wi in wets:
                    rows.append((cpl(zr, zi), cpl(wr, wi), conj))
        for zr, zi in ((-2048, -2048), (2047, 2047), (1024, 1024), (-1024, -1024)):
            for wr, wi in ((2047, 2047), (-2048, -2048), (1024, 1024)):
                rows.append((cpl(zr, zi), cpl(wr, wi), 0))
                rows.append((cpl(zr, zi), cpl(wr, wi), 1))
    elif name == 'mag_approx_s12':
        rows.append((0, 1, 0))                                          # malformed
        rows.append((0, 0, 4))                                          # tier out of range
        samples = [(300, 400), (1024, 1024), (-1024, 1024), (0, 0), (1, 0),
                   (0, -1), (2047, 2047), (-2048, -2048), (-2048, 2047),
                   (1000, -300), (511, 512), (1448, 724)]
        for tier in range(4):
            for re, im in samples:
                rows.append((cpl(re, im), 0, tier))
        for re in range(0, 64, 7):
            for im in range(0, 64, 5):
                for tier in range(4):
                    rows.append((cpl(re, im), 0, tier))
        for re in (-2048, -1024, -1, 0, 1, 1023, 2047):
            for im in (-2048, -724, 0, 724, 2047):
                rows.append((cpl(re, im), 0, 1))
    elif name == 'stockham_addr':
        rows.append((4, 2, 0))                                          # reserved mode
        rows.append((1 << 20, 0, 3))                                    # malformed
        rows.append((13, 0, 0))                                         # L out of range
        rows.append((9 | (9 << 4), 0, 2))                               # s == L
        rows.append((5 | (4 << 4) | (16 << 8), 0, 3))                   # j >= N/2
        # Radix-2 pairs at a 256-point stage: one beat per (s, j, bank width),
        # and s, the pair base and the bank all land in different result fields.
        for stage in range(4):
            for j in range(8):
                for bw in (0, 3, 5):
                    rows.append((8 | (stage << 4) | (j << 8), 0, bw))
        for stage in range(4):
            for j in range(6):
                for bw in (1, 2, 4, 6):
                    rows.append((6 | (stage << 4) | (j << 8), 0, bw))
        # Radix-4 leg sets: legs 2 and 3 ride in aux, so the legs separate beats.
        for length in (6, 8, 10):
            total = 1 << length
            for stage in range(min(length >> 1, 3)):
                for j in range(min(6, total >> 2)):
                    rows.append((length | (stage << 4) | (j << 8), 1, 2 + stage))
        for index, length in enumerate((2, 3, 4, 5, 7, 12)):
            rows.append((length | (index << 4) | (1 << 8), 0, index))
            rows.append((length | (index << 4) | (1 << 8), 1, index))
    elif name == 'dit_stage_map':
        rows.append((4, 3, 0))                                          # reserved mode
        rows.append((0, 1 << 2, 0))                                     # malformed
        rows.append((1, 0, 0))                                          # L below range
        for length in range(2, 9):
            total = 1 << length
            for stage in range(min(length, 3)):
                for j in range(min(4, total >> 1)):
                    rows.append((length | (stage << 4) | (j << 8), 0, 3))
        for length in (2, 3, 4, 5):
            total = 1 << length
            for j in range(min(8, total)):
                rows.append((length | (0 << 4) | (j << 8), 1, 2))
                rows.append((length | (1 << 4) | (j << 8), 1, 4))
        for length in (4, 6, 8):
            total = 1 << length
            for stage in range(max(1, length >> 1)):
                for j in range(min(4, total >> 2)):
                    rows.append((length | (stage << 4) | (j << 8), 2, 3))
                    rows.append((length | (stage << 4) | (j << 8), 2, 0))
    elif name == 'chirp_mult_s12':
        rows.append((0, 0, 1 << 7))                                     # malformed
        rows.append((0, 0, 1 | (0 << 4) | (0 << 6)))                    # L out of range
        rows.append((1 << 24, 0, 6 | (1 << 4)))                         # malformed
        samples = [(1024, 0), (0, 1024), (724, 724), (-512, 256), (1, 1),
                   (1000, -1000), (-2048, 2047)]
        pairs = [(1024, 0), (0, 1024), (724, 724), (-1024, 0), (0, -1024),
                 (512, 512), (2047, 0), (0, 2047)]
        for quad in range(4):
            for conj in (0, 1):
                for cos, sin in pairs:
                    rows.append((cpl(1024, 0), cpl(cos, sin),
                                 (4 | (quad << 4) | (conj << 6))))
        for re, im in samples:
            for conj in (0, 1):
                for quad in range(4):
                    rows.append((cpl(re, im), cpl(724, 724),
                                 (8 | (quad << 4) | (conj << 6))))
        for cos, sin in ((-2048, 0), (0, -2048), (-2048, -2048), (-724, -724)):
            for quad in (1, 2, 3):
                rows.append((cpl(1024, 1024), cpl(cos, sin), 5 | (quad << 4)))
        for length in (2, 3, 6, 9, 12):
            rows.append((cpl(-1024, 512), cpl(0, 1024), length | (2 << 4)))
    return rows


def vectors(name, count=320):
    """Structured board set first (rows 0..127), seeded random only afterwards."""
    rows = _board_rows(name)
    rng = Random(0xF510E0 + sum(name.encode()))

    def mangle(value):
        """About one beat in sixty carries a reserved bit above every legal field."""
        return value | (1 << rng.randrange(20, 31)) if rng.getrandbits(6) == 0 else value

    def control(low, high):
        return mangle(rng.randrange(low, high + 1))

    while len(rows) < count:
        re1 = rng.choice([rng.randrange(-2048, 2048), rng.getrandbits(12) - 2048])
        im1 = rng.choice([rng.randrange(-2048, 2048), rng.getrandbits(12) - 2048])
        re2 = rng.randrange(-2048, 2048)
        im2 = rng.randrange(-2048, 2048)
        if name == 'r2_bfly_s12':
            rows.append((mangle(cpl(re1, im1)), mangle(cpl(re2, im2)),
                         mangle((rng.randrange(8) << 12)
                                | (rng.randrange(-2048, 2048) & 0xFFF))))
        elif name == 'r4_bfly_s12':
            rows.append((mangle(cpl(re1, im1)), mangle(cpl(re2, im2)),
                         mangle((rng.randrange(2) << 24) | (rng.randrange(2) << 25)
                                | cpl(rng.randrange(-2048, 2048),
                                      rng.randrange(-2048, 2048)))))
        elif name == 'twiddle_index16':
            length = rng.randrange(2, 13)
            rows.append((mangle(length | (rng.randrange(length + 2) << 4)
                                 | (rng.getrandbits(12) << 8)),
                         control(0, 1), control(0, 1)))
        elif name == 'cordic_rotate':
            rows.append((mangle(cpl(re1, im1)), mangle(rng.randrange(-8192, 8192) & 0x3FFF),
                         control(1, 12)))
        elif name == 'complex_add_sat':
            rows.append((mangle(cpl(re1, im1)), mangle(cpl(re2, im2)), control(0, 15)))
        elif name == 'cmul_q15':
            rows.append((mangle(cpl(re1, im1)), mangle(cpl(re2, im2)), control(0, 1)))
        elif name == 'mag_approx_s12':
            rows.append((mangle(cpl(re1, im1)), 0 if rng.getrandbits(5) else rng.getrandbits(8),
                         control(0, 3)))
        elif name in ('stockham_addr', 'dit_stage_map'):
            length = rng.randrange(2, 13)
            rows.append((mangle(length | (rng.randrange(length + 2) << 4)
                                 | (rng.getrandbits(12) << 8)),
                         control(0, 3), control(0, 15)))
        elif name == 'chirp_mult_s12':
            rows.append((mangle(cpl(re1, im1)), mangle(cpl(re2, im2)),
                         mangle(control(2, 12) | (rng.randrange(4) << 4)
                                | (rng.randrange(2) << 6))))
        else:
            rows.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32)))
    return rows[:count]


def selftest():
    """Reference checks for the FFT family, derived from outside the model.

    Nothing below reads step() output to build an expected value.  Every number
    is one of:

      * a hand-computed DFT/FFT value -- the 4-point transform of (1,2,3,4) is
        (10, -2+2j, -2, -2-2j), worked out on the sum/difference decomposition
        this family's butterflies implement, and an 8-point transform is
        assembled from these cores and held against a naive O(N^2) DFT written
        here;
      * published trigonometry -- twiddle cos/sin counts and the CORDIC
        atan(2^-i) table and gain A(i)=prod sqrt(1+4^-k)=1.6467602581, re-derived
        from math.atan/math.sqrt inside this function;
      * a second straightforward implementation (naive complex multiply,
        floor-shift saturating add, bit-reversal loop, exponent rule
        e=(j mod 2^(L-s-1))*2^s) that shares no code with the kernels.

    `state` is threaded through every beat of every trace and handed back by
    step(), exactly as generate.py and the board harness do it; no trace restarts
    at zero.  No FFT core keeps state, so each trace also proves that the state
    it is given comes back unchanged.
    """
    checks = 0

    def check(ok, what):
        nonlocal checks
        assert bool(ok), 'fft selftest failed: ' + what
        checks += 1

    def u(value, lo, hi):
        """Unsigned field, written from the spec's [hi:lo] notation."""
        return (value >> lo) & ((1 << (hi - lo + 1)) - 1)

    def sg(value, lo, hi):
        """The same field read back as two's complement."""
        width = hi - lo + 1
        raw = u(value, lo, hi)
        return raw - (1 << width) if raw >> (width - 1) else raw

    def pair(re, im):
        """Stimulus packing only: two signed 12-bit lanes into one 24-bit beat."""
        return (re & 0xFFF) | ((im & 0xFFF) << 12)

    def runner(name):
        """Feed one core a beat at a time, carrying its state forward."""
        held = [0]

        def beat(a, b, c):
            r, x, f, new_state = step(name, a, b, c, held[0])
            assert new_state == held[0], f'{name}: stateless kernel rewrote state'
            held[0] = new_state
            return r, x, f

        return beat

    def naive_dft(seq):
        """Textbook O(N^2) DFT: X_k = sum_n x_n e^{-2 pi i k n / N}."""
        total = len(seq)
        out = []
        for k in range(total):
            acc = complex(0.0, 0.0)
            for index, value in enumerate(seq):
                angle = -2.0 * math.pi * k * index / total
                acc += complex(value[0], value[1]) * complex(math.cos(angle),
                                                             math.sin(angle))
            out.append(acc)
        return out

    def bit_reverse(value, length):
        """Second implementation of the reversal the address cores use."""
        out = 0
        for _ in range(length):
            out = (out << 1) | (value & 1)
            value >>= 1
        return out

    # --------------------------------------------------------------- r2_bfly_s12
    beat_r2 = runner('r2_bfly_s12')

    def naive_r2(xr, xi, yr, yi, gain, axis):
        """Radix-2 butterfly written the slow textbook way.

        Sum leg (x+y) stays 13-bit exact; the difference leg rotates by the
        axis twiddle with a general complex multiply (the core uses a wire
        swap), clips into the slice operand window, then requantises
        round-half-up by the Q1.10 gain and clamps.
        """
        w_re, w_im = ((1, 0), (0, -1), (-1, 0), (0, 1))[axis]
        d_re, d_im = xr - yr, xi - yi
        t_re = d_re * w_re - d_im * w_im
        t_im = d_re * w_im + d_im * w_re
        c_re = min(2047, max(-2048, t_re))
        c_im = min(2047, max(-2048, t_im))
        o_re = min(2047, max(-2048, (c_re * gain + 512) >> 10))
        o_im = min(2047, max(-2048, (c_im * gain + 512) >> 10))
        clipped = int(c_re != t_re or c_im != t_im)
        pre_re, pre_im = (c_re * gain + 512) >> 10, (c_im * gain + 512) >> 10
        return dict(sum=(xr + yr, xi + yi), leg=(o_re, o_im), clipped=clipped,
                    sat_re=int(pre_re != o_re), sat_im=int(pre_im != o_im),
                    fault=bool(clipped or pre_re != o_re or pre_im != o_im))

    # Hand trace: x = 3+1j, y = 1-2j, W = 1, gain = unity 1024.
    # sum = 4-1j, difference = 2+3j, and (p*1024+512)>>10 == p exactly.
    r, x, f = beat_r2(pair(3, 1), pair(1, -2), 1024)
    check((sg(r, 0, 12), sg(r, 13, 25), u(r, 26, 26), u(r, 29, 31),
           sg(x, 0, 11), sg(x, 12, 23), u(x, 24, 26), f)
          == (4, -1, 0, 0, 2, 3, 0, 0), 'r2 hand trace at unity gain')

    # The same difference (2+3j) through the four axis codes, all exact at gain
    # 1024: 1 -> (2,3), -j -> (3,-2), -1 -> (-2,-3), +j -> (-3,2).
    for axis, want in ((0, (2, 3)), (1, (3, -2)), (2, (-2, -3)), (3, (-3, 2))):
        r, x, f = beat_r2(pair(3, 1), pair(1, -2), (axis << 12) | 1024)
        check((sg(x, 0, 11), sg(x, 12, 23), u(r, 29, 31), u(x, 24, 26), f)
              == (want[0], want[1], axis, 0, 0),
              f'r2 axis code {axis} rotation')

    # Gain 512 is exactly one half: (2*512+512)>>10 = 1 and (3*512+512)>>10 = 2,
    # the second one being the round-half-up tie 1.5 -> 2.
    r, x, f = beat_r2(pair(3, 1), pair(1, -2), 512)
    check((sg(x, 0, 11), sg(x, 12, 23), f) == (1, 2, 0),
          'r2 half gain requantise rounds halves up')

    # The slice is signed: difference -1 against gain -1024 is +1024 counts, so
    # the answer is 1.  An unsigned $mul would read (-1) as 4095 and saturate.
    r, x, f = beat_r2(pair(0, 0), pair(1, 0), -1024 & 0xFFF)
    check((sg(x, 0, 11), sg(x, 12, 23), f) == (1, 0, 0),
          'r2 slice multiplies signed operands, not unsigned')

    # -2048 * -2048 = 4194304, plus the 512 rounding term that is 4194816, and
    # 4194816 >> 10 = 4096, which must clamp to 2047 and raise the re flag.
    r, x, f = beat_r2(pair(-2048, 0), pair(0, 0), (-2048 & 0xFFF))
    check((sg(r, 0, 12), sg(x, 0, 11), u(x, 24, 24), u(x, 26, 26), f)
          == (-2048, 2047, 1, 0, 1), 'r2 saturating product lane clamps high')

    # The 13-bit difference 4095 does not fit the slice operand: it clips to
    # 2047 (clipped flag), then 2047*2047 = 4190209, +512 = 4190721, >>10 = 4092
    # which again clamps to 2047 with the re saturation flag.
    r, x, f = beat_r2(pair(2047, 0), pair(-2048, 0), 2047)
    check((sg(x, 0, 11), sg(x, 12, 23), u(x, 24, 26), u(r, 26, 26), f)
          == (2047, 0, 0b101, 1, 1), 'r2 clipped difference then saturated lane')

    # Codes 4..7 are not reserved (only c[31:15] is) and share the +j cone.
    r, x, f = beat_r2(pair(3, 1), pair(1, -2), (5 << 12) | 1024)
    check((sg(x, 0, 11), sg(x, 12, 23), u(r, 29, 31), f) == (-3, 2, 5, 0),
          'r2 axis codes above 3 stay legal and echo back')

    # Every axis against the naive complex implementation, over pairs chosen so
    # that some lanes clip and some saturate.
    for (xr, xi, yr, yi) in ((3, 1, 1, -2), (1, 2, 3, 4), (-4, 6, 2, -3),
                             (2047, 2047, -2048, -2048), (1000, -1000, 1023, 511),
                             (-2048, 2047, 2047, -2048)):
        for axis in range(4):
            for gain in (1024, 512, 1023, -724, 2047, -2048, 0, 1):
                want = naive_r2(xr, xi, yr, yi, gain, axis)
                r, x, f = beat_r2(pair(xr, xi), pair(yr, yi), (axis << 12)
                                 | (gain & 0xFFF))
                check((sg(r, 0, 12), sg(r, 13, 25), sg(x, 0, 11), sg(x, 12, 23),
                       u(x, 24, 26), u(r, 26, 26), f)
                      == (want['sum'][0], want['sum'][1], want['leg'][0],
                          want['leg'][1], (want['sat_im'] << 1)
                          | (want['sat_re']) | (want['clipped'] << 2),
                          want['clipped'], 1 if want['fault'] else 0),
                      f'r2 vs naive butterfly at {(xr, xi, yr, yi, gain, axis)}')

    # Malformed beats: a reserved high bit on any port zeroes the response and
    # leaves the threaded state alone (c[31] included).
    for bad in ((1 << 24, 0, 1024), (0, 1 << 31, 1024), (0, 0, 1 << 15),
                (0, 0, 1 << 31), (0, 0, (1 << 31) | 1024)):
        r, x, f = beat_r2(*bad)
        check((r, x, f) == (0, 0, 1), f'r2 malformed beat {bad} zeroes response')

    # --------------------------------------------------------------- r4_bfly_s12
    beat_r4 = runner('r4_bfly_s12')

    def naive_r4(ur, ui, vr, vi, wr, wi, sign):
        """Streaming radix-4 leg written as plain complex arithmetic.

        sign 0 forms d = u - j*v and sign 1 forms d = u + j*v, which is the odd
        leg pair of a radix-4 butterfly, then multiplies by the Q1.10 twiddle w.
        """
        p_re = ur - vi if sign else ur + vi
        p_im = ui + vr if sign else ui - vr
        c_re = min(2047, max(-2048, p_re))
        c_im = min(2047, max(-2048, p_im))
        pre_re = (c_re * wr - c_im * wi + 512) >> 10
        pre_im = (c_im * wr + c_re * wi + 512) >> 10
        return dict(leg=(min(2047, max(-2048, pre_re)),
                         min(2047, max(-2048, pre_im))),
                    pre=(p_re, p_im),
                    clip=int(p_re != c_re) | int(p_im != c_im) << 1,
                    sat=int(pre_re != min(2047, max(-2048, pre_re)))
                        | int(pre_im != min(2047, max(-2048, pre_im))) << 1)

    # The four legs of the 4-point DFT of (1,2,3,4), which on paper is
    #   X0 = 1+2+3+4 = 10,  X2 = 1-2+3-4 = -2,
    #   X1 = (1-3) + j(4-2) = -2+2j,  X3 = (1-3) - j(4-2) = -2-2j.
    # Even legs: u = x0+x2 = 4 against v = x1+x3 = 6 -> sum 10, difference -2.
    # Odd legs: b = x0-x2 = -2 and d = x1-x3 = -2, and X1 = b - j*d, X3 = b + j*d.
    hand4 = []
    r, x, f = beat_r4(pair(4, 0), pair(6, 0), pair(1024, 0))
    hand4.append(((sg(r, 0, 13), sg(r, 14, 27)), (sg(x, 0, 13), sg(x, 14, 27))))
    check(hand4[0] == ((10, 0), (-2, 0)) and (u(r, 28, 31), f) == (0, 0),
          'r4 even legs give X0 and X2 of the hand 4-point DFT')
    r, x, f = beat_r4(pair(-2, 0), pair(-2, 0), (1 << 24) | pair(1024, 0))
    check((sg(r, 0, 13), sg(r, 14, 27), u(r, 30, 31), f) == (-2, 2, 0b01, 0),
          'r4 odd leg with sign 0 gives X1 = -2+2j')
    r, x, f = beat_r4(pair(-2, 0), pair(-2, 0),
                      (1 << 24) | (1 << 25) | pair(1024, 0))
    check((sg(r, 0, 13), sg(r, 14, 27), u(r, 30, 31), f) == (-2, -2, 0b11, 0),
          'r4 odd leg with sign 1 gives X3 = -2-2j')
    want4 = naive_dft([(1, 0), (2, 0), (3, 0), (4, 0)])
    check(all([abs(hand4[0][0][0] - want4[0].real) < 1e-9,
               abs(hand4[0][0][1] - want4[0].imag) < 1e-9,
               abs(hand4[0][1][0] - want4[2].real) < 1e-9,
               abs(-2 - want4[1].real) < 1e-9, abs(2 - want4[1].imag) < 1e-9,
               abs(-2 - want4[3].real) < 1e-9, abs(-2 - want4[3].imag) < 1e-9]),
          'hand 4-point legs match the naive O(N^2) DFT of the same sequence')

    # Complex multiply by +j: w = (0,1024) must swap and negate exactly.
    r, x, f = beat_r4(pair(5, 3), pair(0, 0), (1 << 24) | pair(0, 1024))
    check((sg(r, 0, 13), sg(r, 14, 27), f) == (-3, 5, 0),
          'r4 leg through the +j quarter-turn twiddle')

    # Pre-add clipping: u = v = (2047,2047) with sign 0 makes p_re = 4094, which
    # clips to 2047 and raises aux[28]; p_im = 0 so no product saturates.
    r, x, f = beat_r4(pair(2047, 2047), pair(2047, 2047),
                      (1 << 24) | pair(1024, 0))
    check((sg(r, 0, 13), sg(r, 14, 27), sg(x, 0, 13), u(x, 28, 29), u(r, 28, 29), f)
          == (2047, 0, 4094, 0b01, 0, 1), 'r4 pre-add clips into the slice window')

    # Product saturation: d = (2047,2047) against w = (2047,2047) leaves
    # re = (4190209-4190209+512)>>10 = 0 and im = (8380418+512)>>10 = 8184,
    # which clamps to 2047 and flags only the imaginary lane.
    r, x, f = beat_r4(pair(2047, 2047), pair(0, 0), (1 << 24) | pair(2047, 2047))
    check((sg(r, 0, 13), sg(r, 14, 27), u(r, 28, 29), f) == (0, 2047, 0b10, 1),
          'r4 requantised product saturates one lane')

    # Sweep against the naive implementation, including the two clip routes.
    for (ur, ui, vr, vi) in ((1, 2, 3, 4), (3, -1, -2, 5), (2047, -2048, 2047, 2047),
                             (-2048, 2047, -1, 1), (1000, -1000, 512, 512),
                             (724, 724, -724, 724), (2047, 2047, 2047, 2047)):
        for (wr, wi) in ((1024, 0), (0, 1024), (724, 724), (-724, 724),
                         (2047, 2047), (-2048, -2048), (512, 512), (1, -1)):
            for sign in (0, 1):
                want = naive_r4(ur, ui, vr, vi, wr, wi, sign)
                r, x, f = beat_r4(pair(ur, ui), pair(vr, vi),
                                  (1 << 24) | (sign << 25) | pair(wr, wi))
                check((sg(r, 0, 13), sg(r, 14, 27), sg(x, 0, 13), sg(x, 14, 27),
                       u(x, 28, 29), u(r, 28, 29), u(r, 30, 31), f)
                      == (want['leg'][0], want['leg'][1], want['pre'][0],
                          want['pre'][1], want['clip'], want['sat'],
                          (sign << 1) | 1,
                          1 if (want['clip'] or want['sat']) else 0),
                      f'r4 vs naive leg at {(ur, ui, vr, vi, wr, wi, sign)}')

    # Untwiddled mode against the saturating complex adder: two independent
    # nets, the same sum and difference, as long as nothing clips.
    beat_cadd_early = runner('complex_add_sat')
    for (ar, ai, br_, bi) in ((4, 0, 6, 0), (1, 2, 3, 4), (-2048, 2047, 0, 0),
                              (1000, -1000, 1023, 1023)):
        r4s, r4d, _ = beat_r4(pair(ar, ai), pair(br_, bi), pair(1024, 0))
        cad, cax, caf = beat_cadd_early(pair(ar, ai), pair(br_, bi), 0)
        check(caf == 0 and (sg(r4s, 0, 13), sg(r4s, 14, 27),
                            sg(r4d, 0, 13), sg(r4d, 14, 27))
              == (sg(cad, 0, 11), sg(cad, 12, 23), sg(cax, 0, 11), sg(cax, 12, 23)),
              f'r4 even legs and complex_add_sat agree on {(ar, ai, br_, bi)}')

    for bad in ((1 << 24, 0, (1 << 24) | pair(1024, 0)),
                (0, 1 << 26, 1 << 24), (0, 0, 1 << 26), (0, 0, 1 << 31),
                (0, 0, (1 << 30) | pair(1024, 0))):
        r, x, f = beat_r4(*bad)
        check((r, x, f) == (0, 0, 1), f'r4 malformed beat {bad} zeroes response')

    # ------------------------------------------------------------ twiddle_index16
    beat_tw = runner('twiddle_index16')

    def naive_exponent(length, stage, index, mode, inv):
        """The two published schedule exponent rules, written out here.

        Stockham radix-2 row: e = (j mod 2^(L-s-1)) * 2^s.
        Radix-4 in-place DIF pass: e = (j mod 2^(L-2s-2)) * 2^(2s).
        """
        total = 1 << length
        if mode == 0:
            exp = (index % (1 << (length - stage - 1))) << stage
        else:
            exp = (index % (1 << (length - 2 * stage - 2))) << (2 * stage)
        return (total - exp) % total if inv else exp

    def quarter_turn(code, cos_v, sin_v):
        """A first-quadrant pair in the four hand-checked quarter turns.

        e^(j(pi/2 + a)) = ( -sin a, +cos a ); e^(j(pi + a)) = ( -cos a, -sin a );
        e^(j(3pi/2 + a)) = ( +sin a, -cos a ).
        """
        return ((cos_v, sin_v), (-sin_v, cos_v),
                (-cos_v, -sin_v), (sin_v, -cos_v))[code]

    # Literal hand beat: L=8 (N=256), s=6, j=1 -> e = (1 mod 2) << 6 = 64, which
    # is a quarter turn: quadrant 1, ROM address 0, swap, negate re, keep im.
    r, x, f = beat_tw(8 | (6 << 4) | (1 << 8), 0, 0)
    check((u(r, 0, 11), u(r, 12, 13), u(r, 14, 14), u(r, 15, 15), u(r, 16, 16),
           u(r, 17, 18), x, f)
          == (0, 1, 1, 1, 0, 0, 64 | (6 << 12) | (8 << 16) | (6 << 20), 0),
          'twiddle hand beat: 256-point stage 6 row 1 is a quarter turn')

    # e = 0 must land on quadrant 0 address 0 with no sign bit at all, i.e. the
    # published unity twiddle (cos, sin) = (1024, 0) counts.
    r, x, f = beat_tw(8 | (0 << 4) | (0 << 8), 0, 0)
    unity = quarter_turn(u(r, 12, 13),
                         int(round(1024 * math.cos(2 * math.pi * u(r, 0, 11) / 256))),
                         int(round(1024 * math.sin(2 * math.pi * u(r, 0, 11) / 256))))
    check((x & 0xFFF, u(r, 12, 31), unity, f) == (0, 0, (1024, 0), 0),
          'twiddle zero exponent reconstructs to exactly unity')

    # Sweep both modes, both directions, every legal L: the exponent must follow
    # the naive rule, the quadrant split must be exact, the three sign bits must
    # follow swap=q0 / negate im=q1 / negate re=q0^q1, and the reconstructed
    # twiddle must equal published trigonometry of the exponent itself.
    for length in range(2, 13):
        total = 1 << length
        depth = length - 2
        for mode in (0, 1):
            if mode and (length & 1):
                continue
            stage_cap = length if mode == 0 else length >> 1
            index_cap = (total >> 1) if mode == 0 else (total >> 2)
            for stage in range(min(stage_cap, 2)):
                for index in range(min(index_cap, 4)):
                    for inv in (0, 1):
                        exp = naive_exponent(length, stage, index, mode, inv)
                        r, x, f = beat_tw(length | (stage << 4) | (index << 8),
                                          inv, mode)
                        quad, rom = u(r, 12, 13), u(r, 0, 11)
                        table = (int(round(1024 * math.cos(2 * math.pi * rom / total))),
                                 int(round(1024 * math.sin(2 * math.pi * rom / total))))
                        got = quarter_turn(quad, *table)
                        err_re = got[0] - 1024 * math.cos(2 * math.pi * exp / total)
                        err_im = got[1] - 1024 * math.sin(2 * math.pi * exp / total)
                        q_expected = exp >> depth
                        check((x & 0xFFF, quad, rom, u(r, 14, 14), u(r, 15, 15),
                               u(r, 16, 16), u(r, 17, 17), u(r, 18, 18), u(x, 12, 15),
                               u(x, 16, 19), u(x, 20, 23), f,
                               abs(err_re) <= 1.0, abs(err_im) <= 1.0)
                              == (exp, q_expected, exp & ((1 << depth) - 1),
                                  q_expected & 1,
                                  (q_expected & 1) ^ ((q_expected >> 1) & 1),
                                  (q_expected >> 1) & 1, inv, mode, stage, length,
                                  depth, 0, True, True),
                              f'twiddle rule and quadrant for '
                              f'{(length, stage, index, mode, inv)}')

    # Radix-4 in-place DIF pass 0 of a 16-point transform: the published leg
    # twiddles of one radix-4 butterfly are W16^0, W16^1, W16^2, W16^3.
    legs = []
    for index in range(4):
        r, x, f = beat_tw(4 | (0 << 4) | (index << 8), 0, 1)
        legs.append((x & 0xFFF, u(r, 12, 13), u(r, 0, 11)))
    check([entry[0] for entry in legs] == [0, 1, 2, 3]
          and [entry[1] for entry in legs] == [0, 0, 0, 0]
          and [entry[2] for entry in legs] == [0, 1, 2, 3],
          'radix-4 pass 0 leg exponents of a 16-point DIF are W16^0..W16^3')
    for exp, quad, rom in legs:
        w = quarter_turn(quad, int(round(1024 * math.cos(2 * math.pi * rom / 16))),
                         int(round(1024 * math.sin(2 * math.pi * rom / 16))))
        check(abs(w[0] - 1024 * math.cos(2 * math.pi * exp / 16)) <= 1.0
              and abs(w[1] - 1024 * math.sin(2 * math.pi * exp / 16)) <= 1.0,
              f'radix-4 leg twiddle {exp} of 16 reconstructs to published trig')

    # A full stage of a 64-point transform: stage 0 of the Stockham schedule is
    # the identity map j -> e, and every exponent 0..N/2-1 appears exactly once,
    # which is what makes one quarter-period ROM enough.
    seen = []
    for index in range(32):
        r, x, f = beat_tw(6 | (0 << 4) | (index << 8), 0, 0)
        seen.append(x & 0xFFF)
    check(sorted(seen) == list(range(32)),
          'twiddle stage 0 of a 64-point schedule enumerates 0..31 once each')

    # Conjugate direction: e and N-e are mirror images, sin flips sign only.
    for index in (1, 5, 17, 31):
        r0, x0, _ = beat_tw(6 | (0 << 4) | (index << 8), 0, 0)
        r1, x1, _ = beat_tw(6 | (0 << 4) | (index << 8), 1, 0)
        forward = quarter_turn(u(r0, 12, 13),
                               int(round(1024 * math.cos(2 * math.pi * u(r0, 0, 11) / 64))),
                               int(round(1024 * math.sin(2 * math.pi * u(r0, 0, 11) / 64))))
        back = quarter_turn(u(r1, 12, 13),
                            int(round(1024 * math.cos(2 * math.pi * u(r1, 0, 11) / 64))),
                            int(round(1024 * math.sin(2 * math.pi * u(r1, 0, 11) / 64))))
        check((x0 & 0xFFF) + (x1 & 0xFFF) == 64
              and abs(back[0] - forward[0]) <= 1 and abs(back[1] + forward[1]) <= 1,
              f'twiddle conjugate exponent mirrors the imaginary leg at j={index}')

    for bad in ((13, 0, 0), (1, 0, 0), (6 | (6 << 4), 0, 0), (8 | (0 << 4) | (128 << 8), 0, 0),
                (7 | (0 << 4) | (0 << 8), 0, 1), (8 | (4 << 4) | (0 << 8), 0, 1),
                (8 | (0 << 4) | (64 << 8), 0, 1), (8, 2, 0), (8, 0, 1 << 31),
                (8, 0, 2), (1 << 20, 0, 0), (8, 1 << 4, 0)):
        r, x, f = beat_tw(*bad)
        check((r, x, f) == (0, 0, 1), f'twiddle malformed beat {bad} zeroes response')

    # ---------------------------------------------------------------- cordic_rotate
    beat_cd = runner('cordic_rotate')

    # The convergence table and the gain are re-derived from math.atan and
    # math.sqrt here, never read from the kernel.  Entry i is atan(2^-i) in units
    # of pi/8192, so entry 0 is exactly a quarter of 8192 = 2048 (45 deg),
    # entry 1 is 26.565 deg = 1209 counts and entry 11 rounds to 1.
    derived_tab = [int(round(math.atan(2.0 ** -i) * 8192.0 / math.pi))
                   for i in range(12)]
    check(derived_tab == CORDIC_TAB and CORDIC_TAB[0] == 2048
          and CORDIC_TAB[1] == 1209 and CORDIC_TAB[2] == 639 and CORDIC_TAB[11] == 1
          and all(CORDIC_TAB[i] > CORDIC_TAB[i + 1] for i in range(11)),
          'CORDIC atan(2^-i) table re-derived from math.atan, strictly decreasing')
    gain12 = 1.0
    for k in range(12):
        gain12 *= math.sqrt(1.0 + 4.0 ** -k)
    gain12 = 1.0
    for k in range(12):
        gain12 *= math.sqrt(1.0 + 4.0 ** -k)
    # The published limiting CORDIC gain prod sqrt(1+4^-i) = 1.6467602581; the
    # 12-term product this kernel builds is smaller by the neglected tail, which
    # is exp(4^-12/2 * 4/3) - 1 ~ 4e-8, so 1e-6 is the honest comparison.
    check(abs(gain12 - 1.6467602581) < 1e-6 and gain12 < 1.6467602581
          and abs(gain12 * 1024.0 - 1686.28) < 0.1,
          'uncompensated CORDIC gain A(12) is the published 1.64676')
    convergent = sum(derived_tab)
    check(4096 < convergent < 8192,
          'sum of the atan table covers +-90 deg so no angle needs two turns')

    def theta_field(angle):
        """b[13:0] carries the signed angle in pi/8192 units."""
        return angle & 0x3FFF

    # Hand traces, one and two micro-rotations, exact integer arithmetic:
    # (1024,0) at theta=0 -> else branch rotates by +45 deg -> (1024,1024) and
    # the residual is requested minus applied = -2048 counts.
    r, x, f = beat_cd(pair(1024, 0), theta_field(0), 1)
    check((sg(r, 0, 13), sg(r, 14, 27), sg(x, 0, 15), u(x, 16, 19), u(r, 30, 31), f)
          == (1024, 1024, -2048, 1, 0, 0), 'CORDIC one iteration is exactly +-45 deg')

    # Second iteration: tx = 1024>>1 = 512, ty = 1024>>1 = 512, residual is
    # negative so x += ty, y -= tx -> (1536, 512); z = -2048 + 1209 = -839.
    # |(1536,512)| = 1619.1 and A(2)*1024 = sqrt(2)*sqrt(5)/2*1024 = 1619.09.
    r, x, f = beat_cd(pair(1024, 0), theta_field(0), 2)
    check((sg(r, 0, 13), sg(r, 14, 27), sg(x, 0, 15), u(x, 16, 19), f)
          == (1536, 512, -839, 2, 0), 'CORDIC two iterations hand trace and gain')

    # Third iteration: tx = 1536>>2 = 384, ty = 512>>2 = 128 -> (1664, 128),
    # z = -839 + 639 = -200 counts = -4.4 deg, applied = +4.4 deg.
    r, x, f = beat_cd(pair(1024, 0), theta_field(0), 3)
    check((sg(r, 0, 13), sg(r, 14, 27), sg(x, 0, 15), u(x, 16, 19))
          == (1664, 128, -200, 3), 'CORDIC three iterations hand trace')

    # Quarter-turn pre-rotation: theta = 4097 > 4096 rotates (1024,0) to
    # (0,1024) first, then one +45 deg micro-rotation lands on (-1024,1024)
    # with residual 4097-4096-2048 = -2047 counts.
    r, x, f = beat_cd(pair(1024, 0), theta_field(4097), 1)
    check((sg(r, 0, 13), sg(r, 14, 27), sg(x, 0, 15), u(r, 30, 31), u(x, 20, 23), f)
          == (-1024, 1024, -2047, 1, 1, 0), 'CORDIC pre-rotation +90 deg hand trace')

    # And the mirror: theta = -4097 takes (1024,0) to (0,-1024) then -45 deg.
    r, x, f = beat_cd(pair(1024, 0), theta_field(-4097), 1)
    check((sg(r, 0, 13), sg(r, 14, 27), sg(x, 0, 15), u(r, 30, 31), u(x, 20, 23), f)
          == (-1024, -1024, 2047, 2, 2, 0), 'CORDIC pre-rotation -90 deg hand trace')

    # Sweep: the output vector must point where the requested angle says, within
    # the residual the kernel reports plus the integer truncation of the shifts,
    # and its length must be A(iters) times the input length.
    for (vx, vy) in ((1024, 0), (0, 1024), (724, 724), (-1000, 300), (2047, 2047)):
        for iters in (12, 8, 5):
            gain = 1.0
            for k in range(iters):
                gain *= math.sqrt(1.0 + 4.0 ** -k)
            tail = sum(derived_tab[iters:]) + 2
            for angle in list(range(-8191, 8192, 1024)) + [4096, -4096, 4097, -4097,
                                                           0, 1, -1, convergent,
                                                           -convergent]:
                if not -8192 <= angle <= 8191:
                    continue
                r, x, f = beat_cd(pair(vx, vy), theta_field(angle), iters)
                out_x, out_y = sg(r, 0, 13), sg(r, 14, 27)
                residual = sg(x, 0, 15)
                wanted = math.atan2(vy, vx) + angle * math.pi / 8192.0
                got = math.atan2(out_y, out_x)
                delta = (got - wanted + math.pi) % (2 * math.pi) - math.pi
                length = math.hypot(out_x, out_y)
                want_len = gain * math.hypot(vx, vy)
                # The reported residual is the algorithmic angle error; the
                # arithmetic shifts lose under one count per lane per step, so
                # at most sqrt(2)*12 counts of perpendicular error, i.e.
                # 17/length radians on top of the residual.
                angle_tol = (abs(residual) + 1) * math.pi / 8192.0 + 18.0 / max(length, 1.0)
                check(f == 0 and abs(delta) <= angle_tol
                      and abs(length - want_len) <= 24.0
                      and u(x, 16, 19) == iters and u(r, 30, 31) == u(x, 20, 23)
                      and (abs(angle) <= 4096 or u(r, 30, 31) in (1, 2)),
                      f'CORDIC angle and gain at {(vx, vy, angle, iters)}: '
                      f'{delta, length, want_len, residual, angle_tol}')

    # A vector on the axis must stay on the axis for a zero-angle rotation only
    # up to the CORDIC's own overshoot: with 12 iterations the residual after
    # theta=0 is one count or less, so y' is within a handful of counts of zero.
    # Greedy CORDIC leaves a residual no bigger than the angle the remaining
    # micro-rotations can still represent, sum(atan(2^-i)) for i >= iters, and
    # that tail is zero after the twelfth step: the last entry is 1 count.
    for iters in (4, 8, 12):
        tail = sum(CORDIC_TAB[iters:])
        r, x, f = beat_cd(pair(1024, 0), theta_field(0), iters)
        residual = sg(x, 0, 15)
        length = math.hypot(sg(r, 0, 13), sg(r, 14, 27))
        check(abs(residual) <= tail
              and abs(math.atan2(sg(r, 14, 27), sg(r, 0, 13)))
              <= (abs(residual) + 1) * math.pi / 8192.0 + 18.0 / length,
              f'CORDIC residual stays inside the remaining atan tail at iters={iters}')

    for bad in ((pair(1024, 0), 0, 0), (pair(1024, 0), 0, 13),
                (1 << 24, 0, 12), (0, 1 << 14, 12), (0, 0, 1 << 31),
                (0, 0, (1 << 4) | 12), (pair(0, 0), 1 << 30, 1)):
        r, x, f = beat_cd(*bad)
        check((r, x, f) == (0, 0, 1), f'CORDIC malformed beat {bad} zeroes response')

    # -------------------------------------------------------------- cmul_q15
    beat_cm = runner('cmul_q15')

    def textbook_cmul(zr, zi, wr, wi, conj):
        """Textbook complex multiply with round-half-up requantise.

        re = zr*wr - zi*wi, im = zi*wr + zr*wi, each >>10 with the +512 tie term
        and then clamped to the signed 12 sample window.  The kernel reaches the
        same answer through Gauss' three products, so agreeing bit-for-bit is
        evidence for the identity and for the slice wiring at the same time.

        Conjugation is the sign the core's own spec text promises -- "c[0]=1
        conjugates the second operand ... by negating the requantised imaginary
        leg after rounding" -- so it negates the ROUNDING RESULT.  `anti` is the
        other reading, conjugating the operand before requantising, and the two
        differ by exactly one count when the leg is an exact half: round-half-up
        is not symmetric about zero, round_shift(+512)=1 but round_shift(-512)=0.
        Keeping both here makes that encoding a tested fact instead of a guess.
        """
        pre_re = zr * wr - zi * wi
        pre_im = zi * wr + zr * wi
        r10, r_c = clamp12(round_shift(pre_re, 10))
        # The sign goes on the REQUANTISED leg, before it is clamped: the spec
        # calls the conjugate direction "a sign on the requantised imaginary
        # leg", and clamping to 2047 first and negating afterwards would turn a
        # leg whose true value was 2171 into -2047 with no flag at all, which is
        # exactly the case result[25] exists to report.
        rounded_im = round_shift(pre_im, 10)
        i10, i_c = clamp12(-rounded_im if conj else rounded_im)
        anti, anti_c = clamp12(round_shift(-pre_im, 10))
        # Gauss needs (zr+zi) and (wr+wi) inside one signed 12 slice operand.
        s_u, u_c = clamp12(zr + zi)
        s_w, w_c = clamp12(wr + wi)
        return dict(re=r10, im=i10, clip=int(r_c or i_c), u=s_u, w=s_w,
                    exact=not (u_c or w_c), anti=anti, anti_clip=int(anti_c),
                    half=pre_im % 1024 == 512)

    def naive_cmul(zr, zi, wr, wi, conj):
        """Positional view of textbook_cmul: (re, im, clip, (u, w), exact)."""
        want = textbook_cmul(zr, zi, wr, wi, conj)
        return (want['re'], want['im'], want['clip'], (want['u'], want['w']),
                want['exact'])

    def slice_cmul(zr, zi, wr, wi, conj):
        """The three-slice datapath as the registration text describes it.

        P1 = zr*wr and P2 = zi*wi are unshared slices and always exact.  P3 is
        the slice product of the SATURATED pre-adds, and the two values actually
        fed to it are what the core reports on aux[11:0] and aux[23:12].  Then
        re = P1-P2 and im = P3-P1-P2, requantised with the same +512 round and
        clamped to signed 12, the beat faulting on any of the four clips.  This
        is the reference for the whole input window, including where Gauss'
        pre-adds saturate and the beat is therefore NOT the complex product.
        """
        u_val, u_c = clamp12(zr + zi)
        w_val, w_c = clamp12(wr + wi)
        p1, p2, p3 = zr * wr, zi * wi, u_val * w_val
        re, r_c = clamp12(round_shift(p1 - p2, 10))
        # Same ordering as the generated RTL: requantise, apply the conjugate
        # sign to that rounded leg, then clamp once, so a conj leg that leaves
        # the window raises result[25] instead of silently reporting 2047-negated.
        rounded = round_shift(p3 - p1 - p2, 10)
        im, i_c = clamp12(-rounded if conj else rounded)
        flags = (r_c << 0) | (i_c << 1) | (u_c << 2) | (w_c << 3)
        return dict(re=re, im=im, u=u_val, w=w_val, flags=flags,
                    fault=int(flags != 0))

    def cmul_beat(zr, zi, wr, wi, conj):
        """One cmul beat, held to the slice reference and the fault equation."""
        ref = slice_cmul(zr, zi, wr, wi, conj)
        r, x, f = beat_cm(pair(zr, zi), pair(wr, wi), conj)
        check((sg(r, 0, 11), sg(r, 12, 23), u(r, 24, 27), f)
              == (ref['re'], ref['im'], ref['flags'], ref['fault']),
              f'cmul lanes and clamp bits match the three-slice spec at '
              f'{(zr, zi, wr, wi, conj)}')
        check((sg(x, 0, 11), sg(x, 12, 23), u(x, 24, 24), u(x, 25, 31))
              == (ref['u'], ref['w'], conj, 0),
              f'cmul aux names the pre-adds actually fed to slice P3 at '
              f'{(zr, zi, wr, wi, conj)}')
        check(u(r, 28, 31) == 0 and f == int(u(r, 24, 27) != 0),
              f'cmul fault is exactly the OR of its four clamp bits at '
              f'{(zr, zi, wr, wi, conj)}')
        return r, x, f, ref

    # Unity is exact: w = (1024,0) must return the operand bit for bit.
    for zr, zi in ((1024, 0), (0, 1024), (-2048, 2047), (724, -724), (1, -1)):
        r, x, f = beat_cm(pair(zr, zi), pair(1024, 0), 0)
        check((sg(r, 0, 11), sg(r, 12, 23), f) == (zr, zi, 0),
              f'cmul by (1024,0) is the identity map at {(zr, zi)}')
    # +j rotation: re = -zi, im = zr; conj(+j) = -j flips the imaginary leg only.
    # Gauss' third product is ONE MULT12X12 slice, so the rotation is exact for
    # every operand whose (zr+zi) fits the signed 12 window the slice is fed --
    # the core's own documented domain, "exact only while both pre-adds fit one
    # slice operand, which is what the flags report".  (2047, 2047) sums to 4094:
    # it is not a quarter-turn case, because 4094*1024 needs a 13x12 slice and
    # the beat must fault instead of claiming a rotation.  Both classes assert
    # here by name, and the unshared legs are checked to survive the clip.
    for zr, zi in ((1024, 512), (724, 724), (1, 0), (2047, 2047), (-1024, -1),
                   (1023, 1024), (-2048, 0), (1447, 600), (2047, -2048),
                   (-2047, -2047), (512, -1024), (0, -2048), (1, 1), (-1, 0),
                   (2047, 0), (-1448, -600)):
        for conj in (0, 1):
            want = textbook_cmul(zr, zi, 0, 1024, conj)
            r, x, f, _ = cmul_beat(zr, zi, 0, 1024, conj)
            if want['exact'] and zi != -2048 and not (conj and zr == -2048):
                check((sg(r, 0, 11), sg(r, 12, 23), f)
                      == (-zi, -zr if conj else zr, 0),
                      f'cmul by +/-j rotates a quarter turn at {(zr, zi, conj)}')
            elif want['exact']:
                # In-window pre-adds but a negated -2048 leg: the floor of two's
                # complement clamps, it does not wrap, and the clamp bit names
                # which leg left the window (result[24]=re, result[25]=im).
                check(f == 1 and u(r, 26, 27) == 0
                      and u(r, 24, 25) == int(zi == -2048)
                      | (int(bool(conj) and zr == -2048) << 1),
                      f'cmul by +/-j clamps the negated -2048 leg at {(zr, zi, conj)}')
            else:
                # The clipped pre-add can only corrupt P3, so the re leg, which
                # is P1-P2 and shares neither operand with the pre-adds, still
                # rotates exactly; the im leg is whatever saturated Gauss gives
                # and the beat faults on result[26].
                check(f == 1 and u(r, 26, 26) == 1 and u(r, 27, 27) == 0
                      and (sg(r, 0, 11) == -zi if zi != -2048 else u(r, 24, 24) == 1)
                      and sg(r, 12, 23) != (zr if not conj else -zr),
                      f'cmul by +/-j faults and keeps its unshared leg at '
                      f'{(zr, zi, conj)}')
    # Conjugating the second operand is a sign on the requantised leg, not a
    # second requantise: (1,0)x(0,512) has an imaginary product of exactly +512,
    # half a count, so rounding first gives +1 and negating gives -1, while
    # conjugating first and rounding half-UP gives 0.  The core does the former.
    r, x, f = beat_cm(pair(1, 0), pair(0, 512), 0)
    check((sg(r, 0, 11), sg(r, 12, 23), f) == (0, 1, 0),
          'cmul requantises the imaginary leg before conjugating it, +512 rounds up')
    r, x, f = beat_cm(pair(1, 0), pair(0, 512), 1)
    check((sg(r, 0, 11), sg(r, 12, 23), f) == (0, -1, 0),
          'cmul by conj negates that rounded leg, it does not re-round the product')
    # Negating the most negative sample is the one thing a signed 12 window
    # cannot do: -(-2048) is 2048, so the rotation clamps that leg and faults
    # instead of wrapping to -2048.  This is the floor of two's complement, not
    # a wiring mistake, and it is the reason the clamp flags exist.
    r, x, f = beat_cm(pair(-2048, 512), pair(0, 1024), 1)
    check((sg(r, 0, 11), sg(r, 12, 23), u(r, 25, 25), f) == (-512, 2047, 1, 1),
          'cmul by conj(+j) clamps the negated -2048 real leg instead of wrapping')
    r, x, f = beat_cm(pair(512, -2048), pair(0, 1024), 0)
    check((sg(r, 0, 11), sg(r, 12, 23), u(r, 24, 24), f) == (2047, 512, 1, 1),
          'cmul by +j clamps the negated -2048 imaginary leg instead of wrapping')
    # A times conj(A) is real and non-negative: the re leg carries |z|^2/1024.
    # What that identity MEANS on this core is closed-form, and it is not "any
    # integer a Python int can hold".  The lanes are signed 12, so the window is
    # [-2048, 2047]; 2048 is not a sample at all, because -(-2048) has no
    # representative, so the largest power the leg can report is 2047 and one
    # count above it the beat must clamp and raise result[24].  With w = conj(z)
    # the two unshared slices give P1 = zr*zr and P2 = -zi*zi, hence the re leg
    # is the requantised power (zr^2 + zi^2 + 512) >> 10 for EVERY input, since
    # no pre-add feeds it.  The im leg is P3-P1-P2 with P3 = u*w, u = zr+zi and
    # w = zr-zi, and difference of squares makes u*w = zr^2 - zi^2 identically
    # whenever both pre-adds fit one slice operand -- so im_pre = 0 and the leg
    # reads (0 + 512) >> 10 = 0 exactly.  The boundary pair is hand-computed:
    # 1447^2 = 2093809 requantises to (2093809+512)>>10 = 2045, the top
    # representable power, while 1448^2 = 2096704 gives (2096704+512)>>10 = 2048
    # exactly, one count past the window, so 1448 is the smallest axis magnitude
    # that saturates and its leg must read 2047 with result[24] raised.  Here
    # (1024,1024) is 2*1024^2 = 2097152 -> 2048 and (2047,2047) is
    # 2*2047^2 = 8380418 -> 8184: both are that same unrepresentable-power clamp,
    # and both also saturate u = zr+zi to 2047 while w = zr-zi is exactly 0, so
    # P3 = 0 = zr^2 - zi^2 and the imaginary leg is still zero for a second,
    # independent reason.  zi = -2048 is absent from the table and the grid only
    # because negating it is not a legal 12-bit stimulus lane.
    hand_power = (
        #   (zr, zi)  re   im rsat isat uclip wclip aux_u aux_w fault
        ((1, 1), (0, 0, 0, 0, 0, 0, 2, 0, 0)),           # 1+1+512 = 514 < 1024
        ((724, 724), (1024, 0, 0, 0, 0, 0, 1448, 0, 0)),  # 2*724^2 = 1048352
        ((300, -400), (244, 0, 0, 0, 0, 0, -100, 700, 0)),  # 250000 -> 244
        ((1023, 1), (1022, 0, 0, 0, 0, 0, 1024, 1022, 0)),  # 1046530 -> 1022
        ((1024, 724), (1536, 0, 0, 0, 0, 0, 1748, 300, 0)),  # 1572752 -> 1536
        ((-724, 724), (1024, 0, 0, 0, 0, 0, 0, -1448, 0)),  # u cancels, w doubles
        ((-1024, -1024), (2047, 0, 1, 0, 0, 0, -2048, 0, 1)),  # u = -2048 is legal
        ((1447, 0), (2045, 0, 0, 0, 0, 0, 1447, 1447, 0)),  # top power in range
        ((1448, 0), (2047, 0, 1, 0, 0, 0, 1448, 1448, 1)),  # 2048: no lane for it
        ((2047, 0), (2047, 0, 1, 0, 0, 0, 2047, 2047, 1)),  # 2047^2 -> 4092
        ((0, 2047), (2047, 0, 1, 0, 0, 0, 2047, -2047, 1)),  # same power, im leg
        ((-2048, 0), (2047, 0, 1, 0, 0, 0, -2048, -2048, 1)),  # 2048^2 -> 4096
        ((1024, 1024), (2047, 0, 1, 0, 1, 0, 2047, 0, 1)),  # 2*1024^2 -> 2048
        ((2047, 2047), (2047, 0, 1, 0, 1, 0, 2047, 0, 1)),  # 2*2047^2 -> 8184
    )
    for (zr, zi), want in hand_power:
        r, x, f = beat_cm(pair(zr, zi), pair(zr, -zi), 0)
        got = (sg(r, 0, 11), sg(r, 12, 23), u(r, 24, 24), u(r, 25, 25),
               u(r, 26, 26), u(r, 27, 27), sg(x, 0, 11), sg(x, 12, 23), f)
        check(got == want,
              f'cmul z*conj(z) against the hand-computed power table at '
              f'{(zr, zi)}: got {got} want {want}')
    # The same law stated as algebra over a grid: the re leg is the clamped power
    # everywhere (P1-P2 shares nothing with the pre-adds), each pre-add clamp bit
    # is exactly the window test on zr+/-zi, aux names the operand actually fed
    # to slice P3, and inside the window the product is exactly real and unfaulted
    # apart from that one power clamp.
    for zr in (-2048, -1448, -1024, -724, -1, 0, 1, 512, 1023, 1448, 2047):
        for zi in (-2047, -1024, -512, -1, 0, 1, 512, 724, 1024, 2047):
            power = (zr * zr + zi * zi + 512) >> 10
            u_sum, w_sum = zr + zi, zr - zi
            u_ok, w_ok = -2048 <= u_sum <= 2047, -2048 <= w_sum <= 2047
            r, x, f = beat_cm(pair(zr, zi), pair(zr, -zi), 0)
            check(sg(r, 0, 11) == min(2047, power)
                  and u(r, 24, 24) == int(power > 2047)
                  and u(r, 26, 26) == int(not u_ok)
                  and u(r, 27, 27) == int(not w_ok)
                  and sg(x, 0, 11) == min(2047, max(-2048, u_sum))
                  and sg(x, 12, 23) == min(2047, max(-2048, w_sum)),
                  f'cmul power leg and pre-add flags at {(zr, zi)}')
            if u_ok and w_ok:
                check(sg(r, 12, 23) == 0 and u(r, 25, 25) == 0
                      and f == int(power > 2047),
                      f'cmul z*conj(z) is exactly real in the in-window domain '
                      f'at {(zr, zi)}')
    # Swept two ways, split by the domain the algebra puts the beat in.  Gauss'
    # identity needs a third product P3 = (zr+zi)*(wr+wi), and both of its
    # operands are signed 12, so the moment either pre-add leaves [-2048, 2047]
    # the slice is handed a saturated operand and the beat is NOT the textbook
    # complex product -- that is the documented contract ("the identity is exact
    # only while both pre-adds fit one slice operand, which is what the flags
    # report") and the reason the flags exist.  Inside the domain the identity is
    # an exact integer equality, so both legs must equal the textbook product
    # leg for leg after round-half-up and clamping.  Outside it the re leg is
    # still exactly the textbook product, because re = P1-P2 = zr*wr - zi*wi uses
    # only the two unshared slices, and the corrupted leg is im; cmul_beat pins
    # that case to the spec's own three-slice algebra plus the aux operands and
    # the fault-is-the-OR-of-the-clamp-bits equation.
    # The flag term this replaces read `(clip & 3) | ((clip >> 2) << 2) | (clip &
    # 1) << 1`, which set result[25] (imaginary clamped) every time result[24]
    # (real clamped) was set, so it asserted a wrong encoding for every
    # single-lane saturation and hid it behind the domain error.
    for zr, zi in ((1024, 0), (0, 1024), (724, 724), (-724, 724), (512, 256),
                   (1, 1), (-2048, 1023), (2047, 2047), (-2048, -2048), (1000, -300)):
        for wr, wi in ((1024, 0), (0, 1024), (724, -724), (512, 512), (2047, 2047),
                       (-2048, -2048), (256, 512), (1023, 0), (-1, -1)):
            for conj in (0, 1):
                r, x, f, _ = cmul_beat(zr, zi, wr, wi, conj)
                re_pre = zr * wr - zi * wi
                im_pre = zi * wr + zr * wi
                re_leg = min(2047, max(-2048, (re_pre + 512) >> 10))
                im_rounded = (im_pre + 512) >> 10
                im_leg = min(2047, max(-2048, -im_rounded if conj else im_rounded))
                textbook_sat = int((re_pre + 512) >> 10 != re_leg) \
                    | int((-im_rounded if conj else im_rounded) != im_leg) << 1
                u_ok, w_ok = -2048 <= zr + zi <= 2047, -2048 <= wr + wi <= 2047
                if u_ok and w_ok:
                    check((sg(r, 0, 11), sg(r, 12, 23), u(r, 24, 27), f)
                          == (re_leg, im_leg, textbook_sat,
                              int(textbook_sat != 0))
                          and (sg(x, 0, 11), sg(x, 12, 23), u(x, 24, 24))
                          == (zr + zi, wr + wi, conj),
                          f'cmul is the textbook product inside the Gauss window '
                          f'at {(zr, zi, wr, wi, conj)}')
                    # A second, separately written transcription of the same
                    # textbook product (textbook_cmul, Gauss-free and clamp-free
                    # until the end) must land on the identical lanes, flags and
                    # aux operands; two algebraic routes agreeing is evidence for
                    # the algebra, not for either one alone.
                    check(naive_cmul(zr, zi, wr, wi, conj)
                          == (re_leg, im_leg, int(textbook_sat != 0),
                              (zr + zi, wr + wi), True),
                          f'cmul textbook transcriptions agree in the Gauss '
                          f'window at {(zr, zi, wr, wi, conj)}')
                else:
                    check(sg(r, 0, 11) == re_leg
                          and u(r, 24, 24) == int(re_leg != ((re_pre + 512) >> 10))
                          and u(r, 26, 26) == int(not u_ok)
                          and u(r, 27, 27) == int(not w_ok)
                          and f == 1 and u(r, 28, 31) == 0
                          and (sg(x, 0, 11), sg(x, 12, 23), u(x, 24, 24))
                          == (min(2047, max(-2048, zr + zi)),
                              min(2047, max(-2048, wr + wi)), conj),
                          f'cmul keeps the unshared real leg and flags the '
                          f'saturated pre-add outside the Gauss window at '
                          f'{(zr, zi, wr, wi, conj)}')
    # Gauss is only exact when neither pre-add clips; the core says so on
    # result[26]/result[27], and a clipped beat is a fault.
    r, x, f = beat_cm(pair(2047, 2047), pair(1024, 0), 0)
    check(u(r, 26, 26) == 1 and f == 1 and sg(x, 0, 11) == 2047,
          'cmul flags the clipped (zr+zi) pre-add instead of wrapping')
    r, x, f = beat_cm(pair(1024, 1024), pair(2047, 2047), 0)
    check(u(r, 27, 27) == 1 and f == 1 and sg(x, 12, 23) == 2047,
          'cmul flags the clipped (wr+wi) pre-add instead of wrapping')
    # Largest-product corner, worked out by hand because the two legs do NOT
    # behave the same way.  re = P1-P2 = 2047*2047 - (-2048*1023) = 4190209 +
    # 2095104 = 6285313, requantised (6285313+512)>>10 = 6138, far past the top
    # of the window, so the leg reads 2047 and result[24] fires.  For P3 the
    # wr+wi pre-add is 2047+1023 = 3070, which saturates to 2047 (result[27]), so
    # P3 = (2047-2048)*2047 = -2047 and P3-P1-P2 = -2047-4190209+2095104 =
    # -2097152 = -2048*1024 exactly; (-2097152+512)>>10 floors to -2048, which is
    # the BOTTOM of the signed 12 window and perfectly representable, so
    # result[25] stays clear and the leg reads -2048, not +2047.  The earlier
    # expectation of "both lanes saturate" asked for 2047 on a leg whose exact
    # value is -2048, and would have needed the clamp to wrap the floor of the
    # window; -2048 has no positive counterpart but it IS a sample.
    r, x, f, _ = cmul_beat(2047, -2048, 2047, 1023, 0)
    check(u(r, 24, 27) == 0b1001 and f == 1
          and (sg(r, 0, 11), sg(r, 12, 23)) == (2047, -2048)
          and (sg(x, 0, 11), sg(x, 12, 23), u(x, 24, 24)) == (-1, 2047, 0),
          'cmul clamps the real lane and floors the imaginary lane to -2048')
    for bad in ((1 << 24, 0, 0), (0, 1 << 24, 0), (0, 0, 1 << 31), (0, 0, 2)):
        r, x, f = beat_cm(*bad)
        check((r, x, f) == (0, 0, 1), f'cmul malformed beat {bad} zeroes response')

    # ------------------------------------------------------------- mag_approx_s12
    beat_mg = runner('mag_approx_s12')

    def naive_mag(re, im, tier):
        """Shift-add magnitude tiers, written independently of the kernel.

        The magnitudes are 12-bit two's complement abs()s, so the -2048 corner
        wraps to 0 exactly as `~q_re + 12'd1` does in 12 bits.
        """
        ar, ai = abs(re) & 0xFFF, abs(im) & 0xFFF
        hi, lo = max(ar, ai), min(ar, ai)
        tiers = (hi + (lo >> 1), hi + (lo >> 1) - (lo >> 3),
                 hi + (lo >> 2), hi + (lo >> 2) + (lo >> 4))
        return hi, lo, ar, ai, tiers, tiers[tier]

    # hi is a proven lower bound on |z| and hi+(lo>>1) a proven upper bound,
    # because (hi+lo/2)^2 = hi^2 + hi*lo + lo^2/4 >= hi^2 + lo^2.
    # Every one of these quantities is a MAGNITUDE, i.e. non-negative by
    # construction, and the spec fixes the lane's width: "result[11:0]=the tier
    # estimate (never exceeds 3070, so it is unsigned 12-representable)".  3070
    # is 2047+1023, the tier-0 ceiling for re=im=2047, and 3070 is above the top
    # of a signed 12 window, so the estimate is read with u(...) here; reading it
    # as two's complement would turn the 3070-count ceiling into -1026 and assert
    # that a magnitude is negative.  The bounds are checked as unsigned counts.
    worst_hi = worst_lo = 0.0
    small_errs = []
    for re in list(range(-2047, 2048, 137)) + [-2048, 2047, -1, 1, 0]:
        for im in list(range(-2047, 2048, 151)) + [-2048, 2047, -1, 1, 0]:
            hi, lo, ar, ai, tiers, _ = naive_mag(re, im, 0)
            true_mag = math.hypot(re, im)
            r, x, f = beat_mg(pair(re, im), 0, 0)
            # The published tier-0 rule is over the REAL half, hi + lo/2, and the
            # hardware pays floor(lo/2), so the count can sit just under |z|.
            # Squaring by hand: (hi+q)^2 >= hi^2 + lo^2 with q = lo>>1 is exactly
            # 2*hi*q + q*q >= lo*lo.  For even lo = 2m that is hi >= 3m/2, always
            # true because hi >= lo = 2m; for odd lo = 2m+1 it is 2*hi*m >=
            # 3m*m + 4m + 1, which fails for m = 0 (lo = 1 with any hi: q = 0, the
            # estimate is hi while sqrt(hi*hi+1) is above it), for m = 1 at the
            # smallest allowed hi (hi = lo = 3: estimate 4 against sqrt(18) =
            # 4.2426) and for m = 2 at hi = lo = 5 (estimate 7 against sqrt(50) =
            # 7.0711); from m = 3 it holds again.  The criterion is an if and only
            # if, so the check asserts |z| <= tiers[0] exactly where it is true
            # and the derived half-count slack where it is not.
            half_floor = lo >> 1
            is_upper_bound = 2 * hi * half_floor + half_floor ** 2 >= lo * lo
            check(u(x, 0, 11) == hi and u(x, 12, 23) == tiers[0]
                  and u(r, 0, 11) == tiers[0]
                  and hi <= true_mag <= hi + lo / 2.0
                  and (true_mag <= tiers[0] if is_upper_bound
                       else tiers[0] < true_mag <= tiers[0] + 0.5)
                  and u(r, 12, 12) == (1 if ai > ar else 0)
                  and u(r, 13, 13) == (1 if re < 0 else 0)
                  and u(r, 14, 14) == (1 if im < 0 else 0)
                  and u(r, 15, 15) == (1 if not (ar or ai) else 0)
                  and u(r, 16, 16) == (1 if ar == ai else 0)
                  and u(r, 17, 18) == 0 and u(x, 24, 24) == 1 and f == 0,
                  f'mag tier0 brackets |z| at {(re, im)}')
            for tier in (1, 2, 3):
                _, _, _, _, tiers_t, est = naive_mag(re, im, tier)
                r, x, f = beat_mg(pair(re, im), 0, tier)
                check(u(r, 0, 11) == est and u(x, 25, 26) == tier
                      and u(r, 17, 18) == tier and est <= 4095 and f == 0,
                      f'mag tier {tier} at {(re, im)}')
                if tier == 1 and true_mag and ar:
                    err = est / true_mag - 1.0
                    # Two hand-derived per-point envelopes, true at EVERY count:
                    # (a) floor(lo/2) >= floor(lo/8) for lo >= 0 (floor is
                    #     monotone and lo/2 >= lo/8), so est = hi + floor(lo/2) -
                    #     floor(lo/8) >= hi, and |z| <= sqrt(2)*hi because lo <=
                    #     hi, hence est/|z| >= 1/sqrt(2) always; equality needs
                    #     est == hi AND lo == hi, i.e. floor(lo/2) == floor(lo/8)
                    #     with lo == hi, which is only lo = hi = 1 -- the grid's
                    #     worst small-count point, whose error is exactly
                    #     1/sqrt(2) - 1 = -0.29289.
                    # (b) est <= hi + lo/2 (drop the -floor(lo/8) term and use
                    #     floor(lo/2) <= lo/2), and (hi + lo/2)/|z| is
                    #     (1 + x/2)/sqrt(1+x^2), maximal at x = 1/2 where it is
                    #     sqrt(5/4) = 1.11803, the core's own documented ceiling.
                    # The continuous half-minus-eighth rule itself is bracketed by
                    # its floor slack: floor(lo/2) >= lo/2 - 1/2 and
                    # floor(lo/8) <= lo/8 give est >= hi + 0.375*lo - 0.5, while
                    # floor(lo/2) <= lo/2 and floor(lo/8) >= lo/8 - 7/8 give
                    # est <= hi + 0.375*lo + 0.875.
                    cont = hi + 0.375 * lo
                    check(cont - 0.5 <= est <= cont + 0.875
                          and 1.0 / math.sqrt(2.0) - 1e-12 <= est / true_mag
                          <= math.sqrt(5.0 / 4.0) + 1e-12,
                          f'mag tier1 sits inside its proven envelopes at {(re, im)}')
                    if true_mag >= 1024.0:
                        # The published +/- envelope is a statement about the
                        # CONTINUOUS rule, and a one-count floor error only hides
                        # inside it at large counts: 0.5/1024 = 0.00049 low and
                        # 0.875/1024 = 0.00085 high.  Below 1024 counts the floors
                        # dominate, so those points are covered by (a) and (b)
                        # above instead of by the quoted percentages.
                        worst_hi = max(worst_hi, err)
                        worst_lo = min(worst_lo, err)
                    else:
                        small_errs.append(err)
    # Tier 1 is the classic half-minus-eighth rule.  Its error is a function of
    # x = lo/hi only: (1 + 0.375x)/sqrt(1+x^2) - 1, which is derived here from
    # that closed form rather than measured -- +6.82% at x = 0.375 and -2.77% at
    # x = 1 (45 deg), 0 at x = 0.
    analytic = max((1.0 + 0.375 * x) / math.sqrt(1.0 + x * x)
                   for x in (i / 8000.0 for i in range(8001)))
    check(abs(analytic - 1.0682) < 5e-4
          and abs(1.375 / math.sqrt(2.0) - 1.0 + 0.0277) < 5e-4,
          f'mag tier1 published extremes +6.8%/-2.8% re-derived ({analytic:.5f})')
    check(-0.0285 <= worst_lo <= -0.027 and 0.065 <= worst_hi <= 0.0685,
          f'mag tier1 large-count grid error (|z| >= 1024) stays inside and '
          f'touches the analytic envelope ({worst_hi:.5f}, {worst_lo:.5f})')
    # The small-count half of the grid is NOT described by the quoted percentages,
    # and saying so is a check, not an excuse: est >= hi >= |z|/sqrt(2) with
    # equality only at hi = lo = 1, so the worst error anywhere is exactly
    # 1/sqrt(2) - 1, reached by the (1,1) corner (est = 1 + floor(1/2) - floor(1/8)
    # = 1 against |z| = sqrt(2)) and by nothing else.  Checked against that closed
    # form, and against the proven ceiling sqrt(5/4) - 1 = +11.8%.
    check(abs(min(small_errs) - (1.0 / math.sqrt(2.0) - 1.0)) < 1e-9
          and max(small_errs) <= math.sqrt(5.0 / 4.0) - 1.0 + 1e-9,
          f'mag tier1 small-count extreme is exactly 1/sqrt(2)-1 '
          f'({min(small_errs):.6f} vs {1.0 / math.sqrt(2.0) - 1.0:.6f})')
    # Pin the two analytic endpoints on hardware counts: lo/hi = 768/2048 is
    # nearest to 0.375 and 45 deg is exactly representable.
    hi, lo, ar, ai, tiers, est = naive_mag(2047, 768, 1)
    r, x, f = beat_mg(pair(2047, 768), 0, 1)
    check(est == 2047 + 384 - 96 and u(r, 0, 11) == est
          and abs(est / math.hypot(2047, 768) - analytic) < 2e-3,
          'mag tier1 near lo/hi=0.375 reproduces the +6.8% overestimate')
    r, x, f = beat_mg(pair(1024, 1024), 0, 1)
    check(u(r, 0, 11) == 1408 and abs(1408 / (1024 * math.sqrt(2.0))
                                      - 1.375 / math.sqrt(2.0)) < 1e-12,
          'mag tier1 at 45 deg is exactly the analytic -2.8% estimate 1408')
    # The -2048 corner is a magnitude the lane CAN hold, and the earlier claim
    # that it wrapped to zero is simply wrong arithmetic: the RTL negates in a
    # 12-bit UNSIGNED lane (`q_ar = q_re[11] ? (~q_re + 12'd1) : q_re`), so
    # ~0x800 + 1 = 0x800 = 2048, which IS |z| because 2048 <= 4095, the top of
    # unsigned 12.  Only a signed 12 lane would lose it, and result[11:0] is
    # unsigned by the spec.  Hence hi = 2048, the tier-0 estimate is
    # 2048 + (0 >> 1) = 2048 exactly, result[13] (re negative) is 1, and neither
    # result[15] (zero input) nor result[16] (|re| == |im|, here 2048 against 0)
    # may be set -- the two flags that would have been wrong had the magnitude
    # really vanished to zero.
    r, x, f = beat_mg(pair(-2048, 0), 0, 0)
    check((u(r, 0, 11), u(x, 0, 11), u(r, 13, 13), u(r, 15, 16), f)
          == (2048, 2048, 1, 0b00, 0),
          'mag holds the -2048 magnitude as unsigned 2048 in 12 bits')
    # True ceilings over the whole input set: hi = lo = 2048 at the both-negative
    # corner gives 2048 + 1024 = 3072, and hi = lo = 2047 gives 2047 + 1023 =
    # 3070; both are under the unsigned 12 ceiling of 4095, so the out-of-range
    # fault can never fire.
    r, x, f = beat_mg(pair(-2047, 2047), 0, 0)
    check(u(r, 0, 11) == 3070 and u(x, 24, 24) == 1 and f == 0 and u(r, 16, 16) == 1,
          'mag 3070 counts stays inside the unsigned 12 lane')
    r, x, f = beat_mg(pair(-2048, -2048), 0, 0)
    check(u(r, 0, 11) == 3072 and u(x, 0, 11) == 2048 and u(x, 12, 23) == 3072
          and u(r, 13, 14) == 0b11 and u(r, 15, 16) == 0b10 and f == 0,
          'mag true ceiling 3072 counts at the both -2048 corner')
    # hi is also handed out on aux so a downstream log can use the lower bound.
    for re, im in ((300, 400), (0, 2047), (-1, -1), (1024, 1024)):
        r, x, f = beat_mg(pair(re, im), 0, 2)
        check(u(x, 0, 11) == max(abs(re), abs(im)) and u(r, 0, 11) % (1 << 12)
              == max(abs(re), abs(im)) + (min(abs(re), abs(im)) >> 2),
              f'mag tier2 and the aux bounds at {(re, im)}')
    for bad in ((0, 0, 4), (0, 0, 1 << 31), (1 << 24, 0, 0), (0, 1, 0),
                (0, 0, 1 << 4), (0, 1 << 8, 0)):
        r, x, f = beat_mg(*bad)
        check((r, x, f) == (0, 0, 1), f'mag malformed beat {bad} zeroes response')

    # __CONTINUE__
    return checks


# __APPEND__
