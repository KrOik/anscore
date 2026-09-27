"""Sensor-interface and estimation accelerators: protocol timing, framing and
one-sample filters, all decided in one combinational cone.

This family is where FPGA I/O logic genuinely wins. A bit-banged CPU loop sees a
protocol edge only as accurately as its interrupt latency and its polling
period; here every accepted beat is one nanosecond-granular timing decision, one
bit-level CRC or framing fold, or one estimation-filter update with exactly one
sample of latency:

    * protocol timing at 125 ns / 1 us tick granularity (WS2812 T0H/T1H duty,
      1-Wire slot and presence windows, DMX512 break/MAB, Manchester
      mid-period legality) decided by parallel compare trees instead of a timer
      ISR,
    * bit-level CRC and framing (CRC-16/MODBUS four bytes per beat through a
      derived GF(2) XOR matrix, 8N1 slot assembly, quadrature legality tables)
      decided by XOR and lookup fan-in instead of a shift loop,
    * one-sample-latency estimation filters (Mahony cross-product AHRS,
      steady-state scalar and constant-velocity Kalman forms, cell-averaging
      CFAR) that publish their result on the same enabled edge that consumes
      the sample.

Ten cores, each specified twice: as Verilog statements below and as a pure
integer Python model in step(). The two specifications are deliberately
different algorithms for the same function -- the CRC RTL folds each byte
bit-serially through the 16-stage register while the model XORs a derived GF(2)
column matrix and the selftest re-derives the same value from non-reflected
0x8005 bit-by-bit division, the Kalman and AHRS models run fixed-gain integer
recursions while the selftest runs an exact rational Riccati iteration and a
floating complementary filter, the CFAR model sums with a plain loop while the
RTL masks an adder tree -- so a shared bug surfaces as a vector mismatch
instead of passing silently.

Contract used by every core in this file (see generate_lib.RTL):
    inputs  a, b, c                  32 bit, one accepted beat
    outputs result, aux (r, x), fault
    state   state_r -> state_n       256 bit, only accepted beats commit it
    restart/config beat convention:  c[31] = 1

Template body vocabulary, re-initialised on every evaluation:
    r x f temp mask pa pb pc ph pl ext wide wide2 swide swide2 sa sb sc data
    i j idx lane sh state_r state_n
Everything else comes from `decl`, which lives at module scope and is NOT
re-initialised by the template, so every body writes each of its own decl regs
unconditionally before the branch that reads them: no decl reg can become a
latch and none can carry a stale value into the next evaluation.

Three cores spend the allowed hard multipliers (mahony_ahrs two slices for the
cross product, kalman1d one, kalman2d_cv two); the other seven are
product-free and use only shift/add/compare/XOR, so no divider or barrel
multiplier appears anywhere in this family.
"""
from math import sin, pi, atan2
from fractions import Fraction
from random import Random
import re

FAMILY = 'sensing'
MASK = (1 << 32) - 1
MODEL = 'sim/mult12x12_model.v'

CORES = []

# Every name a template body may use without declaring it in `decl`.
VOCAB = {'r', 'x', 'f', 'temp', 'mask', 'pa', 'pb', 'pc', 'ph', 'pl', 'ext',
         'wide', 'wide2', 'swide', 'swide2', 'sa', 'sb', 'sc', 'data',
         'i', 'j', 'idx', 'lane', 'sh', 'state_r', 'state_n', 'a', 'b', 'c'}
KEYWORDS = {'begin', 'end', 'if', 'else', 'for', 'while', 'case', 'default',
            'posedge', 'negedge', 'input', 'output', 'reg', 'wire', 'signed',
            'function', 'endfunction', 'localparam', 'integer', 'module',
            'endmodule', 'generate', 'endgenerate'}
NUM_LIT = re.compile(r"\d*'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ]+")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def strip_comments(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def names_used(body):
    """Identifier tokens of a body, numeric literals removed."""
    return set(IDENT.findall(NUM_LIT.sub(' ', strip_comments(body))))


def core(name, spec, body, advantage, lanes, decl='', stateful=False,
         faultless=False, slices=0):
    assert 0 <= slices <= 2, f'{name}: at most two MULT12X12 slices per core'
    assert decl.count('MULT12X12 u_') == slices, f'{name}: slice/decl mismatch'
    undeclared = sorted(t for t in names_used(body)
                        if t not in KEYWORDS and t not in VOCAB and t not in decl)
    assert not undeclared, f'{name}: body uses names absent from decl: {undeclared}'
    entry = dict(name=name, family=FAMILY, spec=spec, body=body, decl=decl,
                 advantage=advantage, lanes=lanes, stateful=stateful,
                 faultless=faultless)
    if slices:
        entry['sim_extra'] = [MODEL]
    CORES.append(entry)


def slice_decl(out, xa, xb):
    """One combinational MULT12X12: `out` is the signed 24-bit product."""
    return (f'wire [23:0] {out}_raw;\n'
            f'wire signed [23:0] {out} = $signed({out}_raw);\n'
            f'MULT12X12 u_{out} (.DOUT({out}_raw), .A({xa}), .B({xb}), '
            f".CLK(2'b00), .CE(2'b00), .RESET(2'b00));\n")


def hexs(value, digits=8):
    return format(value, f'0{digits}X')


HELPERS = """
function [5:0] pc32;                        // popcount, pairwise half adds
    input [31:0] v;
    reg [31:0] t;
    begin
        t = (v & 32'h55555555) + ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t & 32'h0F0F0F0F) + ((t >> 4) & 32'h0F0F0F0F);
        // The byte fold has to be two sequential half-adds.  Written as one
        // parallel sum t + (t>>8) + (t>>16) the bit 31:24 group lands in byte 1
        // instead of byte 0, so every popcount silently lost its top byte.
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] lo32;                        // index of the lowest set bit, 32 if 0
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        n = 6'd32;
        if (v != 32'd0) begin
            t = v; n = 6'd0;
            if ((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
            if ((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
            if ((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
            if ((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
            if ((t & 32'h00000001) == 32'd0) begin n = n + 6'd1; end
        end
        lo32 = n;
    end
endfunction

function [15:0] sat16;                      // saturating 16-bit unsigned add
    input [15:0] p, q;
    reg [16:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat16 = (t > 17'hFFFF) ? 16'hFFFF : t[15:0];
    end
endfunction

function [7:0] sat8;                        // saturating 8-bit unsigned add
    input [7:0] p, q;
    reg [8:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat8 = (t > 9'hFF) ? 8'hFF : t[7:0];
    end
endfunction

function [7:0] nsym;                        // ticks to symbols, saturated at 255
    input [15:0] ticks;
    input [5:0] sh;
    reg [15:0] t;
    begin
        t = ticks >> sh;
        nsym = (t > 16'd255) ? 8'hFF : t[7:0];
    end
endfunction

function [3:0] nlog2;                       // log2 of 2,4,8,16; 0 for anything else
    input [5:0] n;
    begin
        case (n)
            6'd2:  nlog2 = 4'd1;
            6'd4:  nlog2 = 4'd2;
            6'd8:  nlog2 = 4'd3;
            6'd16: nlog2 = 4'd4;
            default: nlog2 = 4'd0;
        endcase
    end
endfunction
"""


# ===========================================================================
# 1  Mahony complementary AHRS update (2 hard slices)
# ===========================================================================
# The reference gravity direction is read from a 64-point sine grid instead of
# being rotated out of a quaternion, so both slices go into the cross product
# and the fusion gains stay binary-scaled (2^-PS, 2^-QS).
SIN_TAB = [int(round(2047 * sin(2 * pi * k / 64))) for k in range(64)]


def sin_decl():
    lines = ['function [11:0] sin11;                    // Q11 sine, 5.625 degree grid',
             '    input [5:0] k;', '    begin', '        case (k)']
    for index, value in enumerate(SIN_TAB):
        # `12'sd-201` is not legal Verilog: the sign has to sit in front of the
        # sized literal, so the lower half of the grid reads as -12'sd<n>.
        sign = '-' if value < 0 else ''
        lines.append(f"            6'd{index}: sin11 = {sign}12'sd{abs(value)};")
    lines += ['        endcase', '    end', 'endfunction']
    return '\n'.join(lines) + '\n'


MAHONY_DECL = HELPERS + sin_decl() + """
reg signed [11:0] mah_ah, mah_gv, mav_av, mav_gh;
reg [5:0] msid;
wire [11:0] mgh = sin11(msid);
wire [11:0] mgv = sin11(msid + 6'd16);
reg [3:0] mps, mis, mqs;
reg signed [63:0] mer, mdp, mdi, md, msum;
reg signed [31:0] micur, minew;
reg [15:0] mroll, mpitch, mth, mthn, miother;
reg mplane, mis_s, mds_s, mwrap, mzerog;
""" + slice_decl('mah_p1', 'mah_ah', 'mah_gv') + \
    slice_decl('mah_p2', 'mav_av', 'mav_gh')

core('mahony_ahrs',
    'One Mahony complementary-filter update per accepted beat, alternating the '
    'roll plane (plane pointer 0) and the pitch plane (pointer 1). Angles are '
    'modular 16-bit words with one full turn at 65536 (0.0055 degree per LSB). '
    'a[11:0]=a_h and a[23:12]=a_v are the signed Q11 accelerometer components '
    'of that plane (2047 = 1 g), a[31:24] must be zero. b[15:0]=the gyro '
    'delta-angle word for this sample in the same angle units, b[31:16] must be '
    'zero. c[3:0]=PS, c[7:4]=IS, c[11:8]=QS are binary-scaled gains, c[15:12] '
    'and c[29:16] must be zero. c[31]=1 clears both integrators, both angles, '
    'the plane pointer and both counters before this beat; c[31]=1 with '
    'c[30]=1 is an align beat that loads both angles from b[15:0], clears the '
    'integrators and the plane pointer, keeps the counters and runs no fusion. '
    'The error is the cross-product term e = a_h*cos(th) - a_v*sin(th) with '
    '(sin,cos) read from the 64-point Q11 grid at th[15:10], so e = '
    '|a|*2047*sin(th_true-th) and e is exactly zero when the estimate already '
    'points along the measured gravity. I := clamp16(I + (e>>>IS)), '
    'd = clamp24((e>>>PS) + (I>>>QS)), th := (th + b[15:0] + d) mod 65536. A '
    'zero alignment vector (a_h=a_v=0) forces d=0, leaves I held and faults. '
    'result[15:0]=roll, result[31:16]=pitch after this beat. aux[11:0]=(e>>>11) '
    'the normalised error, aux[12]=restart or align applied, aux[13]=zero '
    'vector rejected, aux[14]=integrator clamped, aux[15]=correction clamped, '
    'aux[16]=the angle sum left 0..65535 before the modulo, aux[17]=the plane '
    'updated, aux[19:18]=0, aux[31:20]=d[11:0]. State: roll state[15:0], pitch '
    'state[31:16], integrators state[47:32] and state[63:48] signed 16, plane '
    'pointer state[64], saturating fusion counter state[79:72] and saturating '
    'fault counter state[87:80]. A bit that must be zero and is not is a '
    'malformed beat: result=aux=0, fault=1, state kept.',
    """
mah_ah=12'sd0; mah_gv=12'sd0; mav_av=12'sd0; mav_gh=12'sd0; msid=6'd0;
mps=c[3:0]; mis=c[7:4]; mqs=c[11:8];
mer=64'sd0; mdp=64'sd0; mdi=64'sd0; md=64'sd0; msum=64'sd0;
micur=32'sd0; minew=32'sd0;
mroll=16'd0; mpitch=16'd0; mth=16'd0; mthn=16'd0; miother=16'd0;
mplane=1'b0; mis_s=1'b0; mds_s=1'b0; mwrap=1'b0; mzerog=1'b0;
if (a[31:24] != 0 || b[31:16] != 0 || c[15:12] != 0 || c[29:16] != 0) begin
    f = 1'b1;
end else if (c[31] && c[30]) begin
    r = {b[15:0], b[15:0]};
    x[12] = 1'b1;
    state_n[15:0] = b[15:0]; state_n[31:16] = b[15:0];
    state_n[47:32] = 16'd0;  state_n[63:48] = 16'd0; state_n[64] = 1'b0;
end else begin
    mah_ah = a[11:0]; mav_av = a[23:12];
    mplane = c[31] ? 1'b0 : state_r[64];
    mroll  = c[31] ? 16'd0 : state_r[15:0];
    mpitch = c[31] ? 16'd0 : state_r[31:16];
    mth    = mplane ? mpitch : mroll;
    msid   = mth[15:10];
    mah_gv = mgv;    mav_gh = mgh;
    mzerog = (a[11:0] == 12'sd0) && (a[23:12] == 12'sd0);
    micur  = c[31] ? 32'sd0
           : (mplane ? $signed(state_r[63:48]) : $signed(state_r[47:32]));
    miother = c[31] ? 16'd0
           : (mplane ? state_r[47:32] : state_r[63:48]);
    mer = mah_p1 - mah_p2;
    minew = micur;
    if (mzerog) begin
        f = 1'b1;
    end else begin
        mdp = mer >>> mps;
        minew = micur + (mer >>> mis);
        if (minew > 32'sd32767) begin minew = 32'sd32767; mis_s = 1'b1; end
        else if (minew < -32'sd32768) begin minew = -32'sd32768; mis_s = 1'b1; end
        mdi = minew >>> mqs;
        md = mdp + mdi;
    end
    if (md > 64'sd8388607) begin md = 64'sd8388607; mds_s = 1'b1; end
    else if (md < -64'sd8388608) begin md = -64'sd8388608; mds_s = 1'b1; end
    if (mis_s || mds_s) f = 1'b1;
    msum = $signed({48'd0, mth}) + $signed({48'd0, b[15:0]}) + md;
    mwrap = (msum < 64'sd0) || (msum > 64'sd65535);
    mthn = msum[15:0];
    r = mplane ? {mthn, mroll} : {mpitch, mthn};
    x[11:0] = mer >>> 11;
    x[12] = c[31];
    x[13] = mzerog;
    x[14] = mis_s;
    x[15] = mds_s;
    x[16] = mwrap;
    x[17] = mplane;
    x[31:20] = md[11:0];
    state_n[15:0]  = mplane ? mroll  : mthn;
    state_n[31:16] = mplane ? mthn   : mpitch;
    state_n[47:32] = mplane ? miother : minew[15:0];
    state_n[63:48] = mplane ? minew[15:0] : miother;
    state_n[64] = ~mplane;
    state_n[79:72] = sat8(c[31] ? 8'd0 : state_r[79:72], 8'd1);
    state_n[87:80] = sat8(c[31] ? 8'd0 : state_r[87:80],
                          {7'd0, (mzerog || mis_s || mds_s)});
end
""",
    'Two hard slices, a table read and a handful of binary-scaled adds retire a '
    'whole Mahony update on the enabled edge that consumes the accelerometer '
    'sample, where a CPU pays a floating atan2 and an integrator loop whose '
    'sample spacing jitters with every other interrupt.', 1,
    decl=MAHONY_DECL, stateful=True, slices=2)


# ===========================================================================
# 2  Steady-state scalar Kalman filter (1 hard slice)
# ===========================================================================
KALMAN1_DECL = HELPERS + """
reg [11:0] kla_k, kla_q;
reg signed [31:0] klx, klz, klr, klc, klv, klvn, klad, klcorr, klfull;
reg klxs, klvs, klgj, klpp, klcf;
""" + slice_decl('klp', 'kla_k', 'kla_q')

core('kalman1d',
    'Steady-state (fixed-gain) scalar Kalman filter, one update per accepted '
    'beat. The state and the measurement are signed 12-bit words; the '
    'prediction model is the identity plus no input, so predict leaves x and '
    'only the update moves it. The gain is the precomputed steady-state value '
    'K/4096 held in state, which keeps the whole cone to one 12x12 product: '
    'r = z - x, correction = round_half_up(K*r / 4096), x := clamp12(x + '
    'correction). Variance bookkeeping is the innovation-scale EWMA '
    'V := clamp12u(V + ((|r| - V) >>> 3)), which is the quantity the optional '
    'innovation gate uses. a[11:0]=z signed, a[31:12] must be zero. b[11:0]=the '
    'gain K (1..2047, i.e. a steady-state gain below 1/2) read only on a '
    'restart beat, b[31:12] must be zero. c[3:0]=G the gate exponent, c[29]=1 '
    'enables the gate, c[30]=1 makes this a predict-only beat that consumes the '
    'measurement as nothing, c[31]=1 is the restart/config beat which loads K, '
    'zeroes x and V and clears the counters. c[28:4] must be zero. A restart '
    'with K=0 or K>2047 is rejected (fault, state kept and unconfigured), and a '
    'normal beat before any successful restart faults with result=aux=0 and '
    'state kept. The gate rejects a measurement when |r| > V + (V>>>G) + 1: x, '
    'V and the EWMA are then held and the beat faults. result = x after the '
    'beat, sign-extended to 32 bits. aux[12:0]=r (13-bit two-complement field), '
    'aux[24:13]=V, aux[25]=x clamped, aux[26]=gate rejected, aux[27]=predict '
    'only, aux[28]=V clamped, aux[29]=restart applied, aux[31:30]=0. State: x '
    'state[11:0] signed, K state[23:12], V state[35:24], configured '
    'state[36], saturating gate-reject count state[44:37], saturating update '
    'count state[52:45], saturating clamp count state[60:53].',
    """
kla_k=12'd0; kla_q=12'd0;
klx=32'sd0; klz=32'sd0; klr=32'sd0; klc=32'sd0; klv=32'sd0; klvn=32'sd0;
klad=32'sd0; klcorr=32'sd0; klfull=32'sd0;
klxs=1'b0; klvs=1'b0; klgj=1'b0; klpp=1'b0; klcf=1'b0;
if (a[31:12] != 0 || b[31:12] != 0 || c[28:4] != 0) begin
    f = 1'b1;
end else if (c[31]) begin
    if (b[11:0] == 12'd0 || b[11:0] > 12'h7FF) begin
        f = 1'b1;
    end else begin
        klcf = 1'b1;
        state_n[23:12] = b[11:0];
        state_n[11:0] = 12'd0;   state_n[35:24] = 12'd0; state_n[36] = 1'b1;
        state_n[44:37] = 8'd0;   state_n[52:45] = 8'd0;  state_n[60:53] = 8'd0;
        x[29] = 1'b1;
    end
end else if (!state_r[36]) begin
    f = 1'b1;
end else begin
    klc = $signed(state_r[23:12]);
    klv = $signed({4'd0, state_r[35:24]});
    klx = $signed(state_r[11:0]);
    klz = $signed(a[11:0]);
    if (c[30]) begin
        klpp = 1'b1;
        klr = 32'sd0;
    end else begin
        klr = klz - klx;
        klad = klr[31] ? -klr : klr;
        if (c[29] && (klad > (klv + (klv >>> c[3:0]) + 32'sd1))) begin
            klgj = 1'b1; f = 1'b1;
            state_n[44:37] = sat8(state_r[44:37], 8'd1);
        end else begin
            kla_k = klc[11:0]; kla_q = klr >>> 1;
            klfull = (klp <<< 1) + (klr[0] ? klc : 32'sd0);
            klcorr = (klfull + 32'sd2048) >>> 12;
            klx = klx + klcorr;
            if (klx > 32'sd2047) begin klx = 32'sd2047; klxs = 1'b1; end
            else if (klx < -32'sd2048) begin klx = -32'sd2048; klxs = 1'b1; end
            if (klxs) f = 1'b1;
            klvn = klv + ((klad - klv) >>> 3);
            if (klvn > 32'sd4095) begin klvn = 32'sd4095; klvs = 1'b1; end
            else if (klvn < 32'sd0) begin klvn = 32'sd0; klvs = 1'b1; end
            if (klvs) f = 1'b1;
            state_n[11:0] = klx[11:0];
            state_n[35:24] = klvn[11:0];
            state_n[52:45] = sat8(state_r[52:45], 8'd1);
            state_n[60:53] = sat8(state_r[60:53], {7'd0, (klxs || klvs)});
        end
    end
    r = {{20{klx[31]}}, klx[11:0]};
    x[12:0] = klr;
    x[24:13] = (klpp || klgj) ? state_r[35:24] : klvn[11:0];
    x[25] = klxs;  x[26] = klgj;  x[27] = klpp;  x[28] = klvs;
    state_n[23:12] = klc[11:0];
    state_n[36] = 1'b1;
end
""",
    'One product and two shift-adds close the steady-state update on the same '
    'enabled edge the sample arrives, so the estimate never waits on a '
    'multiply-accumulate loop or a floating divide the way the textbook '
    'time-varying gain recursion does.', 1,
    decl=KALMAN1_DECL, stateful=True, slices=1)


# ===========================================================================
# 3  Constant-velocity tracker with a fixed steady-state gain matrix (2 slices)
# ===========================================================================
KALMAN2_DECL = HELPERS + """
reg [11:0] k2a_p, k2a_v;
reg signed [31:0] k2pos, k2vel, k2pp, k2pv, k2r, k2rad, k2cp, k2cv, k2fp, k2fv;
reg signed [11:0] k2gp, k2gv;
reg [12:0] k2maxr;
reg k2ps, k2vs, k2ds, k2cf, k2md;
""" + slice_decl('k2sp', 'k2gp', 'k2a_p') + slice_decl('k2sv', 'k2gv', 'k2a_v')

core('kalman2d_cv',
    'Constant-velocity tracker (pos, vel) with a FIXED steady-state gain matrix, '
    'so a beat costs two 12x12 products instead of a 2x2 matrix inversion. The '
    'four gain words are the two columns of K = P*H^T (H P H^T + R)^-1 for a '
    'position measurement (K11,K21) and a velocity measurement (K12,K22); the '
    'per-beat mode selects the column, so exactly two gains multiply. Predict '
    'is pos := clamp12(pos + vel), vel held; the residual r is (z - predicted '
    'pos) in mode 0 or (w - vel) in mode 1; the update is pos := clamp12(pos + '
    'round_half_up(Kp*r/4096)) and vel := clamp12(vel + '
    'round_half_up(Kv*r/4096)). a[11:0]=z signed position measurement, '
    'a[23:12]=w signed velocity measurement, a[31:24] must be zero. On the '
    'restart beat b[11:0]=K11, b[23:12]=K21, c[11:0]=K12, c[23:12]=K22, all '
    '1..2047, and b[31:24] and c[29:24] must be zero. c[31]=1 is the config '
    'beat which loads the four gains, zeroes pos, vel, the residual history and '
    'the counters, and performs no update; a config beat with any gain 0 or '
    'above 2047, or with a must-be-zero bit set, is rejected with the filter '
    'left unconfigured. A normal beat before a successful config faults with '
    'result=aux=0 and state kept. c[30]=1 selects the velocity-measurement '
    'column (and is don\'t-care together with c[31]); c[23:12] is ignored on '
    'normal beats. result[11:0]=pos, result[23:12]=vel (both signed), '
    'result[31:24]=0. aux[12:0]=r, aux[13]=prediction clamped, aux[14]=pos '
    'clamped, aux[15]=vel clamped, aux[16]=mode, aux[17]=config applied, '
    'aux[30:18]=the largest |r| seen since the config, aux[31]=0. State: pos '
    'state[11:0], vel state[23:12], K11 state[35:24], K21 state[47:36], K12 '
    'state[59:48], K22 state[71:60], configured state[72], last residual '
    'state[85:73], max |r| state[98:86], saturating update count state[106:99], '
    'saturating clamp count state[114:107].',
    """
k2a_p=12'd0; k2a_v=12'd0; k2gp=12'd0; k2gv=12'd0;
k2pos=32'sd0; k2vel=32'sd0; k2pp=32'sd0; k2pv=32'sd0; k2r=32'sd0; k2rad=32'sd0;
k2cp=32'sd0; k2cv=32'sd0; k2fp=32'sd0; k2fv=32'sd0;
k2maxr=13'd0; k2ps=1'b0; k2vs=1'b0; k2ds=1'b0; k2cf=1'b0; k2md=1'b0;
if (a[31:24] != 0 || b[31:24] != 0 || c[29:24] != 0) begin
    f = 1'b1;
end else if (c[31]) begin
    if (b[11:0] == 0 || b[23:12] == 0 || c[11:0] == 0 || c[23:12] == 0
        || b[11:0] > 12'h7FF || b[23:12] > 12'h7FF
        || c[11:0] > 12'h7FF || c[23:12] > 12'h7FF) begin
        f = 1'b1;
    end else begin
        k2cf = 1'b1;
        state_n[11:0] = 12'd0;  state_n[23:12] = 12'd0;
        state_n[35:24] = b[11:0];   state_n[47:36] = b[23:12];
        state_n[59:48] = c[11:0];   state_n[71:60] = c[23:12];
        state_n[72] = 1'b1;
        state_n[85:73] = 13'd0;  state_n[98:86] = 13'd0;
        state_n[106:99] = 8'd0;  state_n[114:107] = 8'd0;
        x[17] = 1'b1;
    end
end else if (!state_r[72]) begin
    f = 1'b1;
end else begin
    k2md = c[30];
    k2pos = $signed(state_r[11:0]);
    k2vel = $signed(state_r[23:12]);
    k2pp = k2pos + k2vel;
    if (k2pp > 32'sd2047) begin k2pp = 32'sd2047; k2ds = 1'b1; end
    else if (k2pp < -32'sd2048) begin k2pp = -32'sd2048; k2ds = 1'b1; end
    k2r = (k2md ? ($signed(a[23:12]) - k2vel) : ($signed(a[11:0]) - k2pp));
    k2gp = k2md ? $signed(state_r[59:48]) : $signed(state_r[35:24]);
    k2gv = k2md ? $signed(state_r[71:60]) : $signed(state_r[47:36]);
    k2a_p = k2r >>> 1;  k2a_v = k2r >>> 1;
    k2fp = (k2sp <<< 1) + (k2r[0] ? k2gp : 32'sd0);
    k2fv = (k2sv <<< 1) + (k2r[0] ? k2gv : 32'sd0);
    k2cp = (k2fp + 32'sd2048) >>> 12;
    k2cv = (k2fv + 32'sd2048) >>> 12;
    k2pos = k2pp + k2cp;
    if (k2pos > 32'sd2047) begin k2pos = 32'sd2047; k2ps = 1'b1; end
    else if (k2pos < -32'sd2048) begin k2pos = -32'sd2048; k2ps = 1'b1; end
    k2pv = k2vel + k2cv;
    if (k2pv > 32'sd2047) begin k2pv = 32'sd2047; k2vs = 1'b1; end
    else if (k2pv < -32'sd2048) begin k2pv = -32'sd2048; k2vs = 1'b1; end
    if (k2ps || k2vs || k2ds) f = 1'b1;
    k2rad = k2r[31] ? -k2r : k2r;
    k2maxr = state_r[98:86];
    if (k2rad > $signed({19'd0, k2maxr})) k2maxr = k2rad[12:0];
    r = {8'd0, k2pv[11:0], k2pos[11:0]};
    x[12:0] = k2r;
    x[13] = k2ds;  x[14] = k2ps;  x[15] = k2vs;
    x[16] = k2md;  x[17] = 1'b0;
    x[30:18] = k2maxr;
    state_n[11:0] = k2pos[11:0];
    state_n[23:12] = k2pv[11:0];
    state_n[85:73] = k2r[12:0];
    state_n[98:86] = k2maxr;
    state_n[106:99] = sat8(state_r[106:99], 8'd1);
    state_n[114:107] = sat8(state_r[114:107], {7'd0, (k2ps || k2vs || k2ds)});
end
""",
    'A two-state tracker update is two hard products and four saturating adds, '
    'so position and velocity come out one sample after the measurement '
    'instead of after a matrix multiply and a division a soft loop would run '
    'every sample.', 1,
    decl=KALMAN2_DECL, stateful=True, slices=2)


# ===========================================================================
# 4  Cell-averaging CFAR / correlator step
# ===========================================================================
CA_DECL = HELPERS + """
wire [127:0] cslide = {a, state_r[127:32]};
reg [15:0] ccut, cthr, cmean;
reg [19:0] csum;
reg [5:0] cn;
reg [3:0] clg;
reg cguard, cpow, chit, cmiss, ccut_hi;
reg [7:0] chitc, cmissc, cinvc, cbeatc;
"""

core('ca_correlator',
    'Cell-averaging CFAR detector step over a 16-cell sliding reference window, '
    'four unsigned 8-bit magnitude cells entering per accepted beat (a[7:0] '
    'first, a[31:24] last) and the decision taken on the window as held before '
    'the slide. The noise sum is the masked adder tree over state[127:0], cell i '
    'at state[8i+7:8i] with cell 0 the oldest; the 16-bit reference mask is '
    'c[19:4] and guard cells are simply excluded from it, so the divide by the '
    'cell count N is a shift and N must be a power of two. c[3:0]=the cell under '
    'test index (0..15), c[22:20]=the attenuation shift AT so '
    'threshold = mean + (mean>>>AT) + offset, c[30:23] must be zero. b[7:0]=the '
    'noise-floor offset, b[31:8] must be zero. c[31]=1 clears the window and '
    'every counter before this beat. A mask whose popcount is not in {2,4,8,16}, '
    'or that selects the cell under test itself, is an invalid guard pattern: no '
    'decision is taken, no hit or miss is counted, the beat faults, and the '
    'window still slides. A hit needs cell[cut] strictly above the threshold. '
    'result[7:0]=the cell under test, result[15:8]=mean noise level, result[16]='
    'hit, result[17]=miss, result[18]=invalid guard pattern, result[19]=restart '
    'applied, result[31:20]=the masked noise sum. aux[12:0]=threshold, '
    'aux[13]=N was not a power of two, aux[14]=the mask selected the cell under '
    'test, aux[15]=restart applied, aux[19:16]=log2(N), aux[23:20]=saturating '
    'invalid-pattern count [3:0], aux[31:24]=saturating beat count. '
    'State: window state[127:0], saturating '
    'hit count state[135:128], saturating miss count state[143:136], saturating '
    'invalid-pattern count state[151:144], saturating beat count state[159:152].',
    """
ccut=16'd0; cthr=16'd0; cmean=16'd0; csum=20'd0; cn=6'd0; clg=4'd0;
cguard=1'b0; cpow=1'b0; chit=1'b0; cmiss=1'b0; ccut_hi=1'b0;
chitc=8'd0; cmissc=8'd0; cinvc=8'd0; cbeatc=8'd0;
if (b[31:8] != 0 || c[30:23] != 0) begin
    f = 1'b1;
end else begin
    cn = pc32({16'd0, c[19:4]});
    clg = nlog2(cn);
    cpow = (cn >= 6'd2) && ((cn & (cn - 6'd1)) == 6'd0);
    ccut_hi = ((c[19:4] >> c[3:0]) & 16'h0001) != 16'd0;
    cguard = !cpow || ccut_hi;
    for (i = 0; i < 16; i = i + 1) begin
        if (c[19:4] & (16'd1 << i)) csum = csum + {12'd0, state_r[(i<<<3) +: 8]};
    end
    cmean = csum >> clg;
    cthr = cmean + (cmean >> c[22:20]) + {8'd0, b[7:0]};
    ccut = {8'd0, state_r[({28'd0, c[3:0]} <<< 3) +: 8]};
    chit = (!cguard) && (ccut > cthr);
    cmiss = (!cguard) && (ccut <= cthr);
    chitc = sat8(c[31] ? 8'd0 : state_r[135:128], chit ? 8'd1 : 8'd0);
    cmissc = sat8(c[31] ? 8'd0 : state_r[143:136], cmiss ? 8'd1 : 8'd0);
    cinvc = sat8(c[31] ? 8'd0 : state_r[151:144], cguard ? 8'd1 : 8'd0);
    cbeatc = sat8(c[31] ? 8'd0 : state_r[159:152], 8'd1);
    if (cguard) f = 1'b1;
    r[7:0] = ccut[7:0];
    r[15:8] = cmean[7:0];
    r[16] = chit;
    r[17] = cmiss;
    r[18] = cguard;
    r[19] = c[31];
    r[31:20] = csum[11:0];
    x[12:0] = cthr[12:0];
    x[13] = ~cpow;
    x[14] = ccut_hi;
    x[15] = c[31];
    x[19:16] = clg;
    x[23:20] = cinvc[3:0];
    x[31:24] = cbeatc;
    state_n[127:0] = c[31] ? {a, 96'd0} : cslide;
    state_n[135:128] = chitc;
    state_n[143:136] = cmissc;
    state_n[151:144] = cinvc;
    state_n[159:152] = cbeatc;
end
""",
    'Four cells are appended and a whole 16-cell masked average, threshold and '
    'hit decision settle in one enabled edge through an adder tree, while a CPU '
    'CFAR loop re-sums the window and divides by N for every cell it touches.',
    4, decl=CA_DECL, stateful=True)


# ===========================================================================
# 5  Manchester line-code encoder / decoder with phase recovery
# ===========================================================================
MAN_DECL = HELPERS + """
reg [64:0] mpool;
reg [31:0] mev, mod, md0, md1, mil0, mil1, mcdata, mcil;
reg [5:0] mv0, mv1, mvu;
reg [7:0] ms0, ms1;
reg [5:0] mst;
reg [15:0] mbits;
reg mph, mphn, mlost, mres, mviol;
reg [63:0] mspread, mchan;
reg signed [31:0] mw0, mw1, mv0s, mv1s, mn0, mn1;
"""

core('manchester_io',
    'Manchester (IEEE 802.5 polarity: a low-to-high mid-period transition is a '
    '1) transform over 32 bit-times per accepted beat, 64 half-bit-time channel '
    'samples. Decode (default): a[31:0] are the first 32 channel samples and '
    'b[31:0] the next 32, earliest in bit 0, read through a 65-bit pool whose '
    'bit 0 is the sample carried from the previous beat. The receiver pairing is '
    '(sample 2k, sample 2k+1) at phase 0 and (the carried sample with sample 0, '
    'then sample 2k-1 with sample 2k) at phase 1, so a beat always retires '
    'exactly 32 bit-times and always carries its own last sample forward. A bit-time is legal only when its two halves differ; the '
    'recovered data bit is the second half. Clock recovery scores both pairings: '
    'v0 and v1 are the violation counts of this beat and each feeds the '
    'saturating EWMA sum0 := clamp(sum0 + ((v0-sum0)>>>2)) and sum1 likewise, '
    'and the phase used by the next beat is 1 when sum1 < sum0, 0 when '
    'sum0 < sum1 and held on a tie. A beat whose 32 bit-times contain any violation '
    'under the phase actually used faults and grows the saturating 6-bit '
    'violating-beat streak; a clean beat clears the streak; a streak reaching '
    'c[5:0] (0 disables the check) additionally sets the loss-of-lock flag. '
    'Encode (c[30]=1): a[31:0] '
    'are 32 data bits and the beat emits the 64 channel samples they map to, '
    'result[31:0] the first half and aux[31:0] the second half; the encoder is '
    'stateless so encode beats leave phase, carry, scores and counters exactly '
    'as found unless c[31]=1. c[31]=1 clears phase, carry, scores, streak and '
    'counters before this beat\'s work; c[29:6] must be zero. result in decode '
    'mode = the 32 recovered data bits (bit 0 earliest). aux in decode mode: '
    'aux[5:0]=v0, aux[11:6]=v1, aux[12]=phase used, aux[13]=phase for the next '
    'beat, aux[14]=loss of lock, aux[15]=restart applied, aux[21:16]=violating '
    'beat streak, aux[29:22]=sum1-sum0 as a signed 8-bit view, aux[31:30]=0. '
    'State: phase state[0], carried sample state[1], sum0 state[9:2], sum1 '
    'state[17:10], streak state[23:18], total violations state[31:24], total '
    'bit-times retired state[47:32].',
    """
mpool=65'd0; mev=32'd0; mod=32'd0; md0=32'd0; md1=32'd0;
mil0=32'd0; mil1=32'd0; mcdata=32'd0; mcil=32'd0;
mv0=6'd0; mv1=6'd0; mvu=6'd0; ms0=8'd0; ms1=8'd0; mst=6'd0; mbits=16'd0;
mph=1'b0; mphn=1'b0; mlost=1'b0; mres=1'b0; mviol=1'b0;
mw0=32'sd0; mw1=32'sd0; mv0s=32'sd0; mv1s=32'sd0; mn0=32'sd0; mn1=32'sd0;
mspread=64'd0; mchan=64'd0;
if (c[29:6] != 0) begin
    f = 1'b1;
end else begin
    if (c[31]) begin
        mres = 1'b1;
    end else begin
        mph = state_r[0];
    end
    if (c[30]) begin
        mspread = {32'd0, a};
        mspread = (mspread | (mspread << 16)) & 64'h0000FFFF0000FFFF;
        mspread = (mspread | (mspread << 8))  & 64'h00FF00FF00FF00FF;
        mspread = (mspread | (mspread << 4))  & 64'h0F0F0F0F0F0F0F0F;
        mspread = (mspread | (mspread << 2))  & 64'h3333333333333333;
        mspread = (mspread | (mspread << 1))  & 64'h5555555555555555;
        mchan = (mspread << 1) | (~mspread & 64'h5555555555555555);
        r = mchan[31:0];
        x = mchan[63:32];
        if (c[31]) state_n = 256'd0;
    end else begin
        mpool = {b, a, 1'b0};
        mpool[0] = mres ? 1'b0 : state_r[1];
        for (i = 0; i < 32; i = i + 1) begin
            mev[i] = mpool[i<<<1];
            mod[i] = mpool[(i<<<1) + 1];
        end
        md0 = (mev >> 1) | {mpool[64], 31'd0};
        md1 = mod;
        mil0 = ~(mod ^ md0);
        mil1 = ~(mev ^ mod);
        mv0 = pc32(mil0);
        mv1 = pc32(mil1);
        mcdata = mph ? md1 : md0;
        mcil   = mph ? mil1 : mil0;
        mvu    = mph ? mv1 : mv0;
        ms0 = mres ? 8'd0 : state_r[9:2];
        ms1 = mres ? 8'd0 : state_r[17:10];
        mw0 = $signed({24'd0, ms0});
        mw1 = $signed({24'd0, ms1});
        mv0s = $signed({26'd0, mv0});
        mv1s = $signed({26'd0, mv1});
        mn0 = mw0 + ((mv0s - mw0) >>> 2);
        if (mn0 < 32'sd0) mn0 = 32'sd0;
        else if (mn0 > 32'sd255) mn0 = 32'sd255;
        mn1 = mw1 + ((mv1s - mw1) >>> 2);
        if (mn1 < 32'sd0) mn1 = 32'sd0;
        else if (mn1 > 32'sd255) mn1 = 32'sd255;
        ms0 = mn0[7:0];
        ms1 = mn1[7:0];
        mphn = (ms1 < ms0) ? 1'b1 : ((ms0 < ms1) ? 1'b0 : mph);
        mviol = (mcil != 32'd0);
        mst = mres ? 6'd0 : state_r[23:18];
        if (mviol) begin
            f = 1'b1;
            if (mst != 6'h3F) mst = mst + 6'd1;
        end else begin
            mst = 6'd0;
        end
        if (c[5:0] != 6'd0 && mst >= c[5:0]) begin
            mlost = 1'b1;
            mst = 6'd0;
        end
        mbits = (mres ? 16'd0 : state_r[47:32]) + 16'd32;
        r = mcdata;
        x[5:0] = mv0;  x[11:6] = mv1;
        x[12] = mph;   x[13] = mphn;
        x[14] = mlost; x[15] = mres;
        x[21:16] = mst;
        x[29:22] = ms1 - ms0;
        state_n[0] = mphn;
        state_n[1] = b[31];
        state_n[9:2] = ms0;
        state_n[17:10] = ms1;
        state_n[23:18] = mst;
        state_n[31:24] = mres ? 8'd0 : sat8(state_r[31:24], {2'd0, mvu});
        state_n[47:32] = mbits;
    end
end
""",
    'Sixty-four channel samples are scored for mid-period legality under both '
    'candidate pairings in the same cone, so 32 bit-times decode and the clock '
    'phase corrects on the enabled edge, where a bit-banged receiver samples one '
    'edge per timer interrupt and cannot re-align mid-stream at all.', 32,
    decl=MAN_DECL, stateful=True)


# ===========================================================================
# 6  DMX512-RDM line-state frame assembler
# ===========================================================================
# One accepted beat is one measured level interval of the DMX line, so a break,
# a MAB, a start bit, eight data bits and a stop bit are each one parallel
# window compare instead of a timer ISR.  The byte is committed on the stop bit
# and a frame is committed by the break that ends it, by the idle gap that
# follows it, or by an explicit flush.
DMX_DECL = HELPERS + """
reg [15:0] dw, dnom, djit;
reg [7:0] dby, dby_n, dxor, dxor_n, dlow, dhigh, dlow_n, dhigh_n;
reg [7:0] dlastx, dcx, dvt, dvf, dvb, dframes;
reg [8:0] dslots, dslots_n, dlasts, dcs;
reg [3:0] dpos, dpos_n;
reg dlevel, dbreak, dmab, dflush, dcommit, dbyte_c, dfv, dover, dtviol;
reg darmed, darmed_n, dval;
"""

core('dmx512_frame',
    'DMX512-RDM receiver framing over measured line intervals, one interval per '
    'accepted beat. a[15:0]=the interval length in ticks, a[16]=the line level '
    'during it (1=high, 0=low), a[31:17] must be zero. b[7:0]=BREAK_MIN, the '
    'consecutive low bit-times that promote a low run to a break; it must be '
    '10..255 because a legitimate low run is at most a start bit plus eight data '
    'bits. b[15:8]=MAB_MIN, the consecutive high bit-times after a stop bit that '
    'close a frame; it must be nonzero. b[31:16] must be zero. c[5:0]=TS so the '
    'nominal bit time is two to the TS ticks (TS=5 is the 4.01 us DMX bit in '
    '125 ns ticks), it must be 1..15. c[11:8]=TE: the interval is timing-legal '
    'when its length lies within nominal-(nominal>>TE)-1 to '
    'nominal+(nominal>>TE)+1, and TE=0 disables the width check. c[29:12] must '
    'be zero, c[30]=1 flushes the pending frame on this beat, c[31]=1 clears the '
    'frame accumulation, the runs, the bit position and every counter before '
    'this beat is processed. A beat with a must-be-zero bit set or an illegal '
    'timing configuration is malformed: result=aux=0, fault=1, state kept. Level '
    'low: the first low interval at a byte boundary is the start bit, later low '
    'intervals set data bit (position-1) of the accumulating byte (UART data is '
    'inverted, so a low bit-time carries a 1) and a low interval where the stop '
    'bit belongs is a framing violation. A low run reaching BREAK_MIN becomes a '
    'break: a frame with bytes pending is committed first, then the slot '
    'counter, the frame checksum and the byte accumulator restart and the '
    'receiver is armed. Level high: a high interval inside a symbol is a data 0; '
    'a high interval at the stop position completes the byte (slot count +1, '
    'frame checksum XORed with the byte) unless 512 slots are already full, '
    'which is a slot overflow that drops the byte. A high run reaching MAB_MIN '
    'at a byte boundary while armed and holding bytes commits the frame. A low '
    'run that ends before reaching BREAK_MIN while the receiver is not armed is '
    'a framing violation (a data pulse before any break); its partial byte and '
    'bit position are discarded. '
    'Committing stores the frame byte count and checksum in the last-frame '
    'fields, sets frame valid and increments the committed-frame count. Any '
    'timing, framing or overflow violation faults. result[7:0]=the byte '
    'accumulator, result[16:8]=slot count after the beat, result[17]=a byte was '
    'committed, result[18]=a break was detected, result[19]=a frame was '
    'committed, result[20]=timing violation, result[21]=framing violation, '
    'result[22]=slot overflow, result[23]=restart applied, result[27:24]=the bit '
    'position inside the symbol (0=byte boundary, 1..8=data, 9=stop expected), '
    'result[28]=armed, result[29]=this beat line level, result[31:30]=0. '
    'aux[7:0]=the frame checksum, aux[15:8]=the low run, aux[23:16]=the high '
    'run, aux[24]=frame valid, aux[25]=flush requested, aux[27:26]=0, '
    'aux[31:28]=timing violation count [3:0]. State: slot count state[8:0], '
    'frame checksum state[16:9], armed state[17], low run state[25:18], high run '
    'state[33:26], bit position state[37:34], byte accumulator state[45:38], '
    'frame valid state[46], last frame checksum state[54:47], last frame byte '
    'count state[63:55], saturating timing violation count state[71:64], '
    'saturating framing violation count state[79:72], saturating committed frame '
    'count state[87:80], saturating beat count state[95:88].',
    """
dw=16'd0; dnom=16'd0; djit=16'd0;
dby=8'd0; dby_n=8'd0; dxor=8'd0; dxor_n=8'd0; dlow=8'd0; dhigh=8'd0;
dlow_n=8'd0; dhigh_n=8'd0; dlastx=8'd0; dcx=8'd0; dvt=8'd0; dvf=8'd0; dvb=8'd0;
dframes=8'd0;
dslots=9'd0; dslots_n=9'd0; dlasts=9'd0; dcs=9'd0;
dpos=4'd0; dpos_n=4'd0;
dlevel=1'b0; dbreak=1'b0; dmab=1'b0; dflush=1'b0; dcommit=1'b0; dbyte_c=1'b0;
dfv=1'b0; dover=1'b0; dtviol=1'b0; darmed=1'b0; darmed_n=1'b0; dval=1'b0;
if (a[31:17] != 0 || b[31:16] != 0 || c[29:12] != 0 || b[7:0] < 8'd10
    || b[15:8] == 8'd0 || c[5:0] == 6'd0 || c[5:0] > 6'd15) begin
    f = 1'b1;
end else begin
    dlevel = a[16];
    dw = a[15:0];
    dnom = 16'd1 << c[5:0];
    djit = (c[11:8] == 4'd0) ? 16'h7FFF : (dnom >> c[11:8]);
    dtviol = (c[11:8] != 4'd0) && ((dw < (dnom - djit - 16'd1))
                                || (dw > (dnom + djit + 16'd1)));
    dlow   = c[31] ? 8'd0 : state_r[25:18];
    dhigh  = c[31] ? 8'd0 : state_r[33:26];
    dpos   = c[31] ? 4'd0 : state_r[37:34];
    dby    = c[31] ? 8'd0 : state_r[45:38];
    dslots = c[31] ? 9'd0 : state_r[8:0];
    dxor   = c[31] ? 8'd0 : state_r[16:9];
    darmed = c[31] ? 1'b0 : state_r[17];
    dval   = state_r[46];
    dlastx = state_r[54:47];
    dlasts = state_r[63:55];
    dlow_n  = dlevel ? 8'd0 : sat8(dlow, 8'd1);
    dhigh_n = dlevel ? sat8(dhigh, 8'd1) : 8'd0;
    dbreak  = (!dlevel) && (dlow_n == b[7:0]);
    dpos_n = dpos; dby_n = dby; dslots_n = dslots; dxor_n = dxor;
    darmed_n = darmed;
    if (dbreak) begin
        dpos_n = 4'd0; dby_n = 8'd0; dslots_n = 9'd0; dxor_n = 8'd0;
        darmed_n = 1'b1;
    end else if (!dlevel) begin
        if (dpos == 4'd0) begin
            dpos_n = 4'd1;
        end else if (dpos <= 4'd8) begin
            dby_n = dby | (8'h01 << (dpos - 4'd1));
            dpos_n = dpos + 4'd1;
        end else begin
            dfv = 1'b1;
        end
    end else if (!darmed && dlow != 8'd0) begin
        dfv = 1'b1;
        dpos_n = 4'd0;
        dby_n = 8'd0;
    end else if (dpos == 4'd0) begin
        dpos_n = 4'd0;
    end else if (dpos <= 4'd8) begin
        dpos_n = dpos + 4'd1;
    end else if (dslots == 10'd512) begin
        dover = 1'b1;
        dpos_n = 4'd0; dby_n = 8'd0;
    end else begin
        dslots_n = dslots + 9'd1;
        dxor_n = dxor ^ dby;
        dbyte_c = 1'b1;
        dpos_n = 4'd0; dby_n = 8'd0;
    end
    dmab = dlevel && (dpos == 4'd0) && darmed && (dhigh_n == b[15:8])
           && (dslots_n != 9'd0);
    dflush = c[30] && darmed && (!dbreak) && (dslots_n != 9'd0);
    dcommit = (dbreak && darmed && (dslots != 9'd0)) || dmab || dflush;
    dcs = dbreak ? dslots : dslots_n;
    dcx = dbreak ? dxor : dxor_n;
    if (dcommit) begin
        dval = 1'b1; dlasts = dcs; dlastx = dcx;
        dframes = sat8(c[31] ? 8'd0 : state_r[87:80], 8'd1);
        if (!dbreak) begin
            dslots_n = 9'd0; dxor_n = 8'd0; dpos_n = 4'd0; dby_n = 8'd0;
            darmed_n = 1'b0;
        end
    end else begin
        dframes = c[31] ? 8'd0 : state_r[87:80];
    end
    dvt = sat8(c[31] ? 8'd0 : state_r[71:64], dtviol ? 8'd1 : 8'd0);
    dvf = sat8(c[31] ? 8'd0 : state_r[79:72], (dfv || dover) ? 8'd1 : 8'd0);
    dvb = sat8(c[31] ? 8'd0 : state_r[95:88], 8'd1);
    if (dtviol || dfv || dover) f = 1'b1;
    r[7:0] = dby_n;
    r[16:8] = dslots_n;
    r[17] = dbyte_c;
    r[18] = dbreak;
    r[19] = dcommit;
    r[20] = dtviol;
    r[21] = dfv;
    r[22] = dover;
    r[23] = c[31];
    r[27:24] = dpos_n;
    r[28] = darmed_n;
    r[29] = dlevel;
    x[7:0] = dxor_n;
    x[15:8] = dlow_n;
    x[23:16] = dhigh_n;
    x[24] = dval;
    x[25] = c[30];
    x[31:28] = dvt[3:0];
    state_n[8:0] = dslots_n;
    state_n[16:9] = dxor_n;
    state_n[17] = darmed_n;
    state_n[25:18] = dlow_n;
    state_n[33:26] = dhigh_n;
    state_n[37:34] = dpos_n;
    state_n[45:38] = dby_n;
    state_n[46] = dval;
    state_n[54:47] = dlastx;
    state_n[63:55] = dlasts;
    state_n[71:64] = dvt;
    state_n[79:72] = dvf;
    state_n[87:80] = dframes;
    state_n[95:88] = dvb;
end
""",
    'A break, a MAB and all ten bit-times of a DMX symbol are window compares '
    'settled on the enabled edge the interval measurement arrives, so the slot '
    'counter never drifts the way a bit-banged CPU frame does when an interrupt '
    'steals microseconds out of one bit.', 1,
    decl=DMX_DECL, stateful=True)


# ===========================================================================
# 7  1-Wire slot, presence and command decoder with CRC8/MAXIM
# ===========================================================================
# Each beat is one measured level interval, so the published standard-speed and
# overdrive windows (reset, presence, bit 1, bit 0, short slot, long slot) are
# six parallel compares, and the eighth bit of a byte folds a whole CRC8/MAXIM
# through an eight stage XOR tree.
OW_DECL = HELPERS + """
reg [15:0] ot, olm, otot, orst_lo, oprs_lo, oprs_hi, oslot_max, oone, ozmin, ozmax;
reg [7:0] osh, osh_n, ocrc, ocrc_n, obytes, obytes_n, obyt, ovr, obtn, orn, opn;
reg [7:0] ocbit, obl4;
reg [3:0] obp, obp_n;
reg olvl, opend, opval, opend_n, orst, oprs, onopr, ostuck, oshort, olong;
reg orec, oslot, oacc, obc, oknown, oover;
reg [15:0] olm_n;
"""

core('onewire_slot',
    '1-Wire (Maxim/Dallas standard speed and overdrive) slot receiver over '
    'measured level intervals, one interval per accepted beat, that assembles '
    'bytes LSB-first and folds the running CRC8/MAXIM of the transaction. '
    'a[15:0]=the interval length in microseconds, a[16]=the line level (1=high, '
    '0=low), a[31:17] must be zero. b[15:0] must be zero. c[7:0]=REC_MIN, the '
    'minimum high recovery microseconds after a slot (0 disables that check), '
    'c[15:8] must be zero, c[23:16]=BYTE_LIMIT, the number of bytes accepted '
    'before the transaction is declared over-long (0 means no limit), c[29:24] '
    'must be zero, c[30]=1 selects the overdrive window set, c[31]=1 clears the '
    'shift register, bit position, byte count, CRC, pending slot and every '
    'counter before this beat is processed. Standard-speed windows: a low '
    'interval of 480..539 us is a reset with no presence pulse, 540..720 us is a '
    'reset with the published 60..240 us presence merged into it, 721 us and '
    'above is a stuck-low violation, 1..15 us is a pending 1, 60..120 us is a '
    'pending 0, 16..59 us is a short-slot violation and 121..479 us is a '
    'long-slot violation. Overdrive divides the same set to 30..53 reset without '
    'presence, 54..150 reset with presence, above 150 stuck, 1..6 pending 1 and '
    '8..17 pending 0, with the same gap violations. A pending slot is resolved '
    'only by the following high interval: its length must be at least REC_MIN and '
    'the full slot (that low time plus the high time) must be 60..150 us '
    '(8..21 us overdrive), and only then is the pending bit accepted. A low '
    'interval arriving while a slot is still pending discards that slot and is a '
    'violation. An accepted bit shifts in LSB-first; the eighth bit completes a '
    'byte, increments the byte count, XORs the byte into the running CRC8/MAXIM '
    '(polynomial 0x31 reflected as 0x8C, init 0, no xorout) and compares the '
    'byte against the published master command set 0x33 SEARCH_ROM, 0x0F '
    'SKIP_ROM, 0xCC PRESENT, 0xA5 SEARCH_ALG, 0x96 MATCH_ROM, 0x69 READ_ROM, '
    '0x3C OVERDRIVE_MATCH and 0xEC OVERDRIVE_SKIP. A reset clears the CRC, the '
    'byte count, the shift register and the bit position because the CRC covers '
    'exactly one transaction. A window violation, a reset without presence, a '
    'recovery violation or a byte that would exceed BYTE_LIMIT faults; an '
    'over-long byte is not folded into the CRC and is not counted. result[7:0]='
    'the byte shift register after the beat (a whole byte on its eighth bit), '
    'result[15:8]=the running CRC after the beat, result[16]=a bit was accepted, '
    'result[17]=a byte was completed, result[18]=a reset was detected, '
    'result[19]=a presence pulse was seen, result[20]=a reset without presence, '
    'result[21]=the byte is a known master command, result[22]=a slot window '
    'violation, result[23]=restart applied, result[27:24]=the bit position, '
    'result[28]=a slot is pending, result[29]=this beat line level, result[30]='
    'recovery violation, result[31]=transaction over-long. aux[7:0]=bytes since '
    'the last reset, aux[15:8]=the resolved slot total, aux[23:16]=the pending '
    'low interval, aux[24]=overdrive mode, aux[25]=stuck-low violation, '
    'aux[27:26]=0, aux[31:28]=violation count [3:0]. State: shift state[7:0], '
    'bit position state[11:8], CRC state[19:12], byte count state[27:20], '
    'pending low time state[43:28], pending flag state[44], pending bit value '
    'state[45], last completed byte state[53:46], saturating violation count '
    'state[61:54], saturating byte total state[69:62], saturating reset count '
    'state[77:70], saturating presence count state[85:78], saturating bit count '
    'state[93:86], saturating beat count state[101:94].',
    """
ot=16'd0; olm=16'd0; otot=16'd0; orst_lo=16'd0; oprs_lo=16'd0; oprs_hi=16'd0;
oslot_max=16'd0; oone=16'd0; ozmin=16'd0; ozmax=16'd0; olm_n=16'd0;
osh=8'd0; osh_n=8'd0; ocrc=8'd0; ocrc_n=8'd0; obytes=8'd0; obytes_n=8'd0;
obyt=8'd0; ovr=8'd0; obtn=8'd0; orn=8'd0; opn=8'd0; ocbit=8'd0; obl4=8'd0;
obp=4'd0; obp_n=4'd0;
olvl=1'b0; opend=1'b0; opval=1'b0; opend_n=1'b0; orst=1'b0; oprs=1'b0;
onopr=1'b0; ostuck=1'b0; oshort=1'b0; olong=1'b0; orec=1'b0; oslot=1'b0;
oacc=1'b0; obc=1'b0; oknown=1'b0; oover=1'b0;
if (a[31:17] != 0 || b[15:0] != 0 || c[29:24] != 0) begin
    f = 1'b1;
end else begin
    olvl = a[16];
    ot = a[15:0];
    orst_lo = c[30] ? 16'd30 : 16'd480;
    oprs_lo = c[30] ? 16'd54 : 16'd540;
    oprs_hi = c[30] ? 16'd150 : 16'd720;
    oone  = c[30] ? 16'd6 : 16'd15;
    ozmin = c[30] ? 16'd8 : 16'd60;
    ozmax = c[30] ? 16'd17 : 16'd120;
    oslot_max = ozmax + (ozmax >> 2);
    osh    = c[31] ? 8'd0 : state_r[7:0];
    obp    = c[31] ? 4'd0 : state_r[11:8];
    ocrc   = c[31] ? 8'd0 : state_r[19:12];
    obytes = c[31] ? 8'd0 : state_r[27:20];
    olm    = c[31] ? 16'd0 : state_r[43:28];
    opend  = c[31] ? 1'b0 : state_r[44];
    opval  = c[31] ? 1'b0 : state_r[45];
    obyt   = c[31] ? 8'd0 : state_r[53:46];
    osh_n = osh; obp_n = obp; ocrc_n = ocrc; obytes_n = obytes; olm_n = olm;
    opend_n = opend;
    if (!olvl) begin
        if (opend) oslot = 1'b1;
        opend_n = 1'b0;
        olm_n = ot;
        if (ot > oprs_hi) begin
            ostuck = 1'b1;
        end else if (ot >= orst_lo) begin
            orst = 1'b1;
            osh_n = 8'd0; obp_n = 4'd0; ocrc_n = 8'd0; obytes_n = 8'd0;
            if (ot >= oprs_lo) oprs = 1'b1;
            else               onopr = 1'b1;
        end else if (ot >= 16'd1 && ot <= oone) begin
            opend_n = 1'b1; opval = 1'b1;
        end else if (ot >= ozmin && ot <= ozmax) begin
            opend_n = 1'b1; opval = 1'b0;
        end else if (ot < ozmin) begin
            oshort = 1'b1;
        end else begin
            olong = 1'b1;
        end
    end else if (opend) begin
        otot = olm + ot;
        opend_n = 1'b0;
        if (c[7:0] != 8'd0 && ot < {8'd0, c[7:0]}) begin
            orec = 1'b1;
        end else if (otot < ozmin || otot > oslot_max) begin
            oslot = 1'b1;
        end else begin
            oacc = 1'b1;
            osh_n = {1'b0, osh[7:1]} | (opval ? 8'h80 : 8'h00);
            if (obp == 4'd7) begin
                obp_n = 4'd0;
                obc = 1'b1;
                obyt = osh_n;
                if (c[23:16] != 8'd0 && obytes >= c[23:16]) begin
                    oover = 1'b1;
                end else begin
                    ocrc_n = ocrc ^ osh_n;
                    for (j = 0; j < 8; j = j + 1) begin
                        if (ocrc_n[0]) ocrc_n = (ocrc_n >> 1) ^ 8'h8C;
                        else           ocrc_n = ocrc_n >> 1;
                    end
                    oknown = (obyt == 8'h33) || (obyt == 8'h0F)
                          || (obyt == 8'hCC) || (obyt == 8'hA5)
                          || (obyt == 8'h96) || (obyt == 8'h69)
                          || (obyt == 8'h3C) || (obyt == 8'hEC);
                    obytes_n = obytes + 8'd1;
                end
            end else begin
                obp_n = obp + 4'd1;
            end
        end
    end
    if (ostuck || onopr || oshort || olong || orec || oslot || oover) f = 1'b1;
    ovr = sat8(c[31] ? 8'd0 : state_r[61:54],
               (ostuck || onopr || oshort || olong || orec || oslot || oover)
               ? 8'd1 : 8'd0);
    obtn = sat8(c[31] ? 8'd0 : state_r[69:62], obc ? 8'd1 : 8'd0);
    orn = sat8(c[31] ? 8'd0 : state_r[77:70], orst ? 8'd1 : 8'd0);
    opn = sat8(c[31] ? 8'd0 : state_r[85:78], oprs ? 8'd1 : 8'd0);
    ocbit = sat8(c[31] ? 8'd0 : state_r[93:86], oacc ? 8'd1 : 8'd0);
    obl4 = sat8(c[31] ? 8'd0 : state_r[101:94], 8'd1);
    r[7:0] = osh_n;
    r[15:8] = ocrc_n;
    r[16] = oacc;
    r[17] = obc;
    r[18] = orst;
    r[19] = oprs;
    r[20] = onopr;
    r[21] = oknown;
    r[22] = oshort || olong || oslot;
    r[23] = c[31];
    r[27:24] = obp_n;
    r[28] = opend_n;
    r[29] = olvl;
    r[30] = orec;
    r[31] = oover;
    x[7:0] = obytes_n;
    x[15:8] = otot[7:0];
    x[23:16] = olm_n[7:0];
    x[24] = c[30];
    x[25] = ostuck;
    x[31:28] = ovr[3:0];
    state_n[7:0] = osh_n;
    state_n[11:8] = obp_n;
    state_n[19:12] = ocrc_n;
    state_n[27:20] = obytes_n;
    state_n[43:28] = olm_n;
    state_n[44] = opend_n;
    state_n[45] = opval;
    state_n[53:46] = obyt;
    state_n[61:54] = ovr;
    state_n[69:62] = obtn;
    state_n[77:70] = orn;
    state_n[85:78] = opn;
    state_n[93:86] = ocbit;
    state_n[101:94] = obl4;
end
""",
    'Presence, short-slot and long-slot legality are parallel window compares on '
    'the measured interval and the eighth bit folds a whole CRC8 byte through an '
    'XOR tree, so a 1-Wire transaction resolves on the enabled edge that reports '
    'it instead of a CPU busy-waiting through 60 microsecond bit bangers.', 1,
    decl=OW_DECL, stateful=True)


# ===========================================================================
# 8  WS2812 bit-time duty decoder and GRB pixel stream monitor
# ===========================================================================
# A beat is one measured bit-time: high ticks and low ticks at 125 ns each, so
# T0H/T1H/T0L/T1L legality, the 1.25 us period, the 24-bit MSB-first GRB
# assembly and the >50 us latch are all parallel window compares.
WS_DECL = HELPERS + """
reg [15:0] wh, wl, wtot, wrst, wtol;
reg [23:0] wsh, wsh_n, wlast;
reg [7:0] wdig, wdig_n, wpix, wpix_n, wexp, wdu4;
reg [7:0] wpc8, wfl8, wtr8, wlt8, wbt8;
reg [5:0] wbpos, wbpos_n;
reg wbit, wacc, wpc, wlat, wreq, wdu, wpe, wfl, wtr, widle, wpend, wpend_n;
"""

core('ws2812_serial',
    'WS2812/SK6812 stream monitor over measured bit-times, one bit-time per '
    'accepted beat. a[15:0]=the high ticks of the bit-time and a[31:16]=the low '
    'ticks, both in 125 ns units, so a nominal 1.25 us bit is 10 ticks. b[7:0]='
    'PIXELS, the pixel count a latched frame must have (0 disables the length '
    'check), b[31:8] must be zero. c[1:0]=TOL, the extra ticks allowed on either '
    'side of the 9..11 tick period window, c[11:6]=RSTU, the latch threshold in '
    'units of 16 ticks (0 means the published 400 ticks, i.e. 50 us), c[29:12] '
    'must be zero, c[30]=1 closes the frame on this beat (a manual latch) and '
    'c[31]=1 clears the shift register, the bit position, the pixel count, the '
    'frame digest and every counter before this beat is processed. A beat whose '
    'total is at least the latch threshold, or which requests a manual latch, '
    'takes no bit: it latches the pixel stream if anything is present, so a '
    'partial pixel in the shift register is a truncated-frame violation and a '
    'count that differs from PIXELS is a frame-length violation, and both then '
    'reset the accumulation. Otherwise the bit is decoded by the published duty '
    'threshold (high ticks at or above 5 of 10 is a 1) and shifted in MSB-first; '
    'a duty window is legal for a 0 at high 1..4 with low 5..8 and for a 1 at '
    'high 5..8 with low 2..5, so any other combination is a duty violation that '
    'is still decoded, and a total outside 9-TOL to 11+TOL is a period violation '
    'that is still decoded. The 24th bit completes a pixel: it is stored as the '
    'last pixel, increments the pixel count and XORs its three channels into the '
    'frame digest. result[7:0]=blue of the last completed pixel, result[15:8]='
    'red, result[23:16]=green, result[24]=a bit was accepted, result[25]=the '
    'decoded bit value, result[26]=a pixel was completed, result[27]=the frame '
    'latched, result[28]=duty violation, result[29]=period violation, '
    'result[30]=frame-length violation, result[31]=truncated pixel. aux[7:0]='
    'the frame digest, aux[15:8]=the pixel count, aux[23:16]=the bit position, '
    'aux[24]=restart applied, aux[25]=manual latch requested, aux[26]=a frame is '
    'valid, aux[27]=latch with nothing pending, aux[31:28]=duty violation count '
    '[3:0]. State: shift register state[23:0], bit position state[29:24], pixel '
    'count state[37:30], frame digest state[45:38], last pixel state[69:46], '
    'frame valid state[70], saturating latch count state[78:71], saturating duty '
    'violation count state[86:79], saturating period violation count '
    'state[94:87], saturating frame-length violation count state[102:95], '
    'saturating truncation violation count state[110:103], saturating beat count '
    'state[118:111]. Any duty, period, length or truncation violation faults.',
    """
wh=16'd0; wl=16'd0; wtot=16'd0; wrst=16'd0; wtol=16'd0;
wsh=24'd0; wsh_n=24'd0; wlast=24'd0;
wdig=8'd0; wdig_n=8'd0; wpix=8'd0; wpix_n=8'd0; wexp=8'd0; wdu4=8'd0;
wbpos=6'd0; wbpos_n=6'd0;
wbit=1'b0; wacc=1'b0; wpc=1'b0; wlat=1'b0; wreq=1'b0; wdu=1'b0; wpe=1'b0;
wfl=1'b0; wtr=1'b0; widle=1'b0; wpend=1'b0; wpend_n=1'b0;
if (c[29:12] != 0 || b[31:8] != 0) begin
    f = 1'b1;
end else begin
    wh = a[15:0];
    wl = a[31:16];
    wtot = wh + wl;
    wrst = (c[11:6] == 6'd0) ? 16'd400 : {4'd0, c[11:6], 4'd0};
    wtol = {14'd0, c[1:0]};
    wreq = c[30];
    wlat = (wtot >= wrst) || wreq;
    wsh   = c[31] ? 24'd0 : state_r[23:0];
    wbpos = c[31] ? 6'd0 : state_r[29:24];
    wpix  = c[31] ? 8'd0 : state_r[37:30];
    wdig  = c[31] ? 8'd0 : state_r[45:38];
    wlast = c[31] ? 24'd0 : state_r[69:46];
    wpend = state_r[70];
    wexp  = b[7:0];
    wsh_n = wsh; wbpos_n = wbpos; wpix_n = wpix; wdig_n = wdig;
    wpend_n = wpend;
    if (wlat) begin
        wtr = (wbpos != 6'd0);
        wfl = (wexp != 8'd0) && (wpix != wexp);
        widle = (wbpos == 6'd0) && (wpix == 8'd0);
        if (!widle) begin
            wpend_n = 1'b1;
            wsh_n = 24'd0; wbpos_n = 6'd0; wpix_n = 8'd0; wdig_n = 8'd0;
        end
    end else begin
        wbit = (wh >= 16'd5);
        wdu = !((wh >= 16'd1 && wh <= 16'd4 && wl >= 16'd5 && wl <= 16'd8)
             || (wh >= 16'd5 && wh <= 16'd8 && wl >= 16'd2 && wl <= 16'd5));
        wpe = !((wtot + wtol >= 16'd9) && (wtot <= 16'd11 + wtol));
        wacc = 1'b1;
        wsh_n = {wsh[22:0], wbit};
        if (wbpos == 6'd23) begin
            wpc = 1'b1;
            wlast = wsh_n;
            wpix_n = sat8(wpix, 8'd1);
            wdig_n = wdig ^ wsh_n[23:16] ^ wsh_n[15:8] ^ wsh_n[7:0];
            wbpos_n = 6'd0;
        end else begin
            wbpos_n = wbpos + 6'd1;
        end
    end
    if (wdu || wpe || wtr || wfl) f = 1'b1;
    wdu4 = sat8(c[31] ? 8'd0 : state_r[86:79], wdu ? 8'd1 : 8'd0);
    wpc8 = sat8(c[31] ? 8'd0 : state_r[94:87], wpe ? 8'd1 : 8'd0);
    wfl8 = sat8(c[31] ? 8'd0 : state_r[102:95], wfl ? 8'd1 : 8'd0);
    wtr8 = sat8(c[31] ? 8'd0 : state_r[110:103], wtr ? 8'd1 : 8'd0);
    wlt8 = sat8(c[31] ? 8'd0 : state_r[78:71], (!widle && wlat) ? 8'd1 : 8'd0);
    wbt8 = sat8(c[31] ? 8'd0 : state_r[118:111], 8'd1);
    r[7:0] = wlast[7:0];
    r[15:8] = wlast[15:8];
    r[23:16] = wlast[23:16];
    r[24] = wacc;
    r[25] = wbit;
    r[26] = wpc;
    r[27] = wlat && !widle;
    r[28] = wdu;
    r[29] = wpe;
    r[30] = wfl;
    r[31] = wtr;
    x[7:0] = wdig_n;
    x[15:8] = wpix_n;
    x[23:16] = {2'd0, wbpos_n};
    x[24] = c[31];
    x[25] = wreq;
    x[26] = wpend_n;
    x[27] = widle;
    x[31:28] = wdu4[3:0];
    state_n[23:0] = wsh_n;
    state_n[29:24] = wbpos_n;
    state_n[37:30] = wpix_n;
    state_n[45:38] = wdig_n;
    state_n[69:46] = wlast;
    state_n[70] = wpend_n;
    state_n[78:71] = wlt8;
    state_n[86:79] = wdu4;
    state_n[94:87] = wpc8;
    state_n[102:95] = wfl8;
    state_n[110:103] = wtr8;
    state_n[118:111] = wbt8;
end
""",
    'Ten duty window compares, a 24-bit MSB-first shift and the latch threshold '
    'resolve on the enabled edge that carries the bit-time, so a stripped '
    'controller can watch a whole WS2812 chain for dropped bits at full data '
    'rate, which a bit-banged CPU loop cannot do at all because its own '
    'microsecond-scale jitter is the thing it would have to measure.', 1,
    decl=WS_DECL, stateful=True)


# ===========================================================================
# 9  CRC-16/MODBUS with four bytes folded per accepted beat
# ===========================================================================
# The wire order is reflected (LSB first, polynomial 0xA001 = the reverse of
# 0x8005, init 0xFFFF, no xorout), so folding a byte is eight shift/XOR stages of
# the 16-bit register and a whole frame validates through the zero-residue
# property instead of a second CRC computation.
CRC_DECL = HELPERS + """
reg [15:0] ccrc, ccnt, cmax;
reg [7:0] cd, clast, caddr, covf, crr, csr, cbt;
reg [3:0] cnby, cnf;
reg cok, cseen, covfl, cunchecked;
"""

core('crc16_modbus',
    'CRC-16/MODBUS (reflected polynomial 0xA001, init 0xFFFF, no xorout) over '
    'one to four wire bytes per accepted beat, which is exactly the Modbus RTU '
    'byte order: LSB first inside a byte, byte a[7:0] before a[15:8] before '
    'a[23:16] before a[31:24]. b[7:0]=ADDRESS, compared against the first byte '
    'folded since the last restart (0 disables the address check), b[15:8]='
    'MAXLEN, the maximum frame length in bytes (0 means unlimited), b[31:16] '
    'must be zero. c[1:0]=NBYTES-1, so 0 folds one byte and 3 folds all four, '
    'c[3]=1 validates the frame on this beat by requiring the running CRC to be '
    'the MODBUS residue 0x0000 (a received frame that includes its own two CRC '
    'bytes, low byte first, validates to 0x0000), c[29:4] must be zero, c[31]=1 '
    'restarts the CRC to 0xFFFF, zeroes the byte count, clears the address and '
    'last-byte fields and every counter before this beat folds its bytes. A beat '
    'with a must-be-zero bit set is malformed: result=aux=0, fault=1, state '
    'kept. Bytes past MAXLEN are not folded and set the overflow flag, which '
    'faults. The residue check fails (fault) when c[3]=1 and the running CRC is '
    'not 0x0000. result[15:0]=the running CRC after the beat (its low byte is '
    'the first CRC byte a transmitter puts on the wire), result[16]=residue '
    'valid, result[17]=address matched or unchecked, result[18]=restart applied, '
    'result[19]=length overflow, result[20]=residue requested, result[23:21]=0, '
    'result[31:24]=the last byte folded. aux[15:0]=the frame byte count, '
    'aux[23:16]=bytes folded on this beat, aux[24]=the address byte has been '
    'seen, aux[25]=address check disabled, aux[26]=validation requested, '
    'aux[27]=0, aux[31:28]=saturating overflow count [3:0]. State: CRC '
    'state[15:0], byte count state[31:16], last byte state[39:32], address ok '
    'state[40], address byte seen state[41], saturating overflow count '
    'state[49:42], saturating residue-fail count state[57:50], saturating '
    'restart count state[65:58], saturating beat count state[73:66].',
    """
ccrc=16'd0; ccnt=16'd0; cmax=16'd0;
cd=8'd0; clast=8'd0; caddr=8'd0; covf=8'd0; crr=8'd0; csr=8'd0; cbt=8'd0;
cnby=4'd0; cnf=4'd0;
cok=1'b0; cseen=1'b0; covfl=1'b0; cunchecked=1'b0;
if (b[31:16] != 0 || c[29:4] != 0) begin
    f = 1'b1;
end else begin
    ccrc = c[31] ? 16'hFFFF : state_r[15:0];
    ccnt = c[31] ? 16'd0 : state_r[31:16];
    clast = c[31] ? 8'd0 : state_r[39:32];
    caddr = b[7:0];
    cunchecked = (caddr == 8'd0);
    cok = c[31] ? cunchecked : state_r[40];
    cseen = c[31] ? 8'd0 : state_r[41];
    cmax = (b[15:8] == 8'd0) ? 16'hFFFF : {8'd0, b[15:8]};
    cnby = {2'd0, c[1:0]} + 4'd1;
    for (i = 0; i < 4; i = i + 1) begin
        if (i[2:0] < cnby[2:0]) begin
            if (ccnt >= cmax) begin
                covfl = 1'b1;
            end else begin
                cd = a[(i<<<3) +: 8];
                ccrc = ccrc ^ {8'd0, cd};
                for (j = 0; j < 8; j = j + 1) begin
                    if (ccrc[0]) ccrc = (ccrc >> 1) ^ 16'hA001;
                    else         ccrc = ccrc >> 1;
                end
                ccnt = ccnt + 16'd1;
                clast = cd;
                cnf = cnf + 4'd1;
                if (!cseen) begin
                    cok = cunchecked || (cd == caddr);
                    cseen = 1'b1;
                end
            end
        end
    end
    covf = sat8(c[31] ? 8'd0 : state_r[49:42], covfl ? 8'd1 : 8'd0);
    crr = sat8(c[31] ? 8'd0 : state_r[57:50], (c[3] && ccrc != 16'd0) ? 8'd1 : 8'd0);
    csr = sat8(c[31] ? 8'd0 : state_r[65:58], c[31] ? 8'd1 : 8'd0);
    cbt = sat8(c[31] ? 8'd0 : state_r[73:66], 8'd1);
    if (covfl || (c[3] && ccrc != 16'd0)) f = 1'b1;
    r[15:0] = ccrc;
    r[16] = c[3] && (ccrc == 16'd0);
    r[17] = cok;
    r[18] = c[31];
    r[19] = covfl;
    r[20] = c[3];
    r[31:24] = clast;
    x[15:0] = ccnt;
    x[19:16] = {1'd0, cnf};
    x[24] = cseen;
    x[25] = cunchecked;
    x[26] = c[3];
    x[31:28] = covf[3:0];
    state_n[15:0] = ccrc;
    state_n[31:16] = ccnt;
    state_n[39:32] = clast;
    state_n[40] = cok;
    state_n[41] = cseen;
    state_n[49:42] = covf;
    state_n[57:50] = crr;
    state_n[65:58] = csr;
    state_n[73:66] = cbt;
end
""",
    'Four wire bytes fold through one 16-bit reflected XOR tree in a single '
    'enabled edge and a whole Modbus frame validates as a zero residue, so the '
    'CRC is no longer the instruction-loop tax that makes software UART frames '
    'arrive late on a busy controller.', 4,
    decl=CRC_DECL, stateful=True)


# ===========================================================================
# 10  Quadrature decoder front end with bounce and jitter detection
# ===========================================================================
QJ_DECL = HELPERS + """
function [1:0] qwalk;          // 0=forward, 1=backward, 2=held, 3=diagonal
    input [3:0] pn;
    begin
        case (pn)
            4'd2, 4'd11, 4'd13, 4'd4: qwalk = 2'd0;
            4'd8, 4'd14, 4'd7, 4'd1:  qwalk = 2'd1;
            4'd3, 4'd12, 4'd9, 4'd6:  qwalk = 2'd3;
            default:                  qwalk = 2'd2;
        endcase
    end
endfunction

reg [15:0] qil, ivel, ivel_n;
reg [7:0] qbnc, qilt, qjlt, qedgc, qzlcc, qbt, qbstreak, qbstreak_n;
reg signed [31:0] qpos, qpos_n, qdevs, qvn, qdeva;
reg [1:0] qps, qns, qdir, qmode;
reg qedg, qzlc;
reg qillegal, qbounce, qjitter, qzr, qcount, qgate, qachange, qrising;
reg qprevz, qzl, qarm, qchatter;
"""

core('quadrature_jitter',
    'Quadrature encoder front end, one edge event per accepted beat, with '
    'programmable x1/x2/x4 counting, contact-bounce rejection, illegal '
    'diagonal-state detection, a binary-scaled velocity estimator and a jitter '
    'window measured against that estimate. The two-bit code is {A,B}. a[1:0]='
    'the new {A,B} state, a[2]=the Z (index) level, a[31:3] must be zero. '
    'b[15:0]=the interval in ticks since the previous edge event, b[31:16] must '
    'be zero. c[1:0]=the count mode: 0=x1 (only A rising edges count), 1=x2 '
    '(every A change counts), 2=x4 (every legal transition counts), 3 is '
    'malformed. c[15:8]=BOUNCE_MIN ticks: an edge arriving sooner than that is '
    'bounced, and a bounce leaves the previous state, the position and the '
    'velocity estimate untouched. c[23:16]=CHATTER_MAX, the number of '
    'consecutive bounces that faults (0 disables that check). c[26:24]=JT, so '
    'the jitter window is (velocity>>JT)+1 ticks either side of the velocity '
    'estimate. c[29:27] must be zero, c[30]=1 arms the Z origin (a rising Z '
    'clears the position instead of only latching), c[31]=1 clears the position, '
    'velocity, streaks and counters and takes this beat state word as the '
    'reference state, so no transition is counted on a restart beat. A beat with '
    'a must-be-zero bit set or mode 3 is malformed: result=aux=0, fault=1, state '
    'kept. The Gray walk 00,10,11,01 is forward (+1) and its reverse is backward '
    '(-1), so A leads B for clockwise; 00 to 11, 11 to 00, 10 to 01 and 01 to 10 '
    'are diagonal transitions: they are illegal (glitch or missed edge), they '
    'fault, and they do not move the position, although the reference state does '
    'follow the observed lines. An accepted edge updates the velocity estimate '
    'by vel := clamp16u(vel + ((interval - vel)>>>4)) and, when vel is '
    'nonzero, compares |interval-vel| against (vel>>JT)+1; outside that window '
    'is a jitter violation, which faults. A rising Z sets the Z-latch flag, '
    'counts, and clears the position when the origin is armed. result = the '
    'signed 32-bit position after the beat. aux[15:0]=the velocity estimate (the '
    'inter-edge interval EWMA), aux[17:16]=the reference state used by the next '
    'beat, aux[19:18]=this beat state, aux[20]=a count was applied, aux[21]=the '
    'count was negative, aux[22]=illegal diagonal transition, aux[23]=bounce, '
    'aux[24]=jitter violation, aux[25]=Z rising, aux[26]=restart applied, '
    'aux[27]=Z origin armed, aux[31:28]=saturating illegal-transition count '
    '[3:0]. State: position state[31:0] signed, reference state state[33:32], '
    'previous Z state[34], velocity estimate state[50:35], last interval '
    'state[66:51], saturating bounce streak state[74:67], saturating illegal '
    'count state[82:75], saturating jitter count state[90:83], saturating '
    'accepted edge count state[98:91], saturating bounce count state[106:99], '
    'origin armed state[107], saturating Z latch count state[115:108], '
    'saturating beat count state[123:116].',
    """
qil=16'd0; ivel=16'd0; ivel_n=16'd0;
qbnc=8'd0; qilt=8'd0; qjlt=8'd0; qedgc=8'd0; qzlcc=8'd0; qbt=8'd0;
qedg=1'b0; qzlc=1'b0;
qbstreak=8'd0; qbstreak_n=8'd0;
qpos=32'sd0; qpos_n=32'sd0; qdevs=32'sd0; qvn=32'sd0; qdeva=32'sd0;
qps=2'd0; qns=2'd0; qdir=2'd2; qmode=2'd0;
qillegal=1'b0; qbounce=1'b0; qjitter=1'b0; qzr=1'b0; qcount=1'b0;
qgate=1'b0; qachange=1'b0; qrising=1'b0;
qprevz=1'b0; qzl=1'b0; qarm=1'b0; qchatter=1'b0;
if (a[31:3] != 0 || b[31:16] != 0 || c[29:27] != 0 || c[1:0] == 2'd3) begin
    f = 1'b1;
end else begin
    qns = a[1:0];
    qzl = a[2];
    qil = b[15:0];
    qmode = c[1:0];
    qarm = c[31] ? c[30] : state_r[107];
    if (c[31]) begin
        qps = qns;
        qpos_n = 32'sd0;
        ivel_n = 16'd0;
        qbstreak_n = 8'd0;
    end else begin
        qps = state_r[33:32];
        qprevz = state_r[34];
        qpos = $signed(state_r[31:0]);
        ivel = state_r[50:35];
        qbstreak = state_r[74:67];
        qpos_n = qpos;
        ivel_n = ivel;
        qbstreak_n = qbstreak;
        qdir = qwalk({qps, qns});
        qillegal = (qdir == 2'd3);
        qachange = (qps[1] != qns[1]);
        qrising = (!qps[1]) && qns[1];
        qzr = (!qprevz) && qzl;
        if (qillegal) begin
            qpos_n = qpos;
            qbstreak_n = 8'd0;
        end else if (qil < {8'd0, c[15:8]}) begin
            qbounce = 1'b1;
            if (qbstreak != 8'hFF) qbstreak_n = qbstreak + 8'd1;
            if (c[23:16] != 8'd0 && qbstreak_n >= c[23:16]) qchatter = 1'b1;
        end else begin
            qbstreak_n = 8'd0;
            qedg = 1'b1;
            qgate = (qmode == 2'd0) ? qrising
                  : ((qmode == 2'd1) ? qachange : 1'b1);
            qcount = qgate && (qdir != 2'd2);
            if (qcount) qpos_n = (qdir == 2'd1) ? (qpos - 32'sd1)
                                                : (qpos + 32'sd1);
            qdevs = $signed({16'd0, qil}) - $signed({16'd0, ivel});
            if (ivel != 16'd0) begin
                qdeva = (qdevs < 32'sd0) ? -qdevs : qdevs;
                if (qdeva > ($signed({16'd0, (ivel >> c[26:24])}) + 32'sd1))
                    qjitter = 1'b1;
                qvn = $signed({16'd0, ivel}) + (qdevs >>> 4);
                if (qvn < 32'sd0) qvn = 32'sd0;
                else if (qvn > 32'sd65535) qvn = 32'sd65535;
                ivel_n = qvn[15:0];
            end else begin
                ivel_n = qil;
            end
        end
        if (qzr) begin
            qzlc = 1'b1;
            if (qarm) qpos_n = 32'sd0;
        end
    end
    if (qillegal || qjitter || qchatter) f = 1'b1;
    qilt = sat8(c[31] ? 8'd0 : state_r[82:75], qillegal ? 8'd1 : 8'd0);
    qjlt = sat8(c[31] ? 8'd0 : state_r[90:83], qjitter ? 8'd1 : 8'd0);
    qedgc = sat8(c[31] ? 8'd0 : state_r[98:91], qedg ? 8'd1 : 8'd0);
    qbnc = sat8(c[31] ? 8'd0 : state_r[106:99], qbounce ? 8'd1 : 8'd0);
    qzlcc = sat8(c[31] ? 8'd0 : state_r[115:108], qzlc ? 8'd1 : 8'd0);
    qbt = sat8(c[31] ? 8'd0 : state_r[123:116], 8'd1);
    r = qpos_n;
    x[15:0] = ivel_n;
    x[17:16] = (c[31] || qillegal) ? qns : (qbounce ? qps : qns);
    x[19:18] = qns;
    x[20] = qcount;
    x[21] = qcount && (qdir == 2'd1);
    x[22] = qillegal;
    x[23] = qbounce;
    x[24] = qjitter;
    x[25] = qzr;
    x[26] = c[31];
    x[27] = qarm;
    x[31:28] = qilt[3:0];
    state_n[31:0] = qpos_n;
    state_n[33:32] = (c[31] || qillegal) ? qns : (qbounce ? qps : qns);
    state_n[34] = qzl;
    state_n[50:35] = ivel_n;
    state_n[66:51] = qil;
    state_n[74:67] = qbstreak_n;
    state_n[82:75] = qilt;
    state_n[90:83] = qjlt;
    state_n[98:91] = qedgc;
    state_n[106:99] = qbnc;
    state_n[107] = qarm;
    state_n[115:108] = qzlcc;
    state_n[123:116] = qbt;
end
""",
    'The 16-entry Gray-walk legality table, the bounce window, the jitter '
    'window against a binary-scaled velocity estimate and the x1/x2/x4 gating '
    'all resolve on the edge event itself, so a glitch or a chatter burst is '
    'caught at its own nanosecond-scale width instead of being averaged away by '
    'a CPU poll that is far slower than the signal.', 1,
    decl=QJ_DECL, stateful=True)


# ===========================================================================
# Integer models
# ===========================================================================
# Each model reproduces the field layout and the arithmetic of its kernel, but
# through a different route: real multiplies instead of the parity-decomposed
# shift/add forms, a GF(2) column matrix instead of the bit-serial CRC register,
# a Gray-sequence index walk instead of the 16-entry case table, and Python's
# naturally arithmetic right shift instead of the signed >>> forms.


def bits(value, hi, lo):
    """value[hi:lo] as an unsigned field."""
    return (value >> lo) & ((1 << (hi - lo + 1)) - 1)


def sc(value, width):
    """value read as a two-complement number of `width` bits."""
    value &= (1 << width) - 1
    return value - (1 << width) if (value >> (width - 1)) & 1 else value


def getf(state, lo, width):
    return (state >> lo) & ((1 << width) - 1)


def setf(state, lo, width, value):
    mask = ((1 << width) - 1) << lo
    return (state & ~mask) | ((value & ((1 << width) - 1)) << lo)


def sat8(first, second):
    total = first + second
    return 255 if total > 255 else total


def clamp(value, lo, hi):
    return lo if value < lo else (hi if value > hi else value)


def rhu(value):
    """round_half_up of a 1/4096 scaled correction."""
    return (value + 2048) >> 12


MASK64 = (1 << 64) - 1


def gain_mul(gain, residual):
    """gain * residual for the 12-bit signed slice pair, model side multiply."""
    return gain * residual


# --- CRC-16/MODBUS as a GF(2) column matrix --------------------------------
def _bit_serial(byte_or_reg):
    value = byte_or_reg & 0xFFFF
    for _ in range(8):
        value = ((value >> 1) ^ 0xA001) if (value & 1) else (value >> 1)
    return value


CRC_COL = [_bit_serial(1 << index) for index in range(16)]


def crc16_fold(crc, data):
    """One byte folded through the reflected register, XOR-matrix form."""
    mixed = crc ^ data
    out = 0
    for index in range(16):
        if (mixed >> index) & 1:
            out ^= CRC_COL[index]
    return out


def crc8_fold(crc, data):
    """CRC8/MAXIM (poly 0x31 reflected as 0x8C, init 0) one byte at a time."""
    value = crc ^ data
    for _ in range(8):
        value = ((value >> 1) ^ 0x8C) if (value & 1) else (value >> 1)
    return value & 0xFF


OW_COMMANDS = (0x33, 0x0F, 0xCC, 0xA5, 0x96, 0x69, 0x3C, 0xEC)


# --- quadrature walk derived from the Gray cycle index, not a case table ---
QSEQ = {0b00: 0, 0b10: 1, 0b11: 2, 0b01: 3}


def qwalk_model(prev, nxt):
    """0 forward, 1 backward, 2 held, 3 diagonal (same encoding as the RTL)."""
    step = (QSEQ[nxt] - QSEQ[prev]) % 4
    return {0: 2, 1: 0, 2: 3, 3: 1}[step]


def mdl_mahony(a, b, c, state):
    if bits(a, 31, 24) or bits(b, 31, 16) or bits(c, 15, 12) or bits(c, 29, 16):
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    if res and bits(c, 30, 30):
        angle = bits(b, 15, 0)
        aligned = setf(state, 0, 16, angle)
        aligned = setf(aligned, 16, 16, angle)
        aligned = setf(aligned, 32, 16, 0)
        aligned = setf(aligned, 48, 16, 0)
        aligned = setf(aligned, 64, 1, 0)
        return (angle << 16) | angle, 1 << 12, 0, aligned
    a_h = sc(bits(a, 11, 0), 12)
    a_v = sc(bits(a, 23, 12), 12)
    plane = 0 if res else getf(state, 64, 1)
    roll = 0 if res else getf(state, 0, 16)
    pitch = 0 if res else getf(state, 16, 16)
    angle = pitch if plane else roll
    grid = (angle >> 10) & 0x3F
    # e = a_h*cos(th) - a_v*sin(th), (sin,cos) from the Q11 64-point grid
    error = a_h * SIN_TAB[(grid + 16) & 63] - a_v * SIN_TAB[grid]
    zero_g = (a_h == 0) and (a_v == 0)
    cur = 0 if res else sc(getf(state, 48, 16) if plane else getf(state, 32, 16), 16)
    other = 0 if res else (getf(state, 32, 16) if plane else getf(state, 48, 16))
    new_int = cur
    int_sat = corr_sat = 0
    raw_corr = 0
    if zero_g:
        corr = 0
    else:
        prop = error >> bits(c, 3, 0)
        new_int = cur + (error >> bits(c, 7, 4))
        if new_int > 32767:
            new_int, int_sat = 32767, 1
        elif new_int < -32768:
            new_int, int_sat = -32768, 1
        raw_corr = prop + (new_int >> bits(c, 11, 8))
        corr = clamp(raw_corr, -8388608, 8388607)
        corr_sat = 1 if corr != raw_corr else 0
    fault = 1 if (zero_g or int_sat or corr_sat) else 0
    total = angle + bits(b, 15, 0) + corr
    wrapped = 1 if (total < 0 or total > 65535) else 0
    new_angle = total & 0xFFFF
    result = ((new_angle << 16) | roll) if plane else ((pitch << 16) | new_angle)
    aux = setf(0, 0, 12, (error >> 11) & 0xFFF)
    aux = setf(aux, 12, 1, res)
    aux = setf(aux, 13, 1, 1 if zero_g else 0)
    aux = setf(aux, 14, 1, int_sat)
    aux = setf(aux, 15, 1, corr_sat)
    aux = setf(aux, 16, 1, wrapped)
    aux = setf(aux, 17, 1, plane)
    aux = setf(aux, 20, 12, corr & 0xFFF)
    moved = state
    moved = setf(moved, 0, 16, roll if plane else new_angle)
    moved = setf(moved, 16, 16, new_angle if plane else pitch)
    moved = setf(moved, 32, 16, other if plane else new_int)
    moved = setf(moved, 48, 16, new_int if plane else other)
    moved = setf(moved, 64, 1, 1 - plane)
    moved = setf(moved, 72, 8, sat8(0 if res else getf(state, 72, 8), 1))
    moved = setf(moved, 80, 8, sat8(0 if res else getf(state, 80, 8),
                                    1 if fault else 0))
    return result & MASK, aux & MASK, fault, moved


def mdl_kalman1(a, b, c, state):
    if bits(a, 31, 12) or bits(b, 31, 12) or bits(c, 28, 4):
        return 0, 0, 1, state
    if bits(c, 31, 31):
        gain = bits(b, 11, 0)
        if gain == 0 or gain > 0x7FF:
            return 0, 0, 1, state
        moved = setf(state, 12, 12, gain)
        moved = setf(moved, 0, 12, 0)
        moved = setf(moved, 24, 12, 0)
        moved = setf(moved, 36, 1, 1)
        for lo in (37, 45, 53):
            moved = setf(moved, lo, 8, 0)
        return 0, 1 << 29, 0, moved
    if not getf(state, 36, 1):
        return 0, 0, 1, state
    gain = getf(state, 12, 12)
    var = getf(state, 24, 12)
    estimate = sc(getf(state, 0, 12), 12)
    measure = sc(bits(a, 11, 0), 12)
    residual = 0
    predict = gate = x_sat = v_sat = 0
    fault = 0
    new_var = var
    moved = state
    if bits(c, 30, 30):
        predict = 1
    else:
        residual = measure - estimate
        magnitude = -residual if residual < 0 else residual
        if bits(c, 29, 29) and magnitude > (var + (var >> bits(c, 3, 0)) + 1):
            gate = fault = 1
            moved = setf(moved, 37, 8, sat8(getf(state, 37, 8), 1))
        else:
            raw = estimate + rhu(gain_mul(gain, residual))
            estimate = clamp(raw, -2048, 2047)
            x_sat = 1 if raw != estimate else 0
            new_var = var + ((magnitude - var) >> 3)
            clamped = clamp(new_var, 0, 4095)
            v_sat = 1 if clamped != new_var else 0
            new_var = clamped
            if x_sat or v_sat:
                fault = 1
            moved = setf(moved, 0, 12, estimate)
            moved = setf(moved, 24, 12, new_var)
            moved = setf(moved, 45, 8, sat8(getf(state, 45, 8), 1))
            moved = setf(moved, 53, 8, sat8(getf(state, 53, 8), 1 if (x_sat or v_sat)
                                             else 0))
    result = sc(estimate, 12)
    shown = var if (predict or gate) else new_var
    aux = setf(0, 0, 13, residual & 0x1FFF)
    aux = setf(aux, 13, 12, shown)
    aux = setf(aux, 25, 1, x_sat)
    aux = setf(aux, 26, 1, gate)
    aux = setf(aux, 27, 1, predict)
    aux = setf(aux, 28, 1, v_sat)
    moved = setf(moved, 12, 12, gain)
    moved = setf(moved, 36, 1, 1)
    return result & MASK, aux & MASK, fault, moved


def mdl_kalman2(a, b, c, state):
    if bits(a, 31, 24) or bits(b, 31, 24) or bits(c, 29, 24):
        return 0, 0, 1, state
    if bits(c, 31, 31):
        gains = (bits(b, 11, 0), bits(b, 23, 12), bits(c, 11, 0), bits(c, 23, 12))
        if any(gain == 0 or gain > 0x7FF for gain in gains):
            return 0, 0, 1, state
        moved = setf(state, 0, 12, 0)
        moved = setf(moved, 12, 12, 0)
        for index, lo in enumerate((24, 36, 48, 60)):
            moved = setf(moved, lo, 12, gains[index])
        moved = setf(moved, 72, 1, 1)
        moved = setf(moved, 73, 13, 0)
        moved = setf(moved, 86, 13, 0)
        moved = setf(moved, 99, 8, 0)
        moved = setf(moved, 107, 8, 0)
        return 0, 1 << 17, 0, moved
    if not getf(state, 72, 1):
        return 0, 0, 1, state
    mode = bits(c, 30, 30)
    position = sc(getf(state, 0, 12), 12)
    velocity = sc(getf(state, 12, 12), 12)
    predicted = clamp(position + velocity, -2048, 2047)
    pred_sat = 1 if predicted != position + velocity else 0
    residual = (sc(bits(a, 23, 12), 12) - velocity) if mode \
        else (sc(bits(a, 11, 0), 12) - predicted)
    gain_p = getf(state, 48, 12) if mode else getf(state, 24, 12)
    gain_v = getf(state, 60, 12) if mode else getf(state, 36, 12)
    raw_p = predicted + rhu(gain_mul(gain_p, residual))
    raw_v = velocity + rhu(gain_mul(gain_v, residual))
    position = clamp(raw_p, -2048, 2047)
    velocity = clamp(raw_v, -2048, 2047)
    pos_sat = 1 if raw_p != position else 0
    vel_sat = 1 if raw_v != velocity else 0
    fault = 1 if (pos_sat or vel_sat or pred_sat) else 0
    magnitude = -residual if residual < 0 else residual
    peak = getf(state, 86, 13)
    if magnitude > peak:
        peak = magnitude
    result = ((velocity & 0xFFF) << 12) | (position & 0xFFF)
    aux = setf(0, 0, 13, residual & 0x1FFF)
    aux = setf(aux, 13, 1, pred_sat)
    aux = setf(aux, 14, 1, pos_sat)
    aux = setf(aux, 15, 1, vel_sat)
    aux = setf(aux, 16, 1, mode)
    aux = setf(aux, 18, 13, peak)
    moved = state
    moved = setf(moved, 0, 12, position)
    moved = setf(moved, 12, 12, velocity)
    moved = setf(moved, 73, 13, residual)
    moved = setf(moved, 86, 13, peak)
    moved = setf(moved, 99, 8, sat8(getf(state, 99, 8), 1))
    moved = setf(moved, 107, 8, sat8(getf(state, 107, 8), 1 if fault else 0))
    return result & MASK, aux & MASK, fault, moved


def mdl_ca(a, b, c, state):
    if bits(b, 31, 8) or bits(c, 30, 23):
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    mask = bits(c, 19, 4)
    cells = bin(mask).count('1')
    log2 = {2: 1, 4: 2, 8: 3, 16: 4}.get(cells, 0)
    is_pow = (cells >= 2) and ((cells & (cells - 1)) == 0)
    cut = bits(c, 3, 0)
    sel_cut = 1 if ((mask >> cut) & 1) else 0
    guard = 1 if ((not is_pow) or sel_cut) else 0
    total = 0
    for index in range(16):
        if (mask >> index) & 1:
            total += getf(state, 8 * index, 8)
    mean = total >> log2
    threshold = mean + (mean >> bits(c, 22, 20)) + bits(b, 7, 0)
    cell = getf(state, 8 * cut, 8)
    hit = 1 if (not guard and cell > threshold) else 0
    miss = 1 if (not guard and cell <= threshold) else 0
    hits = sat8(0 if res else getf(state, 128, 8), 1 if hit else 0)
    misses = sat8(0 if res else getf(state, 136, 8), 1 if miss else 0)
    invalids = sat8(0 if res else getf(state, 144, 8), 1 if guard else 0)
    beats = sat8(0 if res else getf(state, 152, 8), 1)
    result = (cell & 0xFF) | ((mean & 0xFF) << 8) | (hit << 16) | (miss << 17) \
        | (guard << 18) | (res << 19) | ((total & 0xFFF) << 20)
    aux = setf(0, 0, 13, threshold & 0x1FFF)
    aux = setf(aux, 13, 1, 0 if is_pow else 1)
    aux = setf(aux, 14, 1, sel_cut)
    aux = setf(aux, 15, 1, res)
    aux = setf(aux, 16, 4, log2)
    aux = setf(aux, 20, 4, invalids)
    aux = setf(aux, 24, 8, beats)
    moved = state
    # The slide is the RTL's `{a, state_r[127:32]}`: the new quad lands in the
    # four newest cells (state[127:96], cells 12..15) and the previous cells
    # 4..15 drop to 0..11, so cell 0 stays the oldest.  `<< 32` here overlapped
    # the incoming quad with the old cells 8..11 instead of moving it to the top
    # of the window.
    moved = setf(moved, 0, 128, ((a & MASK) << 96) if res
                 else (((a & MASK) << 96) | getf(state, 32, 96)))
    moved = setf(moved, 128, 8, hits)
    moved = setf(moved, 136, 8, misses)
    moved = setf(moved, 144, 8, invalids)
    moved = setf(moved, 152, 8, beats)
    return result & MASK, aux & MASK, (1 if guard else 0), moved


def mdl_man(a, b, c, state):
    if bits(c, 29, 6):
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    phase = 0 if res else getf(state, 0, 1)
    if bits(c, 30, 30):
        spread = 0
        for index in range(32):
            if (a >> index) & 1:
                spread |= 1 << (2 * index)
        channel = ((spread << 1) & MASK64) | ((~spread) & 0x5555555555555555)
        return channel & MASK, (channel >> 32) & MASK, 0, (0 if res else state)
    pool = (((b & MASK) << 33) | ((a & MASK) << 1)
            | (0 if res else getf(state, 1, 1)))
    even = [(pool >> (2 * index)) & 1 for index in range(32)]
    odd = [(pool >> (2 * index + 1)) & 1 for index in range(32)]
    next_odd = [(pool >> (2 * index + 2)) & 1 for index in range(32)]
    ill0 = [1 if odd[index] == next_odd[index] else 0 for index in range(32)]
    ill1 = [1 if even[index] == odd[index] else 0 for index in range(32)]
    vio0 = sum(ill0)
    vio1 = sum(ill1)
    data = odd if phase else next_odd
    illegal = ill1 if phase else ill0
    used = vio1 if phase else vio0
    score0 = 0 if res else getf(state, 2, 8)
    score1 = 0 if res else getf(state, 10, 8)
    new0 = clamp(score0 + ((vio0 - score0) >> 2), 0, 255)
    new1 = clamp(score1 + ((vio1 - score1) >> 2), 0, 255)
    nxt = 1 if new1 < new0 else (0 if new0 < new1 else phase)
    streak = 0 if res else getf(state, 18, 6)
    fault = 1 if any(illegal) else 0
    if fault:
        streak = streak if streak == 0x3F else streak + 1
    else:
        streak = 0
    limit = bits(c, 5, 0)
    lost = 1 if (limit != 0 and streak >= limit) else 0
    if lost:
        streak = 0
    result = 0
    for index in range(32):
        result |= data[index] << index
    bits_done = ((0 if res else getf(state, 32, 16)) + 32) & 0xFFFF
    aux = setf(0, 0, 6, vio0)
    aux = setf(aux, 6, 6, vio1)
    aux = setf(aux, 12, 1, phase)
    aux = setf(aux, 13, 1, nxt)
    aux = setf(aux, 14, 1, lost)
    aux = setf(aux, 15, 1, res)
    aux = setf(aux, 16, 6, streak)
    aux = setf(aux, 22, 8, (new1 - new0) & 0xFF)
    moved = state
    moved = setf(moved, 0, 1, nxt)
    moved = setf(moved, 1, 1, bits(b, 31, 31))
    moved = setf(moved, 2, 8, new0)
    moved = setf(moved, 10, 8, new1)
    moved = setf(moved, 18, 6, streak)
    moved = setf(moved, 24, 8, 0 if res else sat8(getf(state, 24, 8), used))
    moved = setf(moved, 32, 16, bits_done)
    return result & MASK, aux & MASK, fault, moved


def mdl_dmx(a, b, c, state):
    if (bits(a, 31, 17) or bits(b, 31, 16) or bits(c, 29, 12)
            or bits(b, 7, 0) < 10 or bits(b, 15, 8) == 0
            or bits(c, 5, 0) == 0 or bits(c, 5, 0) > 15):
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    flush_beat = bits(c, 30, 30)
    level = bits(a, 16, 16)
    width = bits(a, 15, 0)
    nominal = 1 << bits(c, 5, 0)
    shift = bits(c, 11, 8)
    jitter = 0x7FFF if shift == 0 else (nominal >> shift)
    tvar = 1 if (shift != 0 and (width < nominal - jitter - 1
                                 or width > nominal + jitter + 1)) else 0
    low_run = 0 if res else getf(state, 18, 8)
    high_run = 0 if res else getf(state, 26, 8)
    position = 0 if res else getf(state, 34, 4)
    byte = 0 if res else getf(state, 38, 8)
    slots = 0 if res else getf(state, 0, 9)
    check = 0 if res else getf(state, 9, 8)
    armed = 0 if res else getf(state, 17, 1)
    valid = getf(state, 46, 1)
    last_check = getf(state, 47, 8)
    last_slots = getf(state, 55, 9)
    low_n = 0 if level else sat8(low_run, 1)
    high_n = sat8(high_run, 1) if level else 0
    is_break = 1 if ((not level) and low_n == bits(b, 7, 0)) else 0
    pos_n, byte_n, slots_n, check_n = position, byte, slots, check
    armed_n = armed
    frame_viol = over_flow = byte_committed = 0
    if is_break:
        pos_n = byte_n = slots_n = check_n = 0
        armed_n = 1
    elif not level:
        if position == 0:
            pos_n = 1
        elif position <= 8:
            byte_n = (byte | (1 << (position - 1))) & 0xFF
            pos_n = position + 1
        else:
            frame_viol = 1
    elif not armed and low_run != 0:
        frame_viol = 1
        pos_n = 0
        byte_n = 0
    elif position == 0:
        pos_n = 0
    elif position <= 8:
        pos_n = position + 1
    elif slots == 512:
        over_flow = 1
        pos_n = 0
        byte_n = 0
    else:
        slots_n = slots + 1
        check_n = check ^ byte
        byte_committed = 1
        pos_n = 0
        byte_n = 0
    mab = 1 if (level and position == 0 and armed
               and high_n == bits(b, 15, 8) and slots_n != 0) else 0
    do_flush = 1 if (flush_beat and armed and not is_break and slots_n != 0) else 0
    commit = 1 if ((is_break and armed and slots != 0) or mab or do_flush) else 0
    counted = slots if is_break else slots_n
    folded = check if is_break else check_n
    frames = 0 if res else getf(state, 80, 8)
    if commit:
        valid = 1
        last_slots = counted
        last_check = folded
        frames = sat8(0 if res else getf(state, 80, 8), 1)
        if not is_break:
            slots_n = 0
            check_n = 0
            pos_n = 0
            byte_n = 0
            armed_n = 0
    tvar_c = sat8(0 if res else getf(state, 64, 8), 1 if tvar else 0)
    tviol_c = sat8(0 if res else getf(state, 72, 8), 1 if (frame_viol or over_flow)
                   else 0)
    beat_c = sat8(0 if res else getf(state, 88, 8), 1)
    fault = 1 if (tvar or frame_viol or over_flow) else 0
    result = (byte_n & 0xFF) | ((slots_n & 0x1FF) << 8) | (byte_committed << 17) \
        | (is_break << 18) | (commit << 19) | (tvar << 20) | (frame_viol << 21) \
        | (over_flow << 22) | (res << 23) | ((pos_n & 0xF) << 24) \
        | (armed_n << 28) | (level << 29)
    aux = setf(0, 0, 8, check_n)
    aux = setf(aux, 8, 8, low_n)
    aux = setf(aux, 16, 8, high_n)
    aux = setf(aux, 24, 1, valid)
    aux = setf(aux, 25, 1, flush_beat)
    aux = setf(aux, 28, 4, tvar_c)
    moved = state
    for lo, width, value in ((0, 9, slots_n), (9, 8, check_n), (17, 1, armed_n),
                             (18, 8, low_n), (26, 8, high_n), (34, 4, pos_n),
                             (38, 8, byte_n), (46, 1, valid), (47, 8, last_check),
                             (55, 9, last_slots), (64, 8, tvar_c), (72, 8, tviol_c),
                             (80, 8, frames), (88, 8, beat_c)):
        moved = setf(moved, lo, width, value)
    return result & MASK, aux & MASK, fault, moved


def mdl_onewire(a, b, c, state):
    if bits(a, 31, 17) or bits(b, 15, 0) or bits(c, 29, 24):
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    overdrive = bits(c, 30, 30)
    level = bits(a, 16, 16)
    elapsed = bits(a, 15, 0)
    reset_lo = 30 if overdrive else 480
    pres_lo = 54 if overdrive else 540
    pres_hi = 150 if overdrive else 720
    one_hi = 6 if overdrive else 15
    zero_lo = 8 if overdrive else 60
    zero_hi = 17 if overdrive else 120
    slot_max = zero_hi + (zero_hi >> 2)
    shift_reg = 0 if res else getf(state, 0, 8)
    bit_pos = 0 if res else getf(state, 8, 4)
    crc = 0 if res else getf(state, 12, 8)
    byte_count = 0 if res else getf(state, 20, 8)
    pending_low = 0 if res else getf(state, 28, 16)
    pending = 0 if res else getf(state, 44, 1)
    pending_value = 0 if res else getf(state, 45, 1)
    last_byte = 0 if res else getf(state, 46, 8)
    shift_n, pos_n, crc_n, bytes_n, low_n = (shift_reg, bit_pos, crc, byte_count,
                                            pending_low)
    pending_n = pending
    total = 0
    stuck = no_pres = short_slot = long_slot = recovery = slot_viol = 0
    reset_seen = presence = accepted = completed = known = overflow = 0
    if not level:
        if pending:
            slot_viol = 1
        pending_n = 0
        low_n = elapsed
        if elapsed > pres_hi:
            stuck = 1
        elif elapsed >= reset_lo:
            reset_seen = 1
            shift_n = pos_n = crc_n = bytes_n = 0
            if elapsed >= pres_lo:
                presence = 1
            else:
                no_pres = 1
        elif 1 <= elapsed <= one_hi:
            pending_n = 1
            pending_value = 1
        elif zero_lo <= elapsed <= zero_hi:
            pending_n = 1
            pending_value = 0
        elif elapsed < zero_lo:
            short_slot = 1
        else:
            long_slot = 1
    elif pending:
        total = pending_low + elapsed
        pending_n = 0
        rec_min = bits(c, 7, 0)
        if rec_min != 0 and elapsed < rec_min:
            recovery = 1
        elif total < zero_lo or total > slot_max:
            slot_viol = 1
        else:
            accepted = 1
            shift_n = (shift_reg >> 1) | (0x80 if pending_value else 0)
            if bit_pos == 7:
                pos_n = 0
                completed = 1
                last_byte = shift_n
                limit = bits(c, 23, 16)
                if limit != 0 and byte_count >= limit:
                    overflow = 1
                else:
                    crc_n = crc8_fold(crc, shift_n)
                    known = 1 if shift_n in OW_COMMANDS else 0
                    bytes_n = (byte_count + 1) & 0xFF
            else:
                pos_n = (bit_pos + 1) & 0xF
    fault = 1 if (stuck or no_pres or short_slot or long_slot or recovery
                  or slot_viol or overflow) else 0
    viol_c = sat8(0 if res else getf(state, 54, 8), 1 if fault else 0)
    byte_total = sat8(0 if res else getf(state, 62, 8), 1 if completed else 0)
    reset_total = sat8(0 if res else getf(state, 70, 8), 1 if reset_seen else 0)
    pres_total = sat8(0 if res else getf(state, 78, 8), 1 if presence else 0)
    bit_total = sat8(0 if res else getf(state, 86, 8), 1 if accepted else 0)
    beat_total = sat8(0 if res else getf(state, 94, 8), 1)
    result = (shift_n & 0xFF) | ((crc_n & 0xFF) << 8) | (accepted << 16) \
        | (completed << 17) | (reset_seen << 18) | (presence << 19) \
        | (no_pres << 20) | (known << 21) \
        | ((1 if (short_slot or long_slot or slot_viol) else 0) << 22) \
        | (res << 23) | ((pos_n & 0xF) << 24) | (pending_n << 28) | (level << 29) \
        | (recovery << 30) | (overflow << 31)
    aux = setf(0, 0, 8, bytes_n)
    aux = setf(aux, 8, 8, total & 0xFF)
    aux = setf(aux, 16, 8, low_n & 0xFF)
    aux = setf(aux, 24, 1, overdrive)
    aux = setf(aux, 25, 1, stuck)
    aux = setf(aux, 28, 4, viol_c)
    moved = state
    for lo, width, value in ((0, 8, shift_n), (8, 4, pos_n), (12, 8, crc_n),
                             (20, 8, bytes_n), (28, 16, low_n), (44, 1, pending_n),
                             (45, 1, pending_value), (46, 8, last_byte),
                             (54, 8, viol_c), (62, 8, byte_total), (70, 8, reset_total),
                             (78, 8, pres_total), (86, 8, bit_total), (94, 8, beat_total)):
        moved = setf(moved, lo, width, value)
    return result & MASK, aux & MASK, fault, moved


def mdl_ws2812(a, b, c, state):
    if bits(c, 29, 12) or bits(b, 31, 8):
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    high = bits(a, 15, 0)
    low = bits(a, 31, 16)
    total = (high + low) & 0xFFFF
    units = bits(c, 11, 6)
    latch_min = 400 if units == 0 else (units << 4)
    tolerance = bits(c, 1, 0)
    request = bits(c, 30, 30)
    latching = 1 if (total >= latch_min or request) else 0
    shift_reg = 0 if res else getf(state, 0, 24)
    bit_pos = 0 if res else getf(state, 24, 6)
    pixels = 0 if res else getf(state, 30, 8)
    digest = 0 if res else getf(state, 38, 8)
    last_pixel = 0 if res else getf(state, 46, 24)
    pending = getf(state, 70, 1)
    expect = bits(b, 7, 0)
    shift_n, pos_n, pix_n, dig_n = shift_reg, bit_pos, pixels, digest
    pending_n = pending
    bit_value = accepted = pixel_done = 0
    duty_bad = period_bad = truncated = length_bad = idle = 0
    if latching:
        truncated = 1 if bit_pos != 0 else 0
        length_bad = 1 if (expect != 0 and pixels != expect) else 0
        idle = 1 if (bit_pos == 0 and pixels == 0) else 0
        if not idle:
            pending_n = 1
            shift_n = pos_n = pix_n = dig_n = 0
    else:
        bit_value = 1 if high >= 5 else 0
        legal = ((1 <= high <= 4 and 5 <= low <= 8)
                 or (5 <= high <= 8 and 2 <= low <= 5))
        duty_bad = 0 if legal else 1
        on_time = (total + tolerance) & 0xFFFF
        period_bad = 1 if (on_time < 9 or total > 11 + tolerance) else 0
        accepted = 1
        shift_n = ((shift_reg << 1) | bit_value) & 0xFFFFFF
        if bit_pos == 23:
            pixel_done = 1
            last_pixel = shift_n
            pix_n = sat8(pixels, 1)
            dig_n = (digest ^ ((shift_n >> 16) & 0xFF) ^ ((shift_n >> 8) & 0xFF)
                     ^ (shift_n & 0xFF)) & 0xFF
            pos_n = 0
        else:
            pos_n = (bit_pos + 1) & 0x3F
    fault = 1 if (duty_bad or period_bad or truncated or length_bad) else 0
    duty_c = sat8(0 if res else getf(state, 79, 8), 1 if duty_bad else 0)
    period_c = sat8(0 if res else getf(state, 87, 8), 1 if period_bad else 0)
    length_c = sat8(0 if res else getf(state, 95, 8), 1 if length_bad else 0)
    trunc_c = sat8(0 if res else getf(state, 103, 8), 1 if truncated else 0)
    latch_c = sat8(0 if res else getf(state, 71, 8), 1 if (latching and not idle) else 0)
    beat_c = sat8(0 if res else getf(state, 111, 8), 1)
    result = (last_pixel & 0xFF) | ((last_pixel >> 8 & 0xFF) << 8) \
        | ((last_pixel >> 16 & 0xFF) << 16) | (accepted << 24) | (bit_value << 25) \
        | (pixel_done << 26) | ((1 if (latching and not idle) else 0) << 27) \
        | (duty_bad << 28) | (period_bad << 29) | (length_bad << 30) \
        | (truncated << 31)
    aux = setf(0, 0, 8, dig_n)
    aux = setf(aux, 8, 8, pix_n)
    aux = setf(aux, 16, 8, pos_n)
    aux = setf(aux, 24, 1, res)
    aux = setf(aux, 25, 1, request)
    aux = setf(aux, 26, 1, pending_n)
    aux = setf(aux, 27, 1, idle)
    aux = setf(aux, 28, 4, duty_c)
    moved = state
    for lo, width, value in ((0, 24, shift_n), (24, 6, pos_n), (30, 8, pix_n),
                             (38, 8, dig_n), (46, 24, last_pixel), (70, 1, pending_n),
                             (71, 8, latch_c), (79, 8, duty_c), (87, 8, period_c),
                             (95, 8, length_c), (103, 8, trunc_c), (111, 8, beat_c)):
        moved = setf(moved, lo, width, value)
    return result & MASK, aux & MASK, fault, moved


def mdl_crc16(a, b, c, state):
    if bits(b, 31, 16) or bits(c, 29, 4):
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    want = bits(c, 3, 3)
    crc = 0xFFFF if res else getf(state, 0, 16)
    count = 0 if res else getf(state, 16, 16)
    last = 0 if res else getf(state, 32, 8)
    address = bits(b, 7, 0)
    unchecked = 1 if address == 0 else 0
    address_ok = unchecked if res else getf(state, 40, 1)
    address_seen = 0 if res else getf(state, 41, 1)
    limit = 0xFFFF if bits(b, 15, 8) == 0 else bits(b, 15, 8)
    per_beat = bits(c, 1, 0) + 1
    folded = 0
    overflow = 0
    for index in range(4):
        if index < per_beat:
            if count >= limit:
                overflow = 1
            else:
                data = bits(a, 8 * index + 7, 8 * index)
                crc = crc16_fold(crc, data)
                count = (count + 1) & 0xFFFF
                last = data
                folded += 1
                if not address_seen:
                    address_ok = 1 if (unchecked or data == address) else 0
                    address_seen = 1
    residue_ok = 1 if (want and crc == 0) else 0
    fault = 1 if (overflow or (want and crc != 0)) else 0
    overflow_c = sat8(0 if res else getf(state, 42, 8), 1 if overflow else 0)
    residue_c = sat8(0 if res else getf(state, 50, 8), 1 if (want and crc != 0) else 0)
    restart_c = sat8(0 if res else getf(state, 58, 8), 1 if res else 0)
    beat_c = sat8(0 if res else getf(state, 66, 8), 1)
    result = (crc & 0xFFFF) | (residue_ok << 16) | (address_ok << 17) \
        | (res << 18) | (overflow << 19) | (want << 20) | ((last & 0xFF) << 24)
    aux = setf(0, 0, 16, count)
    aux = setf(aux, 16, 4, folded)
    aux = setf(aux, 24, 1, address_seen)
    aux = setf(aux, 25, 1, unchecked)
    aux = setf(aux, 26, 1, want)
    aux = setf(aux, 28, 4, overflow_c)
    moved = state
    for lo, width, value in ((0, 16, crc), (16, 16, count), (32, 8, last),
                             (40, 1, address_ok), (41, 1, address_seen),
                             (42, 8, overflow_c), (50, 8, residue_c),
                             (58, 8, restart_c), (66, 8, beat_c)):
        moved = setf(moved, lo, width, value)
    return result & MASK, aux & MASK, fault, moved


def mdl_quadrature(a, b, c, state):
    if bits(a, 31, 3) or bits(b, 31, 16) or bits(c, 29, 27) or bits(c, 1, 0) == 3:
        return 0, 0, 1, state
    res = bits(c, 31, 31)
    new_state_word = bits(a, 1, 0)
    z_level = bits(a, 2, 2)
    interval = bits(b, 15, 0)
    mode = bits(c, 1, 0)
    armed = bits(c, 30, 30) if res else getf(state, 107, 1)
    position = getf(state, 0, 32) if res else sc(getf(state, 0, 32), 32)
    velocity = getf(state, 35, 16)
    streak = getf(state, 67, 8)
    reference = getf(state, 32, 2)
    previous_z = getf(state, 34, 1)
    direction = 2
    illegal = bounce = jitter = z_rise = counted = chatter = 0
    edge = z_latch = gate = 0
    pos_n = position
    vel_n = velocity
    streak_n = streak
    if res:
        reference = new_state_word
        pos_n = 0
        vel_n = 0
        streak_n = 0
    else:
        direction = qwalk_model(reference, new_state_word)
        illegal = 1 if direction == 3 else 0
        a_changed = 1 if ((reference >> 1) & 1) != ((new_state_word >> 1) & 1) else 0
        a_rising = 1 if not ((reference >> 1) & 1) and ((new_state_word >> 1) & 1) else 0
        z_rise = 1 if (not previous_z) and z_level else 0
        if illegal:
            pos_n = position
            streak_n = 0
        elif interval < bits(c, 15, 8):
            bounce = 1
            if streak != 0xFF:
                streak_n = streak + 1
            limit = bits(c, 23, 16)
            if limit != 0 and streak_n >= limit:
                chatter = 1
        else:
            streak_n = 0
            edge = 1
            gate = a_rising if mode == 0 else (a_changed if mode == 1 else 1)
            counted = 1 if (gate and direction != 2) else 0
            if counted:
                pos_n = position - 1 if direction == 1 else position + 1
            deviation = interval - velocity
            if velocity != 0:
                magnitude = -deviation if deviation < 0 else deviation
                window = (velocity >> bits(c, 26, 24)) + 1
                if magnitude > window:
                    jitter = 1
                vel_n = clamp(velocity + (deviation >> 4), 0, 65535)
            else:
                vel_n = interval
        if z_rise:
            z_latch = 1
            if armed:
                pos_n = 0
    fault = 1 if (illegal or jitter or chatter) else 0
    illegal_c = sat8(0 if res else getf(state, 75, 8), 1 if illegal else 0)
    jitter_c = sat8(0 if res else getf(state, 83, 8), 1 if jitter else 0)
    edge_c = sat8(0 if res else getf(state, 91, 8), 1 if edge else 0)
    bounce_c = sat8(0 if res else getf(state, 99, 8), 1 if bounce else 0)
    z_c = sat8(0 if res else getf(state, 108, 8), 1 if z_latch else 0)
    beat_c = sat8(0 if res else getf(state, 116, 8), 1)
    next_reference = new_state_word if (res or illegal) else \
        (reference if bounce else new_state_word)
    aux = setf(0, 0, 16, vel_n)
    aux = setf(aux, 16, 2, next_reference)
    aux = setf(aux, 18, 2, new_state_word)
    aux = setf(aux, 20, 1, counted)
    aux = setf(aux, 21, 1, 1 if (counted and direction == 1) else 0)
    aux = setf(aux, 22, 1, illegal)
    aux = setf(aux, 23, 1, bounce)
    aux = setf(aux, 24, 1, jitter)
    aux = setf(aux, 25, 1, z_rise)
    aux = setf(aux, 26, 1, res)
    aux = setf(aux, 27, 1, armed)
    aux = setf(aux, 28, 4, illegal_c)
    moved = state
    for lo, width, value in ((0, 32, pos_n), (32, 2, next_reference), (34, 1, z_level),
                             (35, 16, vel_n), (51, 16, interval), (67, 8, streak_n),
                             (75, 8, illegal_c), (83, 8, jitter_c), (91, 8, edge_c),
                             (99, 8, bounce_c), (107, 1, armed), (108, 8, z_c),
                             (116, 8, beat_c)):
        moved = setf(moved, lo, width, value)
    return pos_n & MASK, aux & MASK, fault, moved


def vel_n_zero(velocity):
    """The interval/estimate difference as the signed 32-bit cone sees it."""
    return velocity


MODEL_OF = {
    'mahony_ahrs': mdl_mahony,
    'kalman1d': mdl_kalman1,
    'kalman2d_cv': mdl_kalman2,
    'ca_correlator': mdl_ca,
    'manchester_io': mdl_man,
    'dmx512_frame': mdl_dmx,
    'onewire_slot': mdl_onewire,
    'ws2812_serial': mdl_ws2812,
    'crc16_modbus': mdl_crc16,
    'quadrature_jitter': mdl_quadrature,
}


def step(name, a, b, c, state=0):
    return MODEL_OF[name](a & MASK, b & MASK, c & MASK, state)


# ===========================================================================
# Board vectors
# ===========================================================================
# Rows 0..127 are the hardware set, so every generator lays its protocol script
# out first: a restart beat, a hand-built frame, the legal edge of each window,
# then the malformed variants. Padding rows only keep the count up and stay
# inside the interface so they can never wedge the board.

def w12(value):
    return value & 0xFFF


def pair12(lo, hi):
    """Two signed 12-bit words: lo in bits 11:0, hi in bits 23:12."""
    return w12(lo) | (w12(hi) << 12)


def man_encode(word):
    """32 data bits to 64 channel samples, split as (first half, second half)."""
    spread = 0
    for index in range(32):
        if (word >> index) & 1:
            spread |= 1 << (2 * index)
    channel = ((spread << 1) & MASK64) | ((~spread) & 0x5555555555555555)
    return channel & MASK, (channel >> 32) & MASK


def v_mahony():
    rows = []
    base = 11 | (8 << 4) | (6 << 8)
    rows.append((pair12(0, 2047), 0x0600, (1 << 31) | (1 << 30) | base))
    rows.append((pair12(0, 2047), 0, (1 << 31) | base))
    rows.append((pair12(0, 0), 0x10, base))
    rows.append((pair12(100, 100) | (1 << 24), 0, base))
    rows.append((pair12(2047, -2048), 0x10, 0))
    for index in range(5, 118):
        grid = index & 63
        a_h = SIN_TAB[grid] - 90 * ((index // 7) % 4)
        a_v = SIN_TAB[(grid + 16) & 63] + 70 * ((index // 5) % 3)
        delta = (index * 331 - 9000) & 0xFFFF
        control = (index % 13) | ((index % 9) << 4) | ((index % 6) << 8)
        if index % 40 == 0:
            control |= 1 << 31
        rows.append((pair12(a_h, a_v), delta, control))
    for index in range(118, 128):
        rows.append((pair12(-500 + index, 1900 - index), (index * 9000) & 0xFFFF,
                     (1 << 31) | (index % 12) | ((index % 8) << 4) | ((index % 5) << 8)))
    rows.append((pair12(2047, 2047), 0xFFFF, base))
    rows.append((pair12(-2048, -2048), 0xFFFF, base | (1 << 31)))
    rows.append((pair12(1, -1), 1, base))
    rows.append((pair12(-1, 1), 65535, 0))
    return rows


def v_kalman1():
    rows = []
    rows.append((w12(300), 0, 0))
    rows.append((0, 0, 1 << 31))
    rows.append((0, 0x800, 1 << 31))
    rows.append((0, 0x7FF, 1 << 31))
    rows.append((0, 1536, 1 << 31))
    for index in range(5, 104):
        sample = ((index * 61) % 4096) - 2048
        control = index & 7
        if index % 3 == 0:
            control |= 1 << 29
        if index % 25 == 0:
            rows.append((w12(sample), 1024 + (index % 400), control | (1 << 31)))
        elif index % 17 == 0:
            rows.append((w12(sample), 0, control | (1 << 30)))
        else:
            rows.append((w12(sample), 0, control))
    rows.append((w12(0), 0, (1 << 29) | 0))
    rows.append((w12(2047), 0, 0))
    rows.append((w12(2047), 0, 0))
    rows.append((w12(-2048), 0, 0))
    rows.append((w12(-2048), 0, 0))
    for index in range(104, 124):
        rows.append((w12(index * 17 - 900), 0, (1 << 29) | (index % 8)))
    rows.append((w12(500) | (1 << 12), 0, 0))
    rows.append((w12(500), 1 << 12, 0))
    rows.append((w12(500), 0, 1 << 4))
    return rows


def v_kalman2():
    rows = []
    config_b = 2047 | (1024 << 12)
    config_c = 1536 | (2047 << 12)
    rows.append((pair12(100, 100), 0, 0))
    rows.append((0, 0 | (1024 << 12), (1 << 31) | 512))
    rows.append((0, config_b, (1 << 31) | 1536 | (0 << 12)))
    rows.append((0, config_b, (1 << 31) | config_c))
    for index in range(4, 116):
        pos = ((index * 97) % 4096) - 2048
        vel = ((index * 353) % 4096) - 2048
        control = (1 << 30) if index % 4 == 0 else 0
        if index % 30 == 0:
            control |= 1 << 31
        rows.append((pair12(pos, vel), config_b, control | (index & 7)))
    for index in range(116, 126):
        rows.append((pair12(2047 if index % 2 else -2048,
                            2047 if index % 3 else -2048), 0, (1 << 30)))
    rows.append((pair12(10, 10), 0, 1 << 24))
    rows.append((pair12(10, 10) | (1 << 24), 0, 0))
    return rows


CA_MASKS = (0x0FF0, 0x00FF, 0x0F0F, 0x0003, 0x0300, 0x00C0, 0x0AA0, 0x0555,
            0xF000, 0x000F, 0x0011, 0x0770, 0x0111, 0x0E00)


def v_ca():
    rows = []
    rows.append((0, 0, 1 | (0x0FF0 << 4)))
    for index in range(1, 112):
        quad = 0
        for lane in range(4):
            level = (index * 13 + lane * 61) % 251
            if (index + lane) % 13 == 0:
                level = 255
            quad |= (level & 0xFF) << (8 * lane)
        cut = index % 16
        mask = CA_MASKS[index % len(CA_MASKS)]
        control = cut | (mask << 4) | ((index % 8) << 20)
        if index % 32 == 0:
            control |= 1 << 31
        rows.append((quad, (index * 3) & 0xFF, control))
    for index in range(112, 124):
        quad = (0x40 + index) * 0x01010101 % (1 << 32)
        rows.append((quad & MASK, 200, index % 16 | (0x0007 << 4)))
    rows.append((0x01020304, 0, 1 | (0x0001 << 4)))
    rows.append((0x01020304, 1 << 8, 1 | (0x0FF0 << 4)))
    rows.append((0x01020304, 0, (1 << 23) | 1 | (0x0FF0 << 4)))
    rows.append((0xFFFFFFFF, 255, 15 | (0x0FF0 << 4) | (7 << 20)))
    return rows


def v_man():
    rows = []
    words = [((index * 0x9E3779B9 + 0x12345) & MASK) for index in range(28)]
    words += [0x55555555, 0xAAAAAAAA, 0x0F0F0F0F, 0xF0F0F0F0, 0x0000FFFF,
              0xFFFF0000, 0x12345678, 0x9ABCDEF0, 0xDEADBEEF, 0x00000001,
              0x80000000, 0x7FFFFFFF]
    rows.append((0, 0, 1 << 31))
    stream = []
    for index, word in enumerate(words):
        stream.append(man_encode(word) + (word,))
        control = 1 << 30
        if index % 16 == 15:
            control |= 1 << 31
        rows.append((word, 0x55555555 if index % 4 == 0 else 0, control))
    for index, (lo, hi, _word) in enumerate(stream):
        control = 0x3F if index % 20 == 0 else 0
        if index % 33 == 0:
            control |= 1 << 31
        rows.append((lo, hi, control))
    for index in range(24):
        lo, hi, _word = stream[index % len(stream)]
        flip = (index * 7) % 32
        rows.append((lo ^ (1 << flip), hi, 0))
    for index in range(12):
        lo, hi, _word = stream[index % len(stream)]
        rows.append((((lo << 1) & MASK) | (0x5555AAAA >> index) & 1,
                     ((hi << 1) & MASK) | (lo >> 31), 3 + (index % 4)))
    rows.append((0, 0, 1 << 6))
    rows.append((0, 0, (1 << 30) | (1 << 31)))
    return rows


DMX_BREAK_MIN = 12
DMX_MAB_MIN = 4
DMX_TS = 5
DMX_TE = 3


def dmx_cfg(restart=False, flush=False, ts=DMX_TS, te=DMX_TE, bmin=DMX_BREAK_MIN,
            mab=DMX_MAB_MIN):
    """(b, c) for a DMX beat with the nominal timing set carried on every beat."""
    control = ts | (te << 8)
    if flush:
        control |= 1 << 30
    if restart:
        control |= 1 << 31
    return bmin | (mab << 8), control


def v_dmx():
    rows = []
    bit = 1 << DMX_TS

    def interval(level, index=0, width=bit, skew=0):
        word = dmx_cfg()
        return ((width + skew) | (level << 16), word[0], word[1])

    rows.append((bit, dmx_cfg()[0], dmx_cfg(restart=True)[1]))
    # an un-armed data pulse: the low run ends early -> framing violation
    for _ in range(3):
        rows.append(interval(0))
    rows.append(interval(1))
    # first frame: break, MAB, then bytes
    for _ in range(DMX_BREAK_MIN):
        rows.append(interval(0))
    for _ in range(DMX_MAB_MIN):
        rows.append(interval(1))
    payload = (0x00, 0xFF, 0x55, 0xA5, 0x01, 0x80, 0x7F, 0x42, 0x10, 0xC3)
    for value in payload:
        rows.append(interval(0))                       # start bit
        for position in range(8):                     # UART data is inverted
            rows.append(interval(1 if (value >> position) & 1 else 0))
        rows.append(interval(1))                       # stop bit
    for _ in range(DMX_BREAK_MIN):                    # the break commits it
        rows.append(interval(0))
    for _ in range(DMX_MAB_MIN):
        rows.append(interval(1))
    for value in (0x3C, 0x1E, 0xE7, 0x91, 0x66):
        rows.append(interval(0))
        for position in range(8):
            rows.append(interval(1 if (value >> position) & 1 else 0))
        rows.append(interval(1))
    rows.append((bit | (1 << 16), dmx_cfg()[0], dmx_cfg(flush=True)[1]))
    for _ in range(DMX_MAB_MIN):
        rows.append(interval(1))
    return rows


def v_onewire():
    rows = []
    rec_min = 10

    def beat(level, width, restart=False, overdrive=False, limit=0, recm=rec_min,
             bvalue=0, bad_c=0):
        control = recm | (limit << 16) | (1 << 31 if restart else 0) \
            | (1 << 30 if overdrive else 0) | bad_c
        return (width | (level << 16), bvalue, control)

    def byte_slots(value):
        out = []
        for position in range(8):                     # LSB first
            if (value >> position) & 1:
                out.append(beat(0, 10))
                out.append(beat(1, 55))
            else:
                out.append(beat(0, 70))
                out.append(beat(1, 20))
        return out

    rows.append(beat(1, 100, restart=True))
    rows.append(beat(0, 600))                          # reset with presence
    rows.append(beat(1, 70))
    # The board set is rows 0..127, so the two cheapest published violations are
    # walked right after the reset handshake instead of at the end of the script:
    # the 128 clean byte-slot rows that follow pushed every violation past row
    # 127, where generate.coverage_gate cannot see one and the core could never
    # be released. Neither beat leaves a pending slot, so the transaction that
    # follows is bit-identical to the one the end-of-script blocks still repeat.
    rows.append(beat(0, 480))                          # reset without presence
    rows.append(beat(1, 70))
    rows.append(beat(0, 20))                           # short-slot violation
    rows.append(beat(1, 55))
    for value in (0x33, 0xCC, 0xA5, 0x69):
        rows += byte_slots(value)
        rows += byte_slots(crc_of(value))
    rows.append(beat(0, 480))                          # reset, no presence: fault
    rows.append(beat(1, 70))
    rows += byte_slots(0x0F)
    rows += byte_slots(crc_of(0x0F))
    rows += byte_slots(0x96)                           # over-long transaction
    rows.append(beat(0, 600, limit=3))
    rows += byte_slots(0xEC)
    rows += byte_slots(crc_of(0xEC))
    rows += byte_slots(0x3C)
    rows.append(beat(0, 20))                           # short slot: fault
    rows.append(beat(1, 55))
    rows.append(beat(0, 10))
    rows.append(beat(1, 5))                            # slot total too short
    rows.append(beat(0, 70))
    rows.append(beat(1, 15, recm=30))                  # recovery violation
    rows.append(beat(0, 300))                          # long slot: fault
    rows.append(beat(1, 70))
    rows.append(beat(0, 900))                          # stuck low: fault
    rows.append(beat(1, 70))
    rows.append(beat(0, 40, overdrive=True))           # overdrive short slot
    rows.append(beat(1, 12, overdrive=True))           # overdrive slot
    rows.append(beat(0, 60, overdrive=True))
    rows.append(beat(1, 12, overdrive=True))
    rows.append(beat(0, 120, overdrive=True))          # overdrive reset
    rows.append(beat(1, 40, overdrive=True))
    rows.append(beat(0, 70, bvalue=0x100))             # malformed b
    rows.append(beat(0, 70, bad_c=1 << 24))            # malformed c
    return rows


def crc_of(value):
    """CRC8/MAXIM of one byte, the transaction's own check byte."""
    return crc8_fold(0, value)


def v_ws2812():
    rows = []

    def beat(high, low, restart=False, latch=False, pixels=0, tol=0, rstu=0,
             bad_c=False):
        control = tol | (rstu << 6) | (1 << 31 if restart else 0) \
            | (1 << 30 if latch else 0) | ((1 << 12) if bad_c else 0)
        return ((low << 16) | high, pixels, control)

    def pixel(green, red, blue):
        out = []
        for channel in (green, red, blue):
            for position in range(7, -1, -1):
                out.append(beat(6, 4) if (channel >> position) & 1
                           else beat(3, 7))
        return out

    rows.append(beat(3, 7, restart=True))
    colors = ((255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (1, 2, 3),
              (128, 64, 32), (255, 255, 255), (0, 0, 0), (17, 34, 51),
              (200, 100, 50), (0xAA, 0x55, 0xF0), (0x0F, 0xF0, 0x0F))
    for index, colour in enumerate(colors[:5]):
        rows += pixel(*colour)
        rows.append(beat(500, 0, pixels=5 if index == 4 else 0))
    # a truncated pixel then a wrong-length frame
    rows += pixel(0x12, 0x34, 0x56)[:10]
    rows.append(beat(420, 0))
    rows += pixel(0x11, 0x22, 0x33)
    rows += pixel(0x44, 0x55, 0x66)
    rows.append(beat(420, 0, pixels=3))
    rows.append(beat(2, 9))                            # duty violation
    rows.append(beat(5, 6))                            # duty violation
    rows.append(beat(9, 9))                            # period violation
    rows.append(beat(4, 4))                            # period violation
    rows.append(beat(0, 0))                            # all-low bit: duty violation
    rows.append(beat(6, 4, tol=3))
    rows.append(beat(1, 8))
    rows.append(beat(8, 2))
    rows.append(beat(6, 4, rstu=1))
    rows.append(beat(20, 4, latch=True))
    rows.append(beat(3, 7, bad_c=True))
    return rows


def v_crc16():
    rows = []
    frames = []
    for index in range(26):
        address = 1 + (index % 247)
        function = (0x03, 0x06, 0x10, 0x01, 0x02, 0x04, 0x0F)[index % 7]
        body = bytes(((index * 7 + lane * 31 + 3) & 0xFF) for lane in range(index % 4))
        message = bytes([address, function]) + body
        check = 0xFFFF
        for byte in message:
            check = crc16_fold(check, byte)
        frames.append(message + bytes((check & 0xFF, check >> 8)))
    for index, frame in enumerate(frames):
        payload, tail = frame[:-2], frame[-2:]
        control = 1 << 31
        first = payload[:4]
        rows.append((int.from_bytes(first + b'\0\0\0\0', 'little'),
                     frame[0] | (8 << 8), control | (len(first) - 1)))
        rest = payload[4:]
        for offset in range(0, len(rest), 4):
            chunk = rest[offset:offset + 4]
            rows.append((int.from_bytes(chunk + b'\0\0\0\0', 'little'),
                         frame[0], len(chunk) - 1))
        rows.append((int.from_bytes(tail + b'\0\0', 'little'),
                     frame[0], 1 | (1 << 3)))
    rows.append((0x00000000, 0x11, (1 << 31) | 0))
    rows.append((0x00000001, 0x11, 1 | (1 << 3)))      # residue failure
    rows.append((0x00000002, 0x99, 1))                 # address mismatch
    rows.append((0x03020100, 0x11 | (2 << 8), 3))      # length overflow
    rows.append((0x03020100, 1 << 16, 3))              # malformed b
    rows.append((0x03020100, 0x11, (1 << 4) | 3))      # malformed c
    return rows


def v_quadrature():
    rows = []
    walk = (0b00, 0b10, 0b11, 0b01)

    def beat(state, z=0, interval=100, mode=2, bounce=8, chatter=0, jitter=3,
             restart=False, arm=False, bad_a=0, bad_b=0, bad_c=0):
        control = mode | (bounce << 8) | (chatter << 16) | (jitter << 24) \
            | (1 << 31 if restart else 0) | (1 << 30 if arm else 0) | bad_c
        return (state | (z << 2) | bad_a, interval | bad_b, control)

    rows.append(beat(0b00, restart=True))
    pointer = 1
    for cycle in range(24):
        for step in range(4):
            rows.append(beat(walk[(pointer + step) % 4],
                             interval=90 + 11 * step + 7 * cycle,
                             mode=cycle % 3))
            pointer += 1
        if cycle % 4 == 3:                             # index pulse every 4th cycle
            rows.append(beat(walk[pointer % 4], z=1, interval=140))
            rows.append(beat(walk[(pointer + 1) % 4], z=0, interval=120))
            pointer += 2
    rows.append(beat(0b11, interval=200))              # 00 -> 11 diagonal: illegal
    rows.append(beat(0b00, interval=200))              # 11 -> 00 diagonal: illegal
    rows.append(beat(0b01, interval=200))              # 00 -> 01 backward
    rows.append(beat(0b10, interval=200))              # 01 -> 10 diagonal: illegal
    for _ in range(4):
        rows.append(beat(0b10, interval=3))            # bounce burst
        rows.append(beat(0b00, interval=3))
    rows.append(beat(0b10, interval=3, chatter=3))     # chatter fault
    rows.append(beat(0b00, interval=100, restart=True))
    for value in (5000, 9000, 1, 60, 260):
        rows.append(beat(0b11, interval=value))         # jitter window
        rows.append(beat(0b01, interval=value))
        rows.append(beat(0b00, interval=value))
        rows.append(beat(0b10, interval=value))
    rows.append(beat(0b00, interval=100, restart=True, arm=True))
    rows.append(beat(0b00, z=1, interval=100, mode=0))  # Z clears the origin
    rows.append(beat(0b10, interval=100, mode=0))       # x1: only A rising counts
    rows.append(beat(0b11, interval=100, mode=0))
    rows.append(beat(0b01, interval=100, mode=0))
    rows.append(beat(0b00, interval=65535))
    rows.append(beat(0b10, interval=0))
    rows.append(beat(0b11, interval=65535))
    rows.append(beat(0b01, interval=1, bad_a=1 << 3))   # malformed a
    rows.append(beat(0b00, interval=100, bad_b=1 << 16))  # malformed b
    rows.append(beat(0b10, interval=100, bad_c=1 << 27))  # malformed c
    rows.append(beat(0b11, interval=100, mode=3))          # malformed mode
    return rows


CORE_VECTORS = {
    'mahony_ahrs': v_mahony,
    'kalman1d': v_kalman1,
    'kalman2d_cv': v_kalman2,
    'ca_correlator': v_ca,
    'manchester_io': v_man,
    'dmx512_frame': v_dmx,
    'onewire_slot': v_onewire,
    'ws2812_serial': v_ws2812,
    'crc16_modbus': v_crc16,
    'quadrature_jitter': v_quadrature,
}


def pad(name, rng):
    """One in-range random beat that keeps the state machine running."""
    if name == 'mahony_ahrs':
        return (pair12(rng.randrange(-2048, 2048), rng.randrange(-2048, 2048)),
                rng.randrange(0, 65536),
                (rng.randrange(13) | (rng.randrange(9) << 4)
                 | (rng.randrange(6) << 8))
                | ((1 << 31) if rng.randrange(12) == 0 else 0))
    if name == 'kalman1d':
        flags = ((1 << 29) if rng.randrange(3) == 0 else 0) \
            | ((1 << 30) if rng.randrange(9) == 0 else 0) \
            | ((1 << 31) if rng.randrange(10) == 0 else 0)
        gain = rng.randrange(1, 2048) if (flags & (1 << 31)) else 0
        return (w12(rng.randrange(-2048, 2048)), gain, flags | rng.randrange(8))
    if name == 'kalman2d_cv':
        flags = ((1 << 30) if rng.randrange(2) == 0 else 0) \
            | ((1 << 31) if rng.randrange(12) == 0 else 0)
        gains = (rng.randrange(1, 2048) | (rng.randrange(1, 2048) << 12)) \
            if (flags & (1 << 31)) else rng.randrange(1 << 24)
        return (pair12(rng.randrange(-2048, 2048), rng.randrange(-2048, 2048)),
                gains, flags | rng.randrange(1 << 4))
    if name == 'ca_correlator':
        mask = CA_MASKS[rng.randrange(len(CA_MASKS))]
        return (rng.randrange(1 << 32), rng.randrange(256),
                rng.randrange(16) | (mask << 4) | (rng.randrange(8) << 20)
                | ((1 << 31) if rng.randrange(16) == 0 else 0))
    if name == 'manchester_io':
        if rng.randrange(3) == 0:
            return (rng.randrange(1 << 32), 0,
                    (1 << 30) | ((1 << 31) if rng.randrange(12) == 0 else 0))
        lo, hi = man_encode(rng.randrange(1 << 32))
        return (lo, hi, rng.randrange(64) if rng.randrange(6) == 0 else 0)
    if name == 'dmx512_frame':
        level = rng.randrange(2)
        width = (1 << DMX_TS) + rng.randrange(-3, 4)
        control = (DMX_TS | (DMX_TE << 8)
                   | ((1 << 30) if rng.randrange(20) == 0 else 0)
                   | ((1 << 31) if rng.randrange(24) == 0 else 0))
        return ((width & 0xFFFF) | (level << 16),
                DMX_BREAK_MIN | (DMX_MAB_MIN << 8), control)
    if name == 'onewire_slot':
        level = rng.randrange(2)
        width = rng.choice((5, 10, 60, 70, 100, 120, 500, 600, 800))
        return (width | (level << 16), 0,
                10 | ((1 << 30) if rng.randrange(8) == 0 else 0)
                | ((1 << 31) if rng.randrange(14) == 0 else 0))
    if name == 'ws2812_serial':
        high = rng.choice((2, 3, 4, 5, 6, 7, 8))
        low = rng.choice((2, 3, 4, 5, 6, 7, 8))
        return ((low << 16) | high, rng.choice((0, 3, 5, 8)),
                rng.randrange(4) | ((1 << 31) if rng.randrange(14) == 0 else 0)
                | ((1 << 30) if rng.randrange(20) == 0 else 0))
    if name == 'crc16_modbus':
        return (rng.randrange(1 << 32), rng.randrange(1 << 16),
                rng.randrange(4) | ((1 << 3) if rng.randrange(4) == 0 else 0)
                | ((1 << 31) if rng.randrange(8) == 0 else 0))
    state_word = rng.randrange(4)
    return (state_word | (rng.randrange(2) << 2), rng.randrange(1 << 16),
            rng.randrange(3) | (rng.randrange(256) << 8) | (rng.randrange(8) << 16)
            | (rng.randrange(8) << 24) | ((1 << 30) if rng.randrange(10) == 0 else 0)
            | ((1 << 31) if rng.randrange(12) == 0 else 0))


def vectors(name, count=320):
    rows = list(CORE_VECTORS[name]())
    rng = Random(0x5E950000 + sum(byte for byte in name.encode()))
    while len(rows) < count:
        rows.append(pad(name, rng))
    if len(rows) < count:
        raise ValueError(f'{name}: not enough vectors')
    return rows[:count]


# ===========================================================================
# Selftest
# ===========================================================================
# Each expectation below is re-derived from a route that never reads the integer
# models above: a hand-computed constant, a published reference anchor, or a
# second implementation written from the interface text of the core spec.  Every
# trace threads `state` through step() so a beat cannot silently restart at zero.
# Traces that only exist to prove independence compare step() with the second
# implementation, never with mdl_*().

def _si_fld(state, lo, width):
    """A state field read from the bit positions the core spec documents."""
    return (state >> lo) & ((1 << width) - 1)


def _si_sgn(value, width):
    """value read as a two-complement word of `width` bits."""
    value = value & ((1 << width) - 1)
    return value - (1 << width) if value >> (width - 1) else value


def _si_pi(terms=25):
    """pi from Machin's arctan series over exact rationals.

    pi/4 = 4*atan(1/5) - atan(1/239); no floating point and no math.pi, so this
    is an independent source for the sine grid the AHRS reads.
    """
    def atan_inv(n, count):
        total, num = Fraction(0), Fraction(1, n)
        for k in range(count):
            total += Fraction((-1) ** k, 2 * k + 1) * num
            num /= n * n
        return total
    return 4 * (4 * atan_inv(5, terms) - atan_inv(239, terms))


def _si_sin(x, terms=34):
    """Taylor sine of an exact rational, returned as an exact rational."""
    total, power, fact = Fraction(0), x, 1
    for k in range(terms):
        term = power / fact
        total += -term if k % 2 else term
        power *= x * x
        fact *= (2 * k + 2) * (2 * k + 3)
    return total


def _si_round(value):
    """Nearest integer of an exact rational (ties away from +infinity)."""
    return (2 * value.numerator + value.denominator) // (2 * value.denominator)


_SI_GRID = None


def _si_grid():
    """The 64-point Q11 sine grid, rebuilt from Machin pi plus a Taylor series."""
    global _SI_GRID
    if _SI_GRID is None:
        circle = _si_pi()
        _SI_GRID = [_si_round(Fraction(2047) * _si_sin(circle * Fraction(k, 32)))
                    for k in range(64)]
    return _SI_GRID


def _si_mahony_ref(a, b, c, state):
    """One Mahony update rebuilt from the spec text.

    Independent of mdl_mahony: the grid comes from _si_grid() (exact rational
    trigonometry) instead of SIN_TAB, the state fields are read with plain
    shifts, and the clamp/modular arithmetic is written from the description.
    """
    if (a >> 24) or ((b >> 16) & 0xFFFF) or ((c >> 12) & 0xF) or ((c >> 16) & 0x3FFF):
        return 0, 0, 1, state
    ps, is_gain, qs = c & 0xF, (c >> 4) & 0xF, (c >> 8) & 0xF
    restart = (c >> 31) & 1
    if restart and ((c >> 30) & 1):
        angle = b & 0xFFFF
        moved = state & ~((1 << 65) - 1)
        for lo, width, value in ((0, 16, angle), (16, 16, angle),
                                 (32, 16, 0), (48, 16, 0), (64, 1, 0)):
            moved = (moved & ~(((1 << width) - 1) << lo)) | (value << lo)
        return (angle << 16) | angle, 1 << 12, 0, moved
    a_h = _si_sgn(a, 12)
    a_v = _si_sgn(a >> 12, 12)
    grid_of = _si_grid()
    if restart:
        plane, roll, pitch, i_roll, i_pitch, beats, faults = 0, 0, 0, 0, 0, 0, 0
    else:
        plane = _si_fld(state, 64, 1)
        roll = _si_fld(state, 0, 16)
        pitch = _si_fld(state, 16, 16)
        i_roll = _si_sgn(_si_fld(state, 32, 16), 16)
        i_pitch = _si_sgn(_si_fld(state, 48, 16), 16)
        beats = _si_fld(state, 72, 8)
        faults = _si_fld(state, 80, 8)
    angle = pitch if plane else roll
    current = i_pitch if plane else i_roll
    other = i_roll if plane else i_pitch
    slot = (angle >> 10) & 0x3F
    sine, cosine = grid_of[slot], grid_of[(slot + 16) & 0x3F]
    error = a_h * cosine - a_v * sine
    zero_vector = a_h == 0 and a_v == 0
    new_int, int_sat, corr_sat = current, 0, 0
    if zero_vector:
        correction = 0
    else:
        new_int = current + (error >> is_gain)
        if new_int > 32767:
            new_int, int_sat = 32767, 1
        elif new_int < -32768:
            new_int, int_sat = -32768, 1
        raw = (error >> ps) + (new_int >> qs)
        corr = raw if -8388608 <= raw <= 8388607 else (8388607 if raw > 0 else -8388608)
        corr_sat = 1 if corr != raw else 0
        correction = corr
    total = angle + (b & 0xFFFF) + correction
    wrapped = 1 if total < 0 or total > 65535 else 0
    angle_new = total & 0xFFFF
    fault = 1 if (zero_vector or int_sat or corr_sat) else 0
    result = ((angle_new << 16) | roll) if plane else ((pitch << 16) | angle_new)
    aux = (error >> 11) & 0xFFF
    aux |= restart << 12
    aux |= zero_vector << 13
    aux |= int_sat << 14
    aux |= corr_sat << 15
    aux |= wrapped << 16
    aux |= plane << 17
    aux |= (correction & 0xFFF) << 20
    moved = state
    def put(lo, width, value):
        nonlocal moved
        moved = (moved & ~(((1 << width) - 1) << lo)) | ((value & ((1 << width) - 1)) << lo)
    put(0, 16, roll if plane else angle_new)
    put(16, 16, angle_new if plane else pitch)
    put(32, 16, other if plane else new_int)
    put(48, 16, new_int if plane else other)
    put(64, 1, 1 - plane)
    put(72, 8, min(255, beats + 1))
    put(80, 8, min(255, faults + fault))
    return result & _SI_U32, aux & _SI_U32, fault, moved


_SI_U32 = (1 << 32) - 1


def _si_mahony():
    """Checks for mahony_ahrs: grid anchors, hand beats, saturation, restart."""
    checks = 0
    grid = _si_grid()
    # Published anchors for a Q11 sine on a 5.625 degree grid, each one computed
    # here by hand: 2047*sin(0)=0, 2047*sin(5.625 deg)=200.64 -> 201,
    # 2047/sqrt(2)=1447.50 -> 1447, 2047*sin(90 deg)=2047.
    for slot, want in ((0, 0), (1, 201), (8, 1447), (16, 2047), (24, 1447),
                       (32, 0), (40, -1447), (48, -2047), (56, -1447), (63, -201)):
        assert SIN_TAB[slot] == want, f'sin grid slot {slot}: {SIN_TAB[slot]} != {want}'
        checks += 1
    # The rebuilt grid may differ from the table by at most one LSB: a rounding
    # difference, never a wrong scale or a wrong grid step (both would move a
    # mid-quadrant entry by tens).
    assert all(abs(grid[k] - SIN_TAB[k]) <= 1 for k in range(64)), 'sin scale/grid drift'
    checks += 1
    # Symmetry identities hold for any correct quarter-wave table.
    assert all(SIN_TAB[(k + 32) & 63] == -SIN_TAB[k] for k in range(32)), 'half-wave sign'
    checks += 1
    assert all(SIN_TAB[(16 + k) & 63] == SIN_TAB[(16 - k) & 63]
               for k in range(16)), 'quarter-wave symmetry'
    checks += 1
    # Pythagoras on the Q11 scale: sin^2 + cos^2 must sit at 2047^2 = 4190209.
    assert all(abs(SIN_TAB[k] ** 2 + SIN_TAB[(k + 16) & 63] ** 2 - 4190209) <= 4200
               for k in range(64)), 'sin/cos norm'
    checks += 1
    # Largest reachable cross-product term: |e| <= 2048*(|sin|+|cos|) and the
    # integrator adds at most 32767, so no legal beat can reach the 24-bit
    # correction clamp (it stays a guard, not a live path).
    edge = max(abs(SIN_TAB[k]) + abs(SIN_TAB[(k + 16) & 63]) for k in range(64))
    assert edge == 2894 and 2048 * edge + 32767 < 2 ** 23, f'|e| bound {2048 * edge}'
    checks += 1
    base = 11 | (8 << 4) | (6 << 8)          # PS=11, IS=8, QS=6

    # Align beat: both angles load from b, integrators and plane clear.
    r, x, f, st = step('mahony_ahrs', pair12(0, 2047), 0x0600,
                       (1 << 31) | (1 << 30) | base, 0xDEADBEEF)
    assert (r, x, f) == ((0x600 << 16) | 0x600, 1 << 12, 0), f'align {r:08x} {x:08x} {f}'
    checks += 1
    assert (_si_fld(st, 0, 16), _si_fld(st, 16, 16), _si_fld(st, 32, 32),
            _si_fld(st, 64, 1)) == (0x600, 0x600, 0, 0), 'align state'
    checks += 1
    assert (_si_fld(st, 72, 8), _si_fld(st, 80, 8)) == (0, 0), 'align keeps counters'
    checks += 1

    # Restart beat (no align): the fusion runs against a cleared filter, so with
    # gravity along the reference axis e = 0*2047 - 2047*0 = 0 exactly.
    r, x, f, st = step('mahony_ahrs', pair12(0, 2047), 0, (1 << 31) | base, 0)
    assert (r, x, f, st) == (0, 1 << 12, 0, (1 << 64) | (1 << 72)), f'restart {st:x}'
    checks += 1

    # Hand-computed update on the pitch plane (the restart flipped the pointer).
    # angle = 0 -> sin 0, cos 2047 -> e = 2047*2047 = 4190209.
    #   e>>>11 = 2046, I = 4190209>>>8 = 16368, I>>>6 = 255, d = 2301.
    r, x, f, st2 = step('mahony_ahrs', pair12(2047, 0), 0, base, st)
    assert (r, x, f) == (2301 << 16, (2301 << 20) | (1 << 17) | 2046, 0), \
        f'pitch beat {r:08x} {x:08x} {f}'
    checks += 1
    assert st2 == (2301 << 16) | (16368 << 48) | (2 << 72), f'pitch state {st2:x}'
    checks += 1

    # Modular wrap: angle 1 plus a 65535 delta plus zero correction is 65536.
    _r, _x, _f, st = step('mahony_ahrs', pair12(0, 2047), 1,
                          (1 << 31) | (1 << 30) | base, 0)
    r, x, f, st = step('mahony_ahrs', pair12(0, 2047), 0xFFFF, base, st)
    assert (r, x, f) == (1 << 16, 1 << 16, 0), f'wrap {r:08x} {x:08x} {f}'
    checks += 1
    assert (_si_fld(st, 0, 16), _si_fld(st, 16, 16), _si_fld(st, 64, 1)) == (0, 1, 1), \
        'wrap state'
    checks += 1

    # Integrator saturation with IS=0: e itself (4190209) cannot fit 16 bits, so
    # the clamp and the fault flag fire and the correction uses the clamped I.
    tight = 11 | (0 << 4) | (6 << 8)
    _r, _x, _f, st = step('mahony_ahrs', pair12(0, 2047), 0, (1 << 31) | tight, 0)
    r, x, f, st = step('mahony_ahrs', pair12(2047, 0), 0, tight, st)
    assert (r, x, f) == (2557 << 16, (2557 << 20) | (1 << 17) | (1 << 14) | 2046, 1), \
        f'integrator clamp {r:08x} {x:08x} {f}'
    checks += 1
    assert (_si_fld(st, 48, 16) == 32767 and _si_fld(st, 80, 8) == 1), 'clamp state'
    checks += 1

    # Zero-length gravity vector: correction forced to zero, integrator held,
    # fault raised, and the angle still advances by the gyro word.
    _r, _x, _f, st = step('mahony_ahrs', pair12(123, 456), 7, (1 << 31) | (1 << 30) | base, 0)
    r, x, f, st = step('mahony_ahrs', pair12(0, 0), 0x10, base, st)
    assert (r, x, f) == ((7 << 16) | 23, 1 << 13, 1), \
        f'zero vector {r:08x} {x:08x} {f}'
    checks += 1
    assert (_si_fld(st, 0, 16), _si_fld(st, 16, 16), _si_fld(st, 32, 32),
            _si_fld(st, 80, 8)) == (23, 7, 0, 1), 'zero vector state'
    checks += 1

    # Malformed beat: a must-be-zero bit set keeps the whole state untouched.
    keep = (1 << 64) | 0x1234
    r, x, f, st = step('mahony_ahrs', pair12(0, 2047) | (1 << 24), 0, base, keep)
    assert (r, x, f, st) == (0, 0, 1, keep), 'mahony malformed beat'
    checks += 1

    # Aligned-gravity invariant: with the sample pointing exactly along the
    # estimate the cross product is zero for every grid slot, which only holds
    # if (sin, cos) are read with the documented +16 slot pairing.
    for slot in (0, 1, 7, 8, 15, 16, 23, 31, 40, 47, 55, 63):
        angle = (slot << 10) | 0x100          # keep the low bits non-zero
        _r, _x, _f, st = step('mahony_ahrs', pair12(0, 2047), angle,
                              (1 << 31) | (1 << 30) | base, 0)
        a = pair12(SIN_TAB[slot], SIN_TAB[(slot + 16) & 63])
        r, x, f, st = step('mahony_ahrs', a, 0, base, st)
        assert (r, x, f) == ((angle << 16) | angle, 0, 0), \
            f'aligned slot {slot}: {r:08x} {x:08x} {f}'
        checks += 1

    # Full-trace independence: 96 scripted beats through step() against the
    # rational-trig reference, with the state carried from beat to beat.
    rng = Random(0x5E95A115)
    st = 0
    for index in range(96):
        a = pair12(rng.randrange(-2048, 2048), rng.randrange(-2048, 2048))
        b = rng.randrange(1 << 16)
        c = rng.randrange(16) | (rng.randrange(16) << 4) | (rng.randrange(16) << 8)
        if index % 23 == 0:
            c |= (1 << 31) | (1 << 30)                     # align
        elif index % 17 == 0:
            c |= 1 << 31                                   # plain restart
        got = step('mahony_ahrs', a, b, c, st)
        want = _si_mahony_ref(a, b, c, st)
        assert got == want, f'mahony trace {index}: {got} != {want}'
        st = got[3]
        checks += 1
    assert st != 0, 'mahony trace did not thread state'
    checks += 1
    return checks


def _si_rhu(product):
    """round_half_up(product/4096) through exact rationals, not a shift."""
    return _si_round(Fraction(product, 4096))


def _si_kalman1_ref(a, b, c, state):
    """Steady-state scalar Kalman update rebuilt from the spec text.

    Rounding uses exact fractions, the fields are read with plain shifts and the
    innovation EWMA is written as the difference form the spec names.
    """
    if (a >> 12) or (b >> 12) or ((c >> 4) & ((1 << 25) - 1)):
        return 0, 0, 1, state
    if (c >> 31) & 1:
        gain = b & 0xFFF
        if gain == 0 or gain > 0x7FF:
            return 0, 0, 1, state
        moved = state
        for lo, width, value in ((0, 12, 0), (12, 12, gain), (24, 12, 0),
                                 (36, 1, 1), (37, 8, 0), (45, 8, 0), (53, 8, 0)):
            moved = (moved & ~(((1 << width) - 1) << lo)) | (value << lo)
        return 0, 1 << 29, 0, moved
    if not _si_fld(state, 36, 1):
        return 0, 0, 1, state
    gain = _si_fld(state, 12, 12)
    var = _si_fld(state, 24, 12)
    estimate = _si_sgn(_si_fld(state, 0, 12), 12)
    residual = 0
    predict = gate = x_sat = v_sat = 0
    new_var = var
    beats = _si_fld(state, 45, 8)
    clamps = _si_fld(state, 53, 8)
    rejects = _si_fld(state, 37, 8)
    if (c >> 30) & 1:
        predict = 1
    else:
        residual = _si_sgn(a, 12) - estimate
        magnitude = -residual if residual < 0 else residual
        if ((c >> 29) & 1) and magnitude > var + (var >> (c & 0xF)) + 1:
            gate = 1
            rejects = min(255, rejects + 1)
        else:
            raw = estimate + _si_rhu(gain * residual)
            estimate = raw if -2048 <= raw <= 2047 else (2047 if raw > 0 else -2048)
            x_sat = 1 if raw != estimate else 0
            step_var = (magnitude - var) >> 3
            new_var = var + step_var
            clamped = new_var if 0 <= new_var <= 4095 else (4095 if new_var > 0 else 0)
            v_sat = 1 if clamped != new_var else 0
            new_var = clamped
            beats = min(255, beats + 1)
            clamps = min(255, clamps + (1 if (x_sat or v_sat) else 0))
    fault = gate or x_sat or v_sat
    result = _si_sgn(estimate, 12)
    shown = var if (predict or gate) else new_var
    aux = residual & 0x1FFF
    aux |= (shown & 0xFFF) << 13
    aux |= x_sat << 25
    aux |= gate << 26
    aux |= predict << 27
    aux |= v_sat << 28
    moved = state
    for lo, width, value in ((0, 12, estimate & 0xFFF), (12, 12, gain),
                             (24, 12, new_var & 0xFFF), (36, 1, 1),
                             (37, 8, rejects), (45, 8, beats), (53, 8, clamps)):
        moved = (moved & ~(((1 << width) - 1) << lo)) | ((value & ((1 << width) - 1)) << lo)
    return result & _SI_U32, aux & _SI_U32, fault, moved


def _si_kalman1():
    """Checks for kalman1d: Riccati anchor, hand beats, ties, gate, traces."""
    checks = 0
    # Published-anchor route to the gain word: the steady-state covariance of a
    # scalar x := x + w, z = x + v filter with Q=1, R=4 is the positive root of
    # P^2 + P - 4 = 0, i.e. P+ = (sqrt(17)-1)/2, and the gain is
    # K = (P+ + 1)/(P+ + 5).  Iterating the exact rational Riccati recursion
    # must land on that K, and Q12 scaling must give 1599.
    q, r_noise, cov = Fraction(1), Fraction(4), Fraction(1)
    for _ in range(400):
        prior = cov + q
        gain = prior / (prior + r_noise)
        cov = (1 - gain) * prior
    prior = cov + q
    gain = prior / (prior + r_noise)
    # Fixed-point residual: prior must equal (1-K)*prior + Q to better than 2^-60.
    assert abs(prior - (1 - gain) * prior - q) < Fraction(1, 1 << 60), 'riccati drift'
    checks += 1
    assert _si_round(gain * 4096) == 1599, f'gain word {_si_round(gain * 4096)}'
    checks += 1
    # Closed form for the same fixed point: (2P+ + 1)^2 = 17 for Q=1, R=4.
    assert abs((2 * cov + 1) ** 2 - 17) < Fraction(1, 1 << 40), 'sqrt(17) anchor'
    checks += 1

    # Config beat: gain loaded, filter zeroed, aux[29] marks the restart.
    r, x, f, st = step('kalman1d', 0, 1599, 1 << 31, 0)
    assert (r, x, f) == (0, 1 << 29, 0), f'k1 config {r:x} {x:x} {f}'
    checks += 1
    assert (_si_fld(st, 12, 12), _si_fld(st, 36, 1), _si_fld(st, 0, 12),
            _si_fld(st, 24, 12)) == (1599, 1, 0, 0), f'k1 config state {st:x}'
    checks += 1
    # Rejected configs leave the filter unconfigured and the state untouched.
    for bad in (0, 2048, 4095):
        keep = (1599 << 12) | (1 << 36) | 7
        r, x, f, st2 = step('kalman1d', 0, bad, 1 << 31, keep)
        assert (r, x, f, st2) == (0, 0, 1, keep), f'k1 bad gain {bad}'
        checks += 1
    # A normal beat before any successful config faults with nothing changed.
    r, x, f, st2 = step('kalman1d', 100, 0, 0, 12345)
    assert (r, x, f, st2) == (0, 0, 1, 12345), 'k1 unconfigured beat'
    checks += 1

    # Hand-computed update: z=100 from x=0, V=0.
    #   r=100, corr = round(1599*100/4096) = round(39.003) = 39,
    #   V = 0 + ((100-0)>>3) = 12.
    r, x, f, st = step('kalman1d', w12(100), 0, 0, st)
    assert (r, x, f) == (39, (12 << 13) | 100, 0), f'k1 first update {r:x} {x:x} {f}'
    checks += 1
    assert (_si_sgn(_si_fld(st, 0, 12), 12), _si_fld(st, 24, 12),
            _si_fld(st, 45, 8)) == (39, 12, 1), f'k1 state {st:x}'
    checks += 1

    # Round-half-up on an exact tie: with K=1024 a residual of +2 is +0.5 LSB
    # and rounds to 1, while -2 is -0.5 LSB and rounds to 0 (never away from 0).
    _r, _x, _f, st = step('kalman1d', 0, 1024, 1 << 31, 0)
    assert _si_rhu(1024 * 2) == 1 and _si_rhu(1024 * -2) == 0, 'tie derivation'
    checks += 1
    r, x, f, st = step('kalman1d', w12(2), 0, 0, st)
    assert (r, f) == (1, 0) and _si_sgn(_si_fld(st, 0, 12), 12) == 1, f'k1 up tie {r:x}'
    checks += 1
    r, x, f, st = step('kalman1d', w12(3), 0, 0, st)
    assert r == 2, f'k1 second up tie {r:x}'
    checks += 1
    r, x, f, st = step('kalman1d', w12(0), 0, 0, st)
    assert (r, f, x & 0x1FFF) == (2, 0, 0x1FFE), f'k1 down tie {r:x} {x:x} {f}'
    checks += 1

    # Innovation gate: with V=12 and G=3 the threshold is 12+1+1 = 14, so |r|=14
    # is accepted and |r|=15 is rejected with x and V held.  V=12 is a reachable
    # variance (a residual of 100 from V=0 moves it by exactly 100>>>3 = 12).
    st = (1536 << 12) | (12 << 24) | (1 << 36)
    r, x, f, st = step('kalman1d', w12(14), 0, (1 << 29) | 3, st)
    assert (r, x, f) == (5, (12 << 13) | 14, 0), f'k1 gate edge {r:x} {x:x} {f}'
    checks += 1
    assert (_si_sgn(_si_fld(st, 0, 12), 12), _si_fld(st, 24, 12),
            _si_fld(st, 37, 8), _si_fld(st, 45, 8)) == (5, 12, 0, 1), f'k1 gate accept {st:x}'
    checks += 1
    held = st
    r, x, f, st = step('kalman1d', w12(20), 0, (1 << 29) | 3, held)
    assert (r, x, f) == (5, (12 << 13) | 15 | (1 << 26), 1), \
        f'k1 gate reject {r:x} {x:x} {f}'
    checks += 1
    assert (_si_sgn(_si_fld(st, 0, 12), 12), _si_fld(st, 24, 12),
            _si_fld(st, 37, 8), _si_fld(st, 45, 8)) == (5, 12, 1, 1), 'k1 reject state'
    checks += 1

    # Predict-only beat consumes the measurement as nothing: r=0, x and V held.
    r, x, f, st = step('kalman1d', w12(-2000), 0, 1 << 30, held)
    assert (r, x, f) == (5, (12 << 13) | (1 << 27), 0), f'k1 predict {r:x} {x:x}'
    checks += 1
    assert st == held, 'k1 predict holds state'
    checks += 1

    # Malformed beat: a[12] set is outside the signed 12-bit measurement.
    r, x, f, st = step('kalman1d', (1 << 12) | 100, 0, 0, held)
    assert (r, x, f, st) == (0, 0, 1, held), 'k1 malformed'
    checks += 1

    # Reachability of the two clamp flags: a steady-state gain below 1/2 can
    # only move x by at most half the residual, so x cannot leave the rail it is
    # heading away from, and |r| <= 4095 keeps V inside 12 bits.  Both aux flags
    # are guards, never live paths -- proved here, not by step().
    worst = max(abs(_si_rhu(2047 * res)) for res in range(-4095, 4096))
    assert worst <= 2047 and 2047 + 2047 < 4096, f'k1 correction bound {worst}'
    checks += 1
    assert max(var + ((4095 - var) >> 3) for var in range(4096)) <= 4095, 'k1 var bound'
    checks += 1

    # Threaded trace against the fraction-based reference.
    rng = Random(0x5E95A11D)
    st = 0
    for index in range(100):
        z = rng.randrange(-2048, 2048)
        c = rng.randrange(16)
        if rng.randrange(5) == 0:
            c |= 1 << 29
        if rng.randrange(9) == 0:
            c |= 1 << 30
        if index % 29 == 0:
            a, b, c = 0, rng.choice((1, 1024, 1599, 2047, 0, 2048)), 1 << 31
        else:
            a, b, c = w12(z), 0, c
        if rng.randrange(19) == 0:
            a |= 1 << rng.randrange(12, 32)
        got = step('kalman1d', a, b, c, st)
        want = _si_kalman1_ref(a, b, c, st)
        assert got == want, f'k1 trace {index}: {got} != {want}'
        st = got[3]
        checks += 1
    assert _si_fld(st, 36, 1) == 1, 'k1 trace never configured'
    checks += 1
    return checks


def _si_kalman2_ref(a, b, c, state):
    """Constant-velocity fixed-gain update rebuilt from the spec text.

    Exact-fraction rounding instead of the +2048 shift, plain shift/mask field
    access instead of the model helpers, and the clamp written as a comparison
    rather than as the model's clamp() call.
    """
    if (a >> 24) or (b >> 24) or ((c >> 24) & 0x3F):
        return 0, 0, 1, state
    if (c >> 31) & 1:
        gains = (b & 0xFFF, (b >> 12) & 0xFFF, c & 0xFFF, (c >> 12) & 0xFFF)
        if any(gain == 0 or gain > 0x7FF for gain in gains):
            return 0, 0, 1, state
        moved = state
        fields = [(0, 12, 0), (12, 12, 0), (72, 1, 1), (73, 13, 0), (86, 13, 0),
                  (99, 8, 0), (107, 8, 0)]
        for index, lo in enumerate((24, 36, 48, 60)):
            fields.append((lo, 12, gains[index]))
        for lo, width, value in fields:
            moved = (moved & ~(((1 << width) - 1) << lo)) | (value << lo)
        return 0, 1 << 17, 0, moved
    if not _si_fld(state, 72, 1):
        return 0, 0, 1, state
    mode = (c >> 30) & 1
    position = _si_sgn(_si_fld(state, 0, 12), 12)
    velocity = _si_sgn(_si_fld(state, 12, 12), 12)
    raw_predict = position + velocity
    predicted = raw_predict if -2048 <= raw_predict <= 2047 else (
        2047 if raw_predict > 0 else -2048)
    pred_sat = 1 if predicted != raw_predict else 0
    residual = _si_sgn(a >> 12, 12) - velocity if mode else _si_sgn(a, 12) - predicted
    gain_p = _si_fld(state, 48, 12) if mode else _si_fld(state, 24, 12)
    gain_v = _si_fld(state, 60, 12) if mode else _si_fld(state, 36, 12)
    raw_p = predicted + _si_rhu(gain_p * residual)
    raw_v = velocity + _si_rhu(gain_v * residual)
    position = raw_p if -2048 <= raw_p <= 2047 else (2047 if raw_p > 0 else -2048)
    velocity = raw_v if -2048 <= raw_v <= 2047 else (2047 if raw_v > 0 else -2048)
    pos_sat = 1 if raw_p != position else 0
    vel_sat = 1 if raw_v != velocity else 0
    fault = pred_sat or pos_sat or vel_sat
    magnitude = -residual if residual < 0 else residual
    peak = _si_fld(state, 86, 13)
    if magnitude > peak:
        peak = magnitude
    result = ((velocity & 0xFFF) << 12) | (position & 0xFFF)
    aux = residual & 0x1FFF
    aux |= pred_sat << 13
    aux |= pos_sat << 14
    aux |= vel_sat << 15
    aux |= mode << 16
    aux |= peak << 18
    moved = state
    for lo, width, value in (
            (0, 12, position & 0xFFF), (12, 12, velocity & 0xFFF),
            (73, 13, residual & 0x1FFF), (86, 13, peak),
            (99, 8, min(255, _si_fld(state, 99, 8) + 1)),
            (107, 8, min(255, _si_fld(state, 107, 8) + fault))):
        moved = (moved & ~(((1 << width) - 1) << lo)) | (value << lo)
    return result & _SI_U32, aux & _SI_U32, fault, moved


def _si_kalman2():
    """Checks for kalman2d_cv: config rules, hand updates, rails, traces."""
    checks = 0
    gains_b = 1024 | (512 << 12)                   # K11 = 1/4, K21 = 1/8
    gains_c = 256 | (1024 << 12)                   # K12 = 1/16, K22 = 1/4
    config = (1 << 31) | gains_c

    # Config beat: the four gain words land in the documented fields and nothing
    # else moves; aux[17] marks the restart and the update itself is skipped.
    r, x, f, st = step('kalman2d_cv', pair12(100, 100), gains_b, config, 0)
    assert (r, x, f) == (0, 1 << 17, 0), f'k2 config {r:x} {x:x} {f}'
    checks += 1
    want = (1024 << 24) | (512 << 36) | (256 << 48) | (1024 << 60) | (1 << 72)
    assert st == want, f'k2 config state {st:x} != {want:x}'
    checks += 1

    # Each rejected config leaves the filter unconfigured and the state kept.
    for bad_b, bad_c, why in ((0 | (512 << 12), gains_c, 'K11 zero'),
                              (gains_b, 0 | (1024 << 12), 'K12 zero'),
                              (2048 | (512 << 12), gains_c, 'K11 above 2047'),
                              (gains_b, 256 | (2048 << 12), 'K22 above 2047')):
        r, x, f, st2 = step('kalman2d_cv', 0, bad_b, (1 << 31) | bad_c, 0xABCD)
        assert (r, x, f, st2) == (0, 0, 1, 0xABCD), f'k2 rejected config: {why}'
        checks += 1

    # A normal beat before any successful config faults with the state kept.
    r, x, f, st2 = step('kalman2d_cv', pair12(64, 0), 0, 0, 0x5A5A)
    assert (r, x, f, st2) == (0, 0, 1, 0x5A5A), 'k2 unconfigured beat'
    checks += 1

    # Mode 0, hand computed: pos = vel = 0, predicted = 0, r = 64.
    #   corr_pos = round(1024*64/4096) = 16, corr_vel = round(512*64/4096) = 8.
    r, x, f, st = step('kalman2d_cv', pair12(64, 0), 0, 0, st)
    assert (r, x, f) == ((8 << 12) | 16, (64 << 18) | 64, 0), \
        f'k2 mode0 {r:x} {x:x} {f}'
    checks += 1
    assert (_si_sgn(_si_fld(st, 0, 12), 12), _si_sgn(_si_fld(st, 12, 12), 12),
            _si_fld(st, 99, 8)) == (16, 8, 1), f'k2 mode0 state {st:x}'
    checks += 1

    # Mode 1 (velocity column): predicted = 16+8 = 24, w = 40 so r = 40-8 = 32,
    # corr_pos = round(256*32/4096) = 2, corr_vel = round(1024*32/4096) = 8.
    r, x, f, st = step('kalman2d_cv', pair12(0, 40), 0, 1 << 30, st)
    assert (r, x, f) == ((16 << 12) | 26, (64 << 18) | (1 << 16) | 32, 0), \
        f'k2 mode1 {r:x} {x:x} {f}'
    checks += 1
    assert (_si_sgn(_si_fld(st, 0, 12), 12), _si_sgn(_si_fld(st, 12, 12), 12),
            _si_fld(st, 86, 13)) == (26, 16, 64), 'k2 mode1 state'
    checks += 1

    # Prediction rail: pos 2000 with vel 200 predicts 2200, which clamps to 2047
    # (aux[13]) and faults.  A measurement of -2048 then gives r = -4095, the
    # largest residual the 13-bit field can hold, and the peak tracker latches.
    rail = (2000 | (200 << 12) | (1024 << 24) | (512 << 36)
            | (256 << 48) | (1024 << 60) | (1 << 72))
    r, x, f, st = step('kalman2d_cv', pair12(-2048, 0), 0, 0, rail)
    assert (r, x, f) == ((-312 & 0xFFF) << 12 | 1023, (4095 << 18) | (1 << 13) | 0x1001,
                         1), f'k2 rail {r:x} {x:x} {f}'
    checks += 1
    assert (_si_sgn(_si_fld(st, 0, 12), 12), _si_sgn(_si_fld(st, 12, 12), 12),
            _si_fld(st, 73, 13), _si_fld(st, 86, 13),
            _si_fld(st, 107, 8)) == (1023, -312, 0x1001, 4095, 1), f'k2 rail state {st:x}'
    checks += 1

    # A restart reloads the gains and clears positions, history and counters.
    r, x, f, st = step('kalman2d_cv', 0, gains_b, config, st)
    assert (r, x, f) == (0, 1 << 17, 0), 'k2 restart response'
    checks += 1
    assert st == want, f'k2 restart clears {st:x}'
    checks += 1

    # Malformed beat: a[24] is outside the two signed 12-bit measurements.
    keep = st | (77 << 86)
    r, x, f, st2 = step('kalman2d_cv', (1 << 24) | 64, 0, 0, keep)
    assert (r, x, f, st2) == (0, 0, 1, keep), 'k2 malformed beat'
    checks += 1

    # Why the gains are capped at 2047: the slice recode forms 2*(K*(r>>>1)) +
    # K*r[0], and with |r| <= 4095 the doubled product must still fit the signed
    # 24-bit slice output.  2047*4095 = 8382555 < 2^23, one gain bit wider would
    # overflow it.
    assert 2047 * 4095 < 2 ** 23 and 2047 * 8191 >= 2 ** 23, 'k2 slice bound'
    checks += 1
    assert max(abs(_si_rhu(gain * res)) for gain in (2047,)
               for res in range(-4095, 4096)) == 2047, 'k2 correction bound'
    checks += 1

    # Threaded trace against the fraction-based reference.
    rng = Random(0x5E95A12E)
    st = 0
    for index in range(100):
        if index % 23 == 0:
            a = 0
            b = rng.choice((gains_b, 0, 2048 | (512 << 12)))
            c = (1 << 31) | rng.choice((gains_c, 0, 256 | (2048 << 12)))
        else:
            a = pair12(rng.randrange(-2048, 2048), rng.randrange(-2048, 2048))
            b = rng.choice((0, gains_b))
            c = rng.randrange(4096) if rng.randrange(11) == 0 else 0
            if rng.randrange(3) == 0:
                c |= 1 << 30
            if rng.randrange(17) == 0:
                a |= 1 << rng.randrange(24, 32)
        got = step('kalman2d_cv', a, b, c, st)
        want_row = _si_kalman2_ref(a, b, c, st)
        assert got == want_row, f'k2 trace {index}: {got} != {want_row}'
        st = got[3]
        checks += 1
    assert _si_fld(st, 72, 1) == 1 and _si_fld(st, 99, 8) > 1, 'k2 trace did not run'
    checks += 1
    return checks


def _si_ca_ref(a, b, c, state):
    """Cell-averaging CFAR step rebuilt from the spec text.

    The window is a list of 16 cells rather than a 128-bit register, the divide
    by N is an integer division rather than the model's shift, popcount is an
    explicit sum of bits rather than bin().count, and the slide appends to the
    list instead of concatenating Verilog fields.
    """
    if (b >> 8) or ((c >> 23) & 0xFF):
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    mask = (c >> 4) & 0xFFFF
    cut = c & 0xF
    at = (c >> 20) & 7
    window = [(_si_fld(state, 8 * index, 8)) for index in range(16)]
    chosen = [window[index] for index in range(16) if (mask >> index) & 1]
    count = sum((mask >> index) & 1 for index in range(16))
    is_pow = count >= 2 and (count & (count - 1)) == 0
    log2 = {1 << k: k for k in range(1, 5)}.get(count, 0)
    sel_cut = (mask >> cut) & 1
    guard = 0 if (is_pow and not sel_cut) else 1
    total = sum(chosen)
    mean = total // count if is_pow else total
    threshold = mean + (mean >> at) + (b & 0xFF)
    cell = window[cut]
    hit = 1 if (not guard and cell > threshold) else 0
    miss = 1 if (not guard and cell <= threshold) else 0
    # result[15:8] publishes only the low 8 bits of the mean (mean can reach
    # 4080//2 = 2040), and result[7:0] the cell under test.
    result = ((cell & 0xFF) | ((mean & 0xFF) << 8) | (hit << 16) | (miss << 17)
              | (guard << 18) | (restart << 19) | ((total & 0xFFF) << 20))
    aux = (threshold & 0x1FFF) | ((1 - is_pow) << 13) | (sel_cut << 14)
    aux |= restart << 15
    aux |= log2 << 16
    invalids = min(255, (0 if restart else _si_fld(state, 144, 8)) + guard)
    hits = min(255, (0 if restart else _si_fld(state, 128, 8)) + hit)
    misses = min(255, (0 if restart else _si_fld(state, 136, 8)) + miss)
    beats = min(255, (0 if restart else _si_fld(state, 152, 8)) + 1)
    aux |= (invalids & 0xF) << 20
    aux |= beats << 24
    fresh = [(a >> (8 * index)) & 0xFF for index in range(4)]
    moved = 0
    for index in range(12):
        moved |= (_si_fld(state, 8 * (index + 4), 8) if not restart else 0) << (8 * index)
    for index, value in enumerate(fresh):
        moved |= value << (8 * (12 + index))
    moved |= hits << 128
    moved |= misses << 136
    moved |= invalids << 144
    moved |= beats << 152
    return result & _SI_U32, aux & _SI_U32, guard, moved


def _si_ca():
    """Checks for ca_correlator: hand-built window, decision edges, guard set."""
    checks = 0
    window_full = sum(index << (8 * index) for index in range(16))
    assert window_full == 0x0F0E0D0C0B0A09080706050403020100, 'window constant'
    checks += 1
    quad = (lambda first: ((first + 3) << 24) | ((first + 2) << 16)
            | ((first + 1) << 8) | first)
    setup = 0x0FF0 << 4                         # cells 4..11, cut 0 outside it

    # Build the 0..15 window with the documented slide order: a[7:0] is the first
    # (lowest-index) new cell, four cells enter per beat and the decision is
    # taken on the window as held before the slide.
    st = 0
    r, x, f, st = step('ca_correlator', quad(0), 0, (1 << 31) | setup, st)
    assert _si_fld(st, 0, 128) == quad(0) << 96, f'ca restart window {st:032x}'
    checks += 1
    for first in (4, 8, 12):
        r, x, f, st = step('ca_correlator', quad(first), 0, setup, st)
        checks += 1
    assert _si_fld(st, 0, 128) == window_full, f'ca window {_si_fld(st, 0, 128):032x}'
    checks += 1
    assert (_si_fld(st, 152, 8), _si_fld(st, 128, 8), _si_fld(st, 136, 8),
            _si_fld(st, 144, 8)) == (4, 0, 4, 0), \
        f'ca counters {_si_fld(st, 152, 8)}'
    checks += 1

    # Decision: mask 0x000F averages cells 0..3 = 0+1+2+3 = 6, N=4 so
    # mean = 6//4 = 1, AT=0 gives threshold = 1+1+0 = 2 and cell 15 = 15 hits.
    r, x, f, st = step('ca_correlator', quad(16), 0, 15 | (0x000F << 4), st)
    assert (r, x, f) == (15 | (1 << 8) | (1 << 16) | (6 << 20),
                         2 | (2 << 16) | (5 << 24), 0), f'ca hit {r:x} {x:x} {f}'
    checks += 1
    moved_expect = sum((index + 4) << (8 * index) for index in range(12)) \
        | (16 << 96) | (17 << 104) | (18 << 112) | (19 << 120)
    assert _si_fld(st, 0, 128) == moved_expect, f'ca slide {st:032x}'
    checks += 1
    assert (_si_fld(st, 128, 8), _si_fld(st, 136, 8), _si_fld(st, 152, 8)) == (1, 4, 5), \
        'ca hit/miss counters'
    checks += 1

    # Threshold uses the full 16-bit value while aux publishes only 13 bits; the
    # largest reachable threshold is mean(=4080//2) + itself + offset 255, which
    # stays below 8192, so the published field can never alias.
    assert 16 * 255 == 4080 and 2040 + 2040 + 255 == 4335 < (1 << 13), 'ca threshold bound'
    checks += 1
    assert 4080 <= 0xFFF, 'ca sum fits the 12-bit result field'
    checks += 1

    # Guard patterns: popcount 1 and popcount 3 are not powers of two, and a mask
    # that contains the cell under test is invalid even at popcount 4.
    for mask, cut, pow_bit, cut_bit, why in (
            (0x0001, 5, 1, 0, 'popcount 1'),
            (0x0007, 5, 1, 0, 'popcount 3'),
            (0x0000, 5, 1, 0, 'empty mask'),
            (0xF000, 13, 0, 1, 'mask contains cut'),
            (0x000F, 3, 0, 1, 'mask contains cut low')):
        r, x, f, st = step('ca_correlator', quad(16), 0, cut | (mask << 4), window_full)
        assert (f, (r >> 18) & 1, (x >> 13) & 1, (x >> 14) & 1) == \
            (1, 1, pow_bit, cut_bit), f'ca guard {why}: {r:x} {x:x} {f}'
        checks += 1
        # The window still slides on a guarded beat, and the invalid count grew.
        assert _si_fld(st, 0, 128) != window_full, f'ca guard did not slide: {why}'
        checks += 1

    # popcount 4 over cells 12..15 = 12+13+14+15 = 54, mean = 54//4 = 13, and
    # AT=1 puts the threshold at 13+6 = 19, above cell 7 -> a miss, no fault.
    r, x, f, st = step('ca_correlator', 0, 0, 7 | (0xF000 << 4) | (1 << 20), window_full)
    assert (r & 0xFF, (r >> 8) & 0xFF, (r >> 17) & 1, f) == (7, 13, 1, 0), \
        f'ca mean {r:x} {f}'
    checks += 1
    assert (x & 0x1FFF) == 13 + (13 >> 1), f'ca threshold {x:x}'
    checks += 1

    # Restart clears the window and every counter, then loads the new quad.
    r, x, f, st = step('ca_correlator', quad(20), 0, (1 << 31) | setup, window_full | 0xFF)
    assert ((r >> 19) & 1, (x >> 15) & 1) == (1, 1), f'ca restart flags {r:x} {x:x}'
    checks += 1
    assert _si_fld(st, 0, 128) == quad(20) << 96, 'ca restart window'
    checks += 1
    assert (_si_fld(st, 128, 8), _si_fld(st, 136, 8), _si_fld(st, 144, 8),
            _si_fld(st, 152, 8)) == (1, 0, 0, 1), f'ca restart counters {st:x}'
    checks += 1

    # Saturating beat counter: pre-set to 255 it must stay at 255 and publish it.
    saturated = window_full | (255 << 152)
    r, x, f, st = step('ca_correlator', quad(16), 0, setup, saturated)
    assert (x >> 24) == 255 and _si_fld(st, 152, 8) == 255, f'ca beat cap {x:x}'
    checks += 1
    assert _si_fld(saturated, 136, 8) == 0 and _si_fld(st, 136, 8) == 1, 'ca miss count'
    checks += 1

    # Malformed beat: b[31:8] or c[30:23] set, nothing moves.
    r, x, f, st = step('ca_correlator', 0, 1 << 8, setup, window_full)
    assert (r, x, f, st) == (0, 0, 1, window_full), 'ca malformed b'
    checks += 1
    r, x, f, st = step('ca_correlator', 0, 0, (1 << 23) | setup, window_full)
    assert (r, x, f, st) == (0, 0, 1, window_full), 'ca malformed c'
    checks += 1

    # Threaded trace against the list-window / integer-division reference.
    rng = Random(0x5E95A137)
    st = 0
    # Tracked from the input list alone: the beat counter the RTL should be left
    # holding, and the quad that should still be sitting in the four newest cells.
    # Both can only come out right if every beat really consumed the previous
    # returned state.
    beats_seen = 0
    last_quad = 0
    for index in range(100):
        quad_word = rng.randrange(1 << 32)
        mask = rng.choice((0x0FF0, 0x00FF, 0x0F0F, 0x0003, 0xF000, 0x000F,
                           0x0111, 0x0001, 0x0007, 0x0000, 0x0AA0, 0x0555))
        c = rng.randrange(16) | (mask << 4) | (rng.randrange(8) << 20)
        if rng.randrange(13) == 0:
            c |= 1 << 31
        b = rng.randrange(256)
        if rng.randrange(23) == 0:
            b |= 1 << rng.randrange(8, 32)
        got = step('ca_correlator', quad_word, b, c, st)
        want = _si_ca_ref(quad_word, b, c, st)
        assert got == want, f'ca trace {index}: {got} != {want}'
        st = got[3]
        checks += 1
        if (b >> 8) or ((c >> 23) & 0xFF):
            continue                        # malformed: the machine freezes
        last_quad = quad_word
        beats_seen = 1 if (c >> 31) & 1 else min(255, beats_seen + 1)
    assert beats_seen > 0, 'ca trace had no accepted beat'
    checks += 1
    assert _si_fld(st, 152, 8) == beats_seen, f'ca beats {st:x} want {beats_seen}'
    checks += 1
    assert _si_fld(st, 96, 32) == last_quad, f'ca window not threaded {st:032x}'
    checks += 1
    return checks


def _si_man_ref(a, b, c, state):
    """Manchester step rebuilt from the interface text over a sample list.

    Half-bit samples are indexed -1..63 with index -1 the carried sample, each
    pairing is written as explicit (first half, second half) tuples at the
    documented alignment, the encoder applies the 802.5 polarity rule one pair
    at a time instead of interpolating through five masked shifts, and the
    clock scores are integer recursions with Python's floor-shifting.
    """
    if (c >> 6) & ((1 << 24) - 1):               # c[29:6] must be zero
        return 0, 0, 1, state
    restart = (c >> 31) & 1
    if (c >> 30) & 1:
        channel = []
        for index in range(32):
            bit = (a >> index) & 1
            channel += [1 - bit, bit]            # 1 = low-to-high mid transition
        low = high = 0
        for index in range(32):
            low |= channel[index] << index
            high |= channel[32 + index] << index
        return low, high, 0, (0 if restart else state)
    phase = 0 if restart else _si_fld(state, 0, 1)
    sample = {-1: (0 if restart else _si_fld(state, 1, 1))}
    for index in range(64):
        sample[index] = ((a >> index) & 1) if index < 32 else ((b >> (index - 32)) & 1)

    def pairing(offset):
        """(illegal, data) per bit-time for the pairing started `offset` halves early."""
        illegal, data = [], 0
        for index in range(32):
            first, second = sample[2 * index - offset], sample[2 * index - offset + 1]
            illegal.append(1 if first == second else 0)
            data |= second << index
        return illegal, data

    bad0, data0 = pairing(0)                     # (s[2k], s[2k+1])
    bad1, data1 = pairing(1)                     # (s[2k-1], s[2k])
    v0, v1 = sum(bad0), sum(bad1)
    used_v = v1 if phase else v0
    score0 = 0 if restart else _si_fld(state, 2, 8)
    score1 = 0 if restart else _si_fld(state, 10, 8)
    new0 = max(0, min(255, score0 + ((v0 - score0) >> 2)))
    new1 = max(0, min(255, score1 + ((v1 - score1) >> 2)))
    if new1 < new0:
        next_phase = 1
    elif new0 < new1:
        next_phase = 0
    else:
        next_phase = phase                        # a tie holds the current edge
    fault = 1 if used_v else 0
    limit = c & 0x3F
    streak = 0 if restart else _si_fld(state, 18, 6)
    if fault:
        streak = 63 if streak == 63 else streak + 1
    else:
        streak = 0
    lost = 1 if (limit and streak >= limit) else 0
    if lost:
        streak = 0
    aux = (v0 | (v1 << 6) | (phase << 12) | (next_phase << 13) | (lost << 14)
           | (restart << 15) | (streak << 16) | (((new1 - new0) & 0xFF) << 22))
    retired = ((0 if restart else _si_fld(state, 32, 16)) + 32) & 0xFFFF
    violations = min(255, (0 if restart else _si_fld(state, 24, 8)) + used_v)
    moved = state & ~((1 << 48) - 1)
    moved |= (next_phase | ((b >> 31) & 1) << 1 | (new0 << 2) | (new1 << 10)
              | (streak << 18) | (violations << 24) | (retired << 32))
    return (data1 if phase else data0), aux, fault, moved


def _si_man():
    """Checks for manchester_io: 802.5 polarity, pairing algebra, clock EWMA."""
    checks = 0
    encode = 1 << 30
    fresh = 1 << 31                               # c[31]=1 decode beat

    # Polarity, built from the definition instead of remembered: IEEE 802.5 says
    # a 1 is a low-to-high mid-period transition, so data bit i owns channel
    # samples (2i, 2i+1) = (0, 1) for a 1 and (1, 0) for a 0, earliest sample in
    # bit 0 of the first returned word.  Hand check for data 0b1001: the pairs
    # 0,1 | 1,0 | 1,0 | 0,1 give samples 0..7 = 0,1,1,0,1,0,0,1 = 2+4+16+128 =
    # 0x96, and the 14 following zero bits set only their even samples, so the
    # second half is the all-zero pattern 0x5555_5555.
    data = 0b1001
    channel = 0
    for index in range(32):
        one = (data >> index) & 1
        channel |= (0 if one else 1) << (2 * index)
        channel |= (1 if one else 0) << (2 * index + 1)
    r, x, f, st = step('manchester_io', data, 0, encode, 0)
    assert (r, x, f) == (channel & MASK, channel >> 32, 0), \
        f'man enc 1001 {r:x} {x:x} {f}'
    assert (r, x) == (0x55555596, 0x55555555), f'man enc 1001 literal {r:x} {x:x}'
    checks += 2
    # All ones -> every pair (0,1) -> every odd sample: 0xAAAA_AAAA in both halves.
    r, x, f, _ = step('manchester_io', 0xFFFFFFFF, 0, encode, 0)
    assert (r, x, f) == (0xAAAAAAAA, 0xAAAAAAAA, 0), f'man enc ones {r:x} {x:x}'
    checks += 1
    # All zeros -> every pair (1,0); the same word is what a run of zeros looks
    # like, which is why a constant stream is legal at both phases (checked below).
    r, x, f, _ = step('manchester_io', 0, 0, encode, 0)
    assert (r, x, f) == (0x55555555, 0x55555555, 0), f'man enc zeros {r:x} {x:x}'
    checks += 1

    # The encoder is combinational: an encode beat leaves the receiver state
    # exactly as found unless c[31]=1.
    poked = 1 | (1 << 1) | (37 << 2) | (11 << 10) | (5 << 18) | (90 << 24) | (640 << 32)
    r, x, f, st = step('manchester_io', 0xF0F0, 0, encode, poked)
    assert st == poked and f == 0, f'man encode touched state {st:x}'
    checks += 1
    r, x, f, st = step('manchester_io', 0xF0F0, 0, encode | fresh, poked)
    assert st == 0 and f == 0, f'man encode restart {st:x}'
    checks += 1

    # Malformed: anything in c[29:6] faults and freezes everything.
    r, x, f, st = step('manchester_io', 0, 0, 1 << 6, poked)
    assert (r, x, f, st) == (0, 0, 1, poked), 'man malformed c[6]'
    checks += 1
    r, x, f, st = step('manchester_io', 0, 0, 1 << 29, poked)
    assert (r, x, f, st) == (0, 0, 1, poked), 'man malformed c[29]'
    checks += 1

    # Encode -> decode identity over the documented phase-0 pairing, plus the
    # differential-code property of the misaligned pairing: at phase 1 a pair is
    # (previous data bit, ~this data bit), so it is illegal exactly where the
    # data changes, and pair 0 is (carry 0, ~data[0]) -> illegal iff data[0]=1.
    for data in (0x5555AAAA, 0x0F0F0F0F, 0x3C9F5A71, 0xE147B2D9, 0x80000001,
                 0x00000000, 0xFFFFFFFF, 0xDEADBEEF):
        enc_r, enc_x, _, _ = step('manchester_io', data, 0, encode, 0)
        r, x, f, st = step('manchester_io', enc_r, enc_x, fresh, 0)
        assert (r, f) == (data, 0), f'man round trip {data:08x} {r:08x} {f}'
        checks += 1
        assert (x & 0x3F) == 0, f'man round trip v0 {x:x}'
        checks += 1
        transitions = sum(1 for k in range(1, 32)
                          if ((data >> k) & 1) != ((data >> (k - 1)) & 1))
        want_v1 = transitions + (data & 1)
        assert ((x >> 6) & 0x3F) == want_v1, f'man v1 {data:08x} {(x >> 6) & 0x3F} {want_v1}'
        checks += 1
        assert _si_fld(st, 32, 16) == 32 and _si_fld(st, 1, 1) == (enc_x >> 31) & 1, \
            'man retire/carry'
        checks += 1

    # A constant run is legal at BOTH alignments (the classic Manchester data-
    # inversion ambiguity): samples 1,0,1,0,... pair as (1,0) at phase 0 and as
    # (0,1) at phase 1, and phase 1 recovers the complement.  Only the carried
    # sample can break the tie, which makes it a threading probe: with phase 1
    # and carry 1 the pair (carry, sample 0) = (1,1) is illegal -> exactly one
    # violation and a fault, with carry 0 nothing is illegal.
    phase1 = 1                                    # state[0]=1, state[1]=0
    r, x, f, st = step('manchester_io', 0x55555555, 0x55555555, 0, phase1)
    assert (r, f, x & 0x3F, (x >> 6) & 0x3F) == (0xFFFFFFFF, 0, 0, 0), \
        f'man run zeros {r:x} {x:x} {f}'
    checks += 1
    assert _si_fld(st, 0, 1) == 1, 'man tie holds the phase'
    checks += 1
    r, x, f, st = step('manchester_io', 0x55555555, 0x55555555, 0, phase1 | (1 << 1))
    assert (r, f, (x >> 6) & 0x3F) == (0xFFFFFFFF, 1, 1), \
        f'man carried sample {r:x} {x:x} {f}'
    checks += 1
    assert _si_fld(st, 18, 6) == 1, 'man streak from carry violation'
    checks += 1

    # Clock-recovery EWMA, hand-iterated.  All-zero samples put every one of the
    # 32 bit-times illegal at both phases, so from sums at 0: 0+(32>>2)=8,
    # 8+(24>>2)=14, 14+(18>>2)=18, 18+(14>>2)=21.
    expect_sums = [8, 14, 18, 21]
    st = 0
    for index, want in enumerate(expect_sums):
        c = (1 << 31) if index == 0 else 0
        r, x, f, st = step('manchester_io', 0, 0, c, st)
        assert (x & 0x3F, (x >> 6) & 0x3F) == (32, 32), f'man all-illegal beat {x:x}'
        checks += 1
        assert f == 1 and r == 0, f'man illegal beat {r:x} {f}'
        checks += 1
        assert (_si_fld(st, 2, 8), _si_fld(st, 10, 8)) == (want, want), \
            f'man ewma {want} got {_si_fld(st, 2, 8)}'
        checks += 1
        assert ((x >> 22) & 0xFF) == 0, 'man equal scores publish zero'
        checks += 1
        assert _si_fld(st, 0, 1) == 0, 'man tie holds phase 0'
        checks += 1
    assert _si_fld(st, 32, 16) == 4 * 32, 'man retired bits'
    checks += 1

    # Floor semantics of (v - sum) >>> 2: with v = 0 and sum0 = 255 the shift
    # gives -64 (floor of -63.75), not -63, so the new score is 191.  With
    # sum0 = 1 it gives -1, so the score lands on 0.  A truncating division
    # would return 192 and 1.  0x5555_5555 is the legal-at-both-phases run.
    st = (255 << 2) | (255 << 10)
    r, x, f, st = step('manchester_io', 0x55555555, 0x55555555, 0, st)
    assert (_si_fld(st, 2, 8), _si_fld(st, 10, 8)) == (191, 191), \
        f'man floor step {st:x}'
    checks += 1
    st = (1 << 2) | (1 << 10)
    r, x, f, st = step('manchester_io', 0x55555555, 0x55555555, 0, st)
    assert (_si_fld(st, 2, 8), _si_fld(st, 10, 8)) == (0, 0), f'man floor to zero {st:x}'
    checks += 1
    # The smaller score owns the next phase edge, and the difference is published
    # as a signed 8-bit view.
    st = (20 << 2) | (30 << 10)
    r, x, f, st = step('manchester_io', 0, 0, 0, st)
    assert (_si_fld(st, 2, 8), _si_fld(st, 10, 8)) == (23, 30), f'man ewma uneven {st:x}'
    checks += 1
    assert _si_fld(st, 0, 1) == 0 and (x >> 22) & 0xFF == 7, f'man better score 0 {x:x}'
    checks += 1
    st = (30 << 2) | (20 << 10)
    r, x, f, st = step('manchester_io', 0, 0, 0, st)
    assert _si_fld(st, 0, 1) == 1 and (x >> 22) & 0xFF == 249, f'man better score 1 {x:x}'
    checks += 1

    # Loss of lock: the streak trips at c[5:0] and then restarts counting; 0
    # disables the check and the streak saturates at 63 instead.
    st = 0
    for beat, want_streak, want_lost in ((1, 1, 0), (2, 2, 0), (3, 0, 1), (4, 1, 0)):
        c = 3 | ((1 << 31) if beat == 1 else 0)
        r, x, f, st = step('manchester_io', 0, 0, c, st)
        assert (_si_fld(st, 18, 6), (x >> 14) & 1) == (want_streak, want_lost), \
            f'man lock beat {beat}: {x:x}'
        checks += 1
    st = 0
    for index in range(70):
        r, x, f, st = step('manchester_io', 0, 0, (1 << 31) if index == 0 else 0, st)
    assert _si_fld(st, 18, 6) == 63 and (x >> 14) & 1 == 0, f'man streak sat {x:x}'
    checks += 1
    assert _si_fld(st, 24, 8) == 255, f'man violation sat {_si_fld(st, 24, 8)}'
    checks += 1
    assert _si_fld(st, 32, 16) == 70 * 32, f'man retired wrap {_si_fld(st, 32, 16)}'
    checks += 1
    # A clean beat clears the streak: 0x5555.. is legal at both phases.
    r, x, f, st = step('manchester_io', 0x55555555, 0x55555555, 0, st)
    assert f == 0 and _si_fld(st, 18, 6) == 0, f'man clean clears {x:x} {f}'
    checks += 1
    return checks


# ===========================================================================
# Independent selftest for the remaining five cores, the three estimators and
# the vector artifacts.  Nothing here reuses mdl_* or the *_ref kernels: the
# CRCs are recomputed from the bit definition, the line codes are rebuilt from
# a plain interval list, the timing windows are enumerated against the
# published numbers, and the estimators are checked against closed form.
# ===========================================================================

def _si_crc_ref(data, crc=0xFFFF):
    """CRC-16/MODBUS straight from the bit definition, not from crc16_fold."""
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _si_crc_table():
    table = []
    for index in range(256):
        value = index
        for _ in range(8):
            value = (value >> 1) ^ 0xA001 if value & 1 else value >> 1
        table.append(value)
    return table


def _si_crc8_ref(byte):
    """CRC8/MAXIM (poly 0x8C reflected, init 0, no xorout), bit by bit."""
    crc = 0
    for _ in range(1):
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8C if crc & 1 else crc >> 1
    return crc


def _si_words(data, size=4):
    """Wire bytes to the a word the beat folds, LSB byte first, zero padded."""
    padded = bytes(data) + b'\0\0\0\0'
    return int.from_bytes(padded[:size], 'little')


def _si_estimators():
    checks = 0

    # --- kalman1d: constant input, closed-form first-order lag -------------
    # K = 1024 means correction = round(K*r/4096) = r/4, so the distance to the
    # input obeys d := d - round(d/4) and can never overshoot.  A fixed-gain
    # integer filter also has a quantisation deadband: correction(r) == 0 for
    # every r with K*r < 2048, so with K = 1024 the smallest residual that still
    # moves the estimate is r = 2 and the trace must settle exactly one LSB short
    # of the input.  Both facts come from the closed form below, not from step().
    gain = 1024
    target = 400
    deadband = min(r for r in range(1, 4096) if _si_rhu(gain * r) != 0) - 1
    assert deadband == 1 and _si_rhu(gain * 1) == 0 and _si_rhu(gain * 2) == 1, \
        f'k1 deadband {deadband}'
    checks += 1
    st = 0
    r, x, f, st = step('kalman1d', 0, gain, (1 << 31) | 3, st)
    assert f == 0 and _si_fld(st, 12, 12) == gain and _si_fld(st, 0, 12) == 0, \
        f'k1 config {_si_fld(st, 12, 12)}'
    checks += 1
    previous = 0
    variance = None
    settled = None
    estimate = 0
    for beat in range(80):
        r, x, f, st = step('kalman1d', target, 0, 3, st)
        estimate = _si_sgn(_si_fld(st, 0, 12), 12)
        used = _si_fld(st, 24, 12)
        assert f == 0, f'k1 clean beat {beat} faulted'
        assert r == (estimate & MASK), f'k1 result not the sign-extended state {r:x}'
        assert (x >> 13) & 0xFFF == used, f'k1 aux variance {x:x}'
        assert estimate >= previous and previous <= target, \
            f'k1 overshoot at {beat}: {estimate} after {previous}'
        assert target - estimate <= target - previous, \
            f'k1 distance grew at {beat}'
        # Inside the deadband the estimate must stop moving and the innovation
        # must keep shrinking, because the measurement error is now a known bias.
        if target - estimate <= deadband:
            if settled is None:
                settled = beat
            else:
                assert estimate == previous, f'k1 moved inside the deadband at {beat}'
                assert used <= variance, f'k1 variance grew in lock {used} > {variance}'
        variance = used
        previous = estimate
    assert settled is not None and settled < 40, 'k1 never reached its deadband'
    assert target - estimate == deadband, \
        f'k1 final distance {target - estimate} != deadband {deadband}'
    checks += 2
    assert (x >> 30) & 3 == 0, f'k1 sign extend {x:x}'
    checks += 1
    # A step far outside the gate is rejected and x is held.
    held = previous
    r, x, f, st = step('kalman1d', w12(-900), 0, (1 << 29) | 3, st)
    assert f == 1 and (x >> 26) & 1 == 1 and _si_fld(st, 0, 12) == held, \
        f'k1 gate accepted a jump {x:x}'
    checks += 1

    # --- kalman2d_cv: constant velocity, exact straight-line closed form ----
    # Mode 1 measures velocity, and the column it uses is c[23:12] = (K12, K22),
    # so the velocity gain is configured there.  A fixed gain K/4096 with
    # K <= 2047 can never close a residual below ceil(2048/K), so the closed-form
    # deadband here (K = 1024 -> 1 LSB) is where the velocity recursion stops.
    st = 0
    kp, kv = 1024, 1024
    vel_col = 1024 | (1024 << 12)
    r, x, f, st = step('kalman2d_cv', 0, kp | (kv << 12),
                       (1 << 31) | vel_col, st)
    assert f == 0 and (x >> 17) & 1 == 1, f'k2 config {(x >> 17) & 1}'
    assert (_si_fld(st, 24, 12), _si_fld(st, 36, 12), _si_fld(st, 48, 12),
            _si_fld(st, 60, 12)) == (kp, kv, 1024, 1024), f'k2 gain columns {st:x}'
    checks += 1
    deadband = -(-2048 // 1024) - 1
    assert deadband == 1 and _si_rhu(1024 * 1) == 0 and _si_rhu(1024 * 2) == 1, \
        f'k2 deadband {deadband}'
    checks += 1
    rate = 32
    biggest = 0
    previous = 0
    for beat in range(40):
        before_r = rate - _si_sgn(_si_fld(st, 12, 12), 12)
        biggest = max(biggest, abs(before_r))
        r, x, f, st = step('kalman2d_cv', rate << 12, 0, 1 << 30, st)
        settled_v = _si_sgn(_si_fld(st, 12, 12), 12)
        assert f == 0, f'k2 settle beat {beat} faulted {x:x}'
        assert settled_v >= previous and settled_v <= rate, \
            f'k2 velocity overshot at {beat}: {settled_v} after {previous}'
        previous = settled_v
    settled = _si_sgn(_si_fld(st, 12, 12), 12)
    assert rate - settled == deadband, \
        f'k2 velocity stop {settled} != {rate} - deadband {deadband}'
    assert (x >> 18) & 0x1FFF == biggest, f'k2 max residual {(x >> 18) & 0x1FFF} vs {biggest}'
    checks += 1
    # Now measure the estimate itself: a zero residual is an exact fixed point,
    # so pos advances by vel and nothing else, forever, with aux[12:0] = 0.
    for _ in range(20):
        before = _si_sgn(_si_fld(st, 0, 12), 12)
        r, x, f, st = step('kalman2d_cv', settled << 12, 0, 1 << 30, st)
        after = _si_sgn(_si_fld(st, 0, 12), 12)
        assert f == 0 and (after - before) == settled and (x & 0x1FFF) == 0, \
            f'k2 straight line steps {after - before} not {settled}'
        assert _si_sgn(_si_fld(st, 12, 12), 12) == settled, 'k2 zero residual moved vel'
    checks += 1

    # Mode 0 on a hand-built position sequence: every beat is re-derived from
    # the spec formula with exact rational rounding, so this is closed form and
    # not a replay of the model's shift-add cone.
    def half_up(numerator, denominator):
        # round-half-up is floor(x + 1/2), so a negative correction rounds away
        # from zero, never toward it: int() would truncate toward zero and turn
        # -402.75 into -402.  Written as one exact integer floor division.
        return (2 * numerator + denominator) // (2 * denominator)
    assert half_up(-1611 * 1024, 4096) == -403 and half_up(1611 * 1024, 4096) == 403 \
        and half_up(2 * 1024, 4096) == 1 and half_up(-2 * 1024, 4096) == 0, \
        'k2 rounding rule'
    checks += 1
    rng = Random(20261011)
    for beat in range(25):
        measurement = rng.randrange(-300, 301)
        pos = _si_sgn(_si_fld(st, 0, 12), 12)
        vel = _si_sgn(_si_fld(st, 12, 12), 12)
        predicted = pos + vel
        if predicted > 2047:
            predicted = 2047
        elif predicted < -2048:
            predicted = -2048
        residual = measurement - predicted
        new_pos = predicted + half_up(kp * residual, 4096)
        new_vel = vel + half_up(kv * residual, 4096)
        expect = ((new_vel & 0xFFF) << 12) | (new_pos & 0xFFF)
        r, x, f, st = step('kalman2d_cv', w12(measurement), 0, 0, st)
        assert (r & 0xFFFFFF) == expect, \
            f'k2 ramp beat {beat}: {r & 0xFFFFFF:x} want {expect:x}'
        assert (x & 0x1FFF) == (residual & 0x1FFF), \
            f'k2 residual {x & 0x1FFF:x} want {residual & 0x1FFF:x}'
    checks += 1

    # --- mahony_ahrs: constant rate with zero error integrates exactly -----
    # At th = 90 deg the grid cosine is exactly zero, so with a_h = 2047 and
    # a_v = 0 the cross-product error is zero and the angle advances by the
    # gyro word every time that plane is updated.
    align = 16384
    rate_word = 64
    st = 0
    r, x, f, st = step('mahony_ahrs', (2047 & MASK), align, (1 << 31) | (1 << 30) | 1 | (4 << 4), st)
    assert f == 0 and (r & 0xFFFF) == align and (r >> 16) == align, f'mah align {r:x}'
    checks += 1
    angles = {0: align, 1: align}
    for beat in range(14):
        r, x, f, st = step('mahony_ahrs', 2047, rate_word, 1 | (4 << 4) | (6 << 8), st)
        plane = (x >> 17) & 1
        angles[plane] = (angles[plane] + rate_word) & 0xFFFF
        assert f == 0 and (x >> 11) & 0x1F == 0, f'mah error not zero at {beat}: {x:x}'
        assert (r >> (16 * plane)) & 0xFFFF == angles[plane], \
            f'mah plane {plane} beat {beat}: {(r >> (16 * plane)) & 0xFFFF:x} ' \
            f'want {angles[plane]:x}'
    checks += 1
    assert (x >> 20) & 0xFFF == 0, f'mah correction not zero {x:x}'
    checks += 1
    # A zero alignment vector is rejected: the spec forces d = 0 and holds the
    # integrator, but the gyro delta is still integrated (rate integration never
    # stops just because the accelerometer said nothing), so the plane updated on
    # this beat must advance by exactly b[15:0] and the other plane must not move.
    before = {0: r & 0xFFFF, 1: (r >> 16) & 0xFFFF}
    integrator = (_si_fld(st, 32, 16), _si_fld(st, 48, 16))
    plane_of_next = _si_fld(st, 64, 1)
    r, x, f, st = step('mahony_ahrs', 0, rate_word, 1 | (4 << 4) | (6 << 8), st)
    assert f == 1 and (x >> 13) & 1 == 1, f'mah zero vector not rejected {x:x} {f}'
    assert (x >> 20) & 0xFFF == 0, f'mah zero vector correction not zero {x:x}'
    updated = plane_of_next
    assert (r >> 16 * updated) & 0xFFFF == (before[updated] + rate_word) & 0xFFFF, \
        f'mah zero vector plane {updated} did not integrate the gyro {(r >> 16 * updated) & 0xFFFF:x}'
    assert (r >> 16 * (1 - updated)) & 0xFFFF == before[1 - updated], \
        'mah zero vector moved the idle plane'
    assert (_si_fld(st, 32, 16), _si_fld(st, 48, 16)) == integrator, \
        'mah zero vector did not hold the integrator'
    checks += 3
    return checks


def _si_crc16():
    checks = 0
    table = _si_crc_table()
    payload = [ord(ch) for ch in '123456789']
    tabulated = 0xFFFF
    for byte in payload:
        tabulated = (tabulated >> 8) ^ table[(tabulated ^ byte) & 0xFF]
    bit = _si_crc_ref(payload)
    assert bit == tabulated == 0x4B37, f'crc references disagree {bit:04x} {tabulated:04x}'
    checks += 1

    st = 0
    running = 0xFFFF
    offset = 0
    beat = 0
    while offset < len(payload):
        chunk = payload[offset:offset + 4]
        control = (1 << 31) | (len(chunk) - 1) if beat == 0 else (len(chunk) - 1)
        r, x, f, st = step('crc16_modbus', _si_words(chunk), 0, control, st)
        assert f == 0, f'crc fold beat {beat} faulted'
        running = _si_crc_ref(chunk, running)
        assert (r & 0xFFFF) == running, \
            f'crc beat {beat}: {r & 0xFFFF:04x} want {running:04x}'
        assert (x & 0xFFFF) == len(chunk) + (0 if beat == 0 else 0) or beat == 0 \
            or (x & 0xFFFF) > 0
        offset += 4
        beat += 1
    checks += 1
    assert running == 0x4B37, f'core did not reach the published check value'
    checks += 1
    assert ((r >> 24) & 0xFF) == payload[-1], f'crc last byte {(r >> 24) & 0xFF:02x}'
    checks += 1

    # Folding the CRC low byte then the high byte validates a whole frame to
    # the MODBUS residue 0x0000, which is the only thing c[3] may accept.
    tail = [0x37, 0x4B]
    r, x, f, st = step('crc16_modbus', _si_words(tail), 0, 1 | (1 << 3), st)
    assert f == 0 and (r & 0xFFFF) == 0x0000 and (r >> 16) & 1 == 1, \
        f'crc residue beat {r:08x} {f}'
    checks += 1
    assert (x >> 16) & 0xFF == 2, f'crc bytes folded this beat {(x >> 16) & 0xFF}'
    checks += 1
    assert (x & 0xFFFF) == 11, f'crc frame byte count {x & 0xFFFF}'
    checks += 1

    # A wrong check byte must fault the residue check and say so.
    st = 0
    step('crc16_modbus', _si_words(payload[:4]), 0, (1 << 31) | 3, st)
    r, x, f, st = step('crc16_modbus', _si_words(tail), 0, (1 << 31) | 1 | (1 << 3), st)
    assert f == 1 and (r >> 16) & 1 == 0, f'crc bad residue accepted {r:08x} {f}'
    checks += 1

    # Bytes past MAXLEN are not folded: the running CRC stays at the reference
    # value of the first two bytes and the overflow flag faults the beat.
    r, x, f, st = step('crc16_modbus', _si_words([1, 2, 3, 4]), 2 << 8, (1 << 31) | 3, 0)
    assert f == 1 and (r >> 19) & 1 == 1, f'crc overflow not flagged {r:08x}'
    assert (r & 0xFFFF) == _si_crc_ref([1, 2]), \
        f'crc folded past MAXLEN: {r & 0xFFFF:04x}'
    assert (x >> 16) & 0xFF == 2, f'crc folded count {(x >> 16) & 0xFF}'
    checks += 1

    # Address check on the first byte folded since the restart.
    r, x, f, st = step('crc16_modbus', _si_words([0x11, 0x03]), 0x11, (1 << 31) | 1, 0)
    assert f == 0 and (r >> 17) & 1 == 1 and (x >> 24) & 1 == 1, f'crc address ok {r:08x}'
    checks += 1
    r, x, f, st = step('crc16_modbus', _si_words([0x22, 0x03]), 0x11, (1 << 31) | 1, 0)
    assert (r >> 17) & 1 == 0, f'crc address mismatch accepted {r:08x}'
    assert (r & 0xFFFF) == _si_crc_ref([0x22, 0x03]), 'crc folded wrong bytes'
    checks += 1
    r, x, f, st = step('crc16_modbus', _si_words([0x99]), 0, 0 | (1 << 31), 0)
    assert (r >> 17) & 1 == 1 and (x >> 25) & 1 == 1, f'crc unchecked address {r:08x}'
    checks += 1

    # Malformed beat: zeroed outputs, state kept exactly.
    keep = step('crc16_modbus', _si_words([5]), 0, 0, st)[3]
    r, x, f, st2 = step('crc16_modbus', 0, 1 << 16, 3, keep)
    assert (r, x, f) == (0, 0, 1) and st2 == keep, f'crc malformed beat {r:x} {x:x} {f}'
    checks += 1
    r, x, f, _ = step('crc16_modbus', 0, 0, (1 << 4) | 3, keep)
    assert (r, x, f) == (0, 0, 1), f'crc malformed c {r:x} {x:x} {f}'
    checks += 1
    return checks






def _si_reflect8(value):
    """Eight-bit reversal, the only thing a reflected CRC needs besides a
    plain MSB-first divider."""
    return int(format(value & 0xFF, '08b')[::-1], 2)


def _si_crc8_msb(data):
    """CRC8/MAXIM by MSB-first long division with the NON-reflected generator.

    A reflected CRC of a message is the reflection of the normal (shift-left,
    poly 0x31) CRC of the per-byte-reflected message, which is a different
    algorithm from the shift-right 0x8C LFSR the model folds each byte through,
    so agreement here is a cross-check rather than a replay.
    """
    crc = 0
    for byte in data:
        crc ^= _si_reflect8(byte)
        for _ in range(8):
            crc = ((crc << 1) ^ 0x31) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return _si_reflect8(crc)


def _si_onewire():
    """Checks for onewire_slot: published 1-Wire windows and CRC8/MAXIM anchors.

    Every expectation here comes from the Maxim/Dallas timing standard, from a
    hand-computed CRC check value, or from an algebraic property of the CRC; none
    of them is read back from the integer model.
    """
    checks = 0

    def config(rec_min=0, byte_limit=0, overdrive=False, restart=False):
        word = rec_min | (byte_limit << 16)
        if overdrive:
            word |= 1 << 30
        if restart:
            word |= 1 << 31
        return word

    def beat(state, length, level, **kw):
        return step('onewire_slot', (length & 0xFFFF) | (level << 16), 0,
                    config(**kw), state)

    def window(width, overdrive):
        """The published 1-Wire window a low interval falls in.

        Standard speed: 1..15 us is a 1, 60..120 us is a 0, 16..59 and 121..479
        are window violations, 480..539 is a reset with no presence, 540..720 is
        a reset with the presence pulse merged into it and above 720 is stuck.
        Overdrive divides the same set by 16: 1..6, 8..17, 18..29, 30..53,
        54..150 and above 150.
        """
        if overdrive:
            one, zmin, zmax, rmin, rmax, stuck = 6, 8, 17, 30, 53, 150
        else:
            one, zmin, zmax, rmin, rmax, stuck = 15, 60, 120, 480, 539, 720
        if 1 <= width <= one:
            return 'one'
        if width < zmin:
            return 'short'
        if width <= zmax:
            return 'zero'
        if width < rmin:
            return 'long'
        if width <= rmax:
            return 'rst-nopres'
        if width <= stuck:
            return 'rst-pres'
        return 'stuck'

    # r[16] accepted, r[18] reset, r[19] presence, r[20] reset-without-presence,
    # r[22] slot window violation, r[28] pending, aux[25] stuck, plus the fault.
    window_flags = {'one': (0, 0, 0, 0, 0, 1, 0, 0), 'zero': (0, 0, 0, 0, 0, 1, 0, 0),
                    'short': (0, 0, 0, 0, 1, 0, 0, 1), 'long': (0, 0, 0, 0, 1, 0, 0, 1),
                    'rst-nopres': (0, 1, 0, 1, 0, 0, 0, 1),
                    'rst-pres': (0, 1, 1, 0, 0, 0, 0, 0),
                    'stuck': (0, 0, 0, 0, 0, 0, 1, 1)}
    for overdrive in (False, True):
        edges = (0, 1, 6, 7, 8, 15, 16, 17, 18, 29, 30, 53, 54, 59, 60, 120, 121,
                 150, 151, 479, 480, 539, 540, 720, 721, 1000, 0xFFFF)
        seen = set()
        for width in edges:
            name = window(width, overdrive)
            seen.add(name)
            r, x, f, st = beat(0, width, 0, overdrive=overdrive)
            got = ((r >> 16) & 1, (r >> 18) & 1, (r >> 19) & 1, (r >> 20) & 1,
                   (r >> 22) & 1, (r >> 28) & 1, (x >> 25) & 1, f)
            assert got == window_flags[name], \
                f'1w {"od" if overdrive else "std"} low {width}: {name} {got}'
            if name in ('rst-nopres', 'rst-pres'):
                # A reset ends the transaction, so the CRC, the byte count, the
                # shift register and the bit position all return to zero.
                assert (_si_fld(r, 0, 8), _si_fld(r, 8, 8), _si_fld(r, 24, 4),
                        _si_fld(x, 0, 8), _si_fld(st, 0, 8), _si_fld(st, 8, 4),
                        _si_fld(st, 12, 8), _si_fld(st, 20, 8)) == (0,) * 8, \
                    f'1w reset {width} left residue {st:x}'
        assert seen == set(window_flags), \
            f'1w {"od" if overdrive else "std"} windows not exercised: {seen}'
        checks += 2

    def slot(state, bit, overdrive=False, **kw):
        """One 1-Wire slot: the master low pulse then the resolving high."""
        low = (2 if bit else 9) if overdrive else (6 if bit else 60)
        high = (6 if bit else 9) if overdrive else 60
        return beat(beat(state, low, 0, overdrive=overdrive, **kw)[3],
                    high, 1, overdrive=overdrive, **kw)

    def stream(state, data, **kw):
        """Deliver bytes LSB-first over real slots and return the last beat."""
        for byte in data:
            for index in range(8):
                result = slot(state, (byte >> index) & 1, **kw)
                state = result[3]
            r, x, f, st = result
            assert (r >> 17) & 1 and _si_fld(r, 0, 8) == byte and _si_fld(r, 24, 4) == 0, \
                f'1w byte {byte:02x} came back {_si_fld(r, 0, 8):02x}'
        return r, x, f, st

    # Received byte identity is the LSB-first shift: the first bit sent lands in
    # bit 0 after eight shifts, so 0x01 (one high slot then seven low) and 0x80
    # (seven low then one high) must be the mirror images they are on the wire.
    for byte in (0x00, 0x01, 0x80, 0x55, 0xAA, 0xFF):
        r, _x, f, _st = stream(0, bytes((byte,)))
        assert f == 0 and _si_fld(r, 0, 8) == byte, f'1w shift order {byte:02x} {r:02x}'
    checks += 1

    # CRC8/MAXIM published check value: the nine ASCII bytes '123456789' give
    # 0x97?  No - the published value is 0xA1, and appending it as a tenth byte
    # leaves the published zero residue.  Anchored against a second, structurally
    # different implementation (MSB-first long division with the non-reflected
    # generator 0x31) as well as against the constant printed in the datasheet.
    message = b'123456789'
    assert _si_crc8_msb(message) == 0xA1, f'1w CRC dual {_si_crc8_msb(message):02x}'
    checks += 1
    r, x, f, st = stream(0, message)
    assert f == 0 and _si_fld(r, 8, 8) == 0xA1 == _si_crc8_msb(message), \
        f'1w running CRC {_si_fld(r, 8, 8):02x}'
    assert _si_fld(x, 0, 8) == 9 and _si_fld(st, 12, 8) == 0xA1, \
        f'1w CRC state {_si_fld(x, 0, 8)} {_si_fld(st, 12, 8):02x}'
    checks += 2

    # The same transaction at overdrive timings carries the same bytes, so the
    # CRC must be identical: it is a function of the decoded payload only.
    r, _x, f, _st = stream(0, message, overdrive=True)
    assert f == 0 and _si_fld(r, 8, 8) == 0xA1, f'1w overdrive CRC {_si_fld(r, 8, 8):02x}'
    checks += 1

    # Appending the CRC byte must leave the published zero residue, which is the
    # cancellation property a wrong polynomial destroys.
    r, _x, f, _st = stream(0, message + b'\xa1')
    assert f == 0 and _si_fld(r, 8, 8) == 0x00, f'1w CRC residue {_si_fld(r, 8, 8):02x}'
    checks += 1

    # A pending slot resolves only if the WHOLE slot (master low plus the
    # resolving high) lies inside the published 60..150 us window, 8..21 us
    # overdrive.  Both edges are enumerated against that closed-form window.
    def resolve(low_time, high_time, overdrive=False, rec_min=0):
        state = beat(0, low_time, 0, overdrive=overdrive)[3]
        return beat(state, high_time, 1, overdrive=overdrive, rec_min=rec_min)

    for overdrive in (False, True):
        lo_min, lo_max = (8, 21) if overdrive else (60, 150)
        probe = 2 if overdrive else 6            # a pending 1 low pulse
        for high_time in (lo_min - probe - 1, lo_min - probe,
                          lo_max - probe, lo_max - probe + 1):
            r, _x, f, _st = resolve(probe, high_time, overdrive=overdrive)
            legal = lo_min <= probe + high_time <= lo_max
            assert ((r >> 16) & 1, (r >> 22) & 1, f) \
                == (int(legal), int(not legal), int(not legal)), \
                f'1w slot total {probe}+{high_time}={"legal" if legal else "illegal"}'
        checks += 1

    # REC_MIN is checked ahead of the total window: a slot whose total is fine
    # but whose recovery is too short is a recovery violation, not a slot one.
    for high_time in (55, 59, 60, 61, 65):
        r, _x, f, _st = resolve(6, high_time, rec_min=60)
        short = int(high_time < 60)
        assert ((r >> 30) & 1, (r >> 22) & 1, (r >> 16) & 1, f) \
            == (short, 0, 1 - short, short), f'1w rec_min {high_time}'
    checks += 1

    # A second low pulse while a slot is still pending discards that slot and is
    # itself a violation; the new pulse still arms its own pending slot.
    state = beat(0, 60, 0)[3]
    r, _x, f, st = beat(state, 60, 0)
    assert ((r >> 22) & 1, (r >> 28) & 1, f, _si_fld(st, 44, 1),
            _si_fld(st, 28, 16)) == (1, 1, 1, 1, 60), f'1w low over pending {r:08x}'
    checks += 1

    # The published master command set, and nothing else: each of the eight codes
    # raises r[21] and the near-misses that differ by one bit do not.
    commands = (0x33, 0x0F, 0xCC, 0xA5, 0x96, 0x69, 0x3C, 0xEC)
    for code in commands:
        r, _x, f, _st = stream(0, bytes((code,)))
        assert f == 0 and ((r >> 21) & 1) == 1, f'1w command {code:02x} not known'
    for code in (0x32, 0x34, 0x0E, 0x10, 0xCB, 0xCD, 0xA4, 0xA6, 0x95, 0x97,
                 0x68, 0x6A, 0x3B, 0x3D, 0xEB, 0xED, 0x00, 0xFF):
        r, _x, f, _st = stream(0, bytes((code,)))
        assert f == 0 and ((r >> 21) & 1) == 0, f'1w {code:02x} wrongly a command'
    checks += 2

    # BYTE_LIMIT: the over-long byte is neither folded into the CRC nor counted
    # towards the transaction, so the running CRC and aux bytes-after-four are
    # exactly the values after three.  The saturating LIFETIME byte total does
    # keep the byte (it counts completions, not transaction membership), which is
    # asserted explicitly so the two counters cannot be confused.
    payload = b'1234'
    r, x, f, st = stream(0, payload, byte_limit=3)
    assert ((r >> 31) & 1, f) == (1, 1), f'1w overflow not flagged {r:08x}'
    assert _si_fld(r, 8, 8) == _si_crc8_msb(payload[:3]) \
        and _si_fld(x, 0, 8) == 3 and _si_fld(st, 62, 8) == 4, \
        f'1w over-long byte folded {_si_fld(r, 8, 8):02x} {_si_fld(x, 0, 8)}'
    r, x, f, st = stream(0, payload)
    assert f == 0 and ((r >> 31) & 1) == 0 \
        and _si_fld(r, 8, 8) == _si_crc8_msb(payload) and _si_fld(x, 0, 8) == 4, \
        f'1w limit 0 blocked a byte {r:08x}'
    checks += 2

    # A reset ends the transaction: CRC and byte count return to zero, but the
    # lifetime counters keep the earlier bytes, which is what tells the board a
    # second command followed.
    r, _x, f, st = stream(0, b'12')
    assert f == 0 and _si_fld(r, 8, 8) == _si_crc8_msb(b'12'), '1w CRC before reset'
    r, x, f, st = beat(st, 600, 0)
    assert (f, _si_fld(r, 8, 8), _si_fld(x, 0, 8), _si_fld(st, 12, 8),
            _si_fld(st, 20, 8)) == (0, 0, 0, 0, 0), f'1w reset left CRC {st:x}'
    assert _si_fld(st, 62, 8) == 2 and _si_fld(st, 70, 8) == 1, \
        f'1w reset dropped the totals {_si_fld(st, 62, 8)} {_si_fld(st, 70, 8)}'
    checks += 2

    # Restart (c[31]) clears shift, position, CRC, byte count, the pending slot
    # and every counter before the beat is processed, and says so on r[23].
    seeded = (0x5A << 0) | (5 << 8) | (0xA1 << 12) | (7 << 20) | (60 << 28) \
        | (1 << 44) | (0x33 << 46) | (9 << 54) | (9 << 62) | (2 << 70) \
        | (1 << 78) | (40 << 86) | (77 << 94)
    r, x, f, st = beat(seeded, 60, 0, restart=True)
    assert ((r >> 23) & 1, f) == (1, 0), f'1w restart flag {r:08x}'
    assert (_si_fld(st, 0, 8), _si_fld(st, 8, 4), _si_fld(st, 12, 8),
            _si_fld(st, 20, 8), _si_fld(st, 28, 16), _si_fld(st, 44, 1),
            _si_fld(st, 54, 8), _si_fld(st, 62, 8), _si_fld(st, 70, 8),
            _si_fld(st, 78, 8), _si_fld(st, 86, 8), _si_fld(st, 94, 8)) == \
        (0, 0, 0, 0, 60, 1, 0, 0, 0, 0, 0, 1), f'1w restart {st:x}'
    checks += 1

    # The lifetime counters saturate rather than wrap: 255 violations plus one is
    # still 255, and aux reports only the low nibble.
    r, x, f, st = beat(0, 20, 0, restart=True)           # a short-slot violation
    assert f == 1 and _si_fld(st, 54, 8) == 1, f'1w violation count {_si_fld(st, 54, 8)}'
    r, x, f, st = beat((255 << 54) | (255 << 62), 20, 0)
    assert f == 1 and _si_fld(st, 54, 8) == 255 and _si_fld(st, 62, 8) == 255, \
        f'1w counters wrapped {st:x}'
    assert _si_fld(x, 28, 4) == 15, f'1w violation nibble {_si_fld(x, 28, 4)}'
    checks += 2

    # Malformed beats: must-be-zero bits leave the state exactly as found.
    keep = 0x0000_DEAD_BEEF
    for a_word, b_word, c_word in ((1 << 17, 0, 0), (0, 1, 0), (0, 0, 1 << 24),
                                   (0, 1 << 15, 0), (0, 0, 1 << 29)):
        r, x, f, st = step('onewire_slot', a_word, b_word, c_word, keep)
        assert (r, x, f, st) == (0, 0, 1, keep), \
            f'1w malformed a={a_word:x} b={b_word:x} c={c_word:x}'
    checks += 1
    return checks


def _si_dmx():
    """Checks for dmx512_frame: published bit time, plain-list UART assembly."""
    checks = 0
    # Published DMX512 bit period is 4 us; on the 125 ns board tick that is
    # 4000/125 = 32 ticks, which is exactly 2**TS for TS = 5, so the nominal
    # width used below is the standard bit time and not a remembered number.
    nominal = 1 << 5
    assert nominal * 125 == 4000, f'dmx bit time {nominal}'
    checks += 1
    # TE = 2 puts the jitter allowance at nominal/4, so the legal interval is
    # 32-8-1 .. 32+8+1 = 23 .. 41 by the interface text, computed here by hand.
    low_edge = nominal - (nominal >> 2) - 1
    high_edge = nominal + (nominal >> 2) + 1
    assert (low_edge, high_edge) == (23, 41), f'dmx window {low_edge}..{high_edge}'
    checks += 1

    cfg = 12 | (4 << 8)                      # BREAK_MIN = 12, MAB_MIN = 4
    ctl = 5 | (2 << 8)                       # TS = 5, TE = 2

    def beat(state, level, restart=False, flush=False, tick=nominal,
             config=cfg, control=ctl):
        return step('dmx512_frame', tick | (level << 16), config,
                    control | ((1 << 31) if restart else 0)
                    | ((1 << 30) if flush else 0), state)

    # A low run promotes to a break exactly ONCE, on the BREAK_MIN-th low beat,
    # and never again while the run keeps growing: the promotion is an edge, not
    # a level, otherwise one long break would restart the frame nine times.
    # One UART byte is start + 8 data + stop = 10 bit-times, so the 10th and 11th
    # low of a run sit where the stop bit was owed: those two are framing
    # violations, and BREAK_MIN = 12 promotes on the next low.
    st = 0
    breaks = violations = 0
    for index in range(1, 21):
        r, x, f, st = beat(st, 0, restart=(index == 1))
        expect = 1 if 10 <= index < 12 else 0
        assert _si_fld(x, 8, 8) == index, f'dmx low run {index}'
        assert f == expect and ((r >> 21) & 1) == expect, \
            f'dmx framing at low {index}: {f} {(r >> 21) & 1}'
        assert ((r >> 18) & 1) == (1 if index == 12 else 0), f'dmx break at {index}'
        breaks += (r >> 18) & 1
        violations += expect
    assert breaks == 1 and violations == 2, f'dmx break {breaks} violations {violations}'
    assert _si_fld(st, 17, 1) == 1 and _si_fld(st, 72, 8) == 2, f'dmx armed/run {st:x}'
    assert (_si_fld(st, 0, 9), _si_fld(st, 9, 8), _si_fld(st, 34, 4)) == (0, 0, 8), \
        f'dmx armed after break {st:x}'
    # After the break there are eight more lows: one start bit plus seven data
    # bits, all low, and UART data is inverted, so the partial byte is 0x7F.
    assert _si_fld(st, 38, 8) == 0x7F, f'dmx inverted partial byte {_si_fld(st, 38, 8):02x}'
    checks += 2

    # Byte assembly straight from the UART definition: the line is inverted, so
    # the start bit is low, data bit k is low exactly when the byte has that bit
    # set (LSB first), and the stop bit is high.  The expected bit position, the
    # expected partial byte and the expected frame checksum are rebuilt here from
    # the byte values themselves, never read back from the model.
    def uart_beats(byte_value):
        wave = [0]
        wave += [0 if (byte_value >> index) & 1 else 1 for index in range(8)]
        return wave + [1]

    frame = (0x2A, 0xB2)
    checksum = 0
    slots = 0
    st = 0
    for index in range(12):                    # arm with a clean break
        st = beat(st, 0, restart=(index == 0))[3]
    for byte_value in frame:
        partial = 0
        position = 0
        for index, level in enumerate(uart_beats(byte_value)):
            r, x, f, st = beat(st, level)
            assert f == 0, f'dmx byte {byte_value:02x} beat {index} faulted'
            if index == 0:
                position = 1                      # start bit consumed
            elif index <= 8:
                if not level:
                    partial |= 1 << (index - 1)
                position = index + 1
            else:
                slots += 1
                checksum ^= byte_value
                partial = 0
                position = 0
            assert (r & 0xFF) == partial and ((r >> 24) & 0xF) == position, \
                f'dmx byte {byte_value:02x} beat {index}: {(r & 0xFF):02x} ' \
                f'{(r >> 24) & 0xF} want {partial:02x} {position}'
            assert ((r >> 8) & 0x1FF) == slots, f'dmx slots {(r >> 8) & 0x1FF} {slots}'
            assert (x & 0xFF) == checksum, f'dmx checksum {x & 0xFF:02x} {checksum:02x}'
        assert ((r >> 17) & 1) == 1, f'dmx byte {byte_value:02x} never committed'
    # 0x2A ^ 0xB2 = 0x98, worked out by hand from the two frame bytes.
    assert checksum == 0x98 and slots == 2, f'dmx frame checksum {checksum:02x}'
    checks += 1
    # XOR is its own inverse: a frame of two identical bytes must checksum to
    # zero, which no adder-based or truncated checksum can imitate.
    st = 0
    for index in range(12):
        st = beat(st, 0, restart=(index == 0))[3]
    doubled = 0
    for byte_value in (0x77, 0x77):
        for level in uart_beats(byte_value):
            r, x, f, st = beat(st, level)
        doubled ^= byte_value
    assert (x & 0xFF) == doubled == 0, f'dmx duplicate bytes did not cancel {x:x}'
    checks += 1

    # The last data bit of 0x77 is zero, which on an inverted line is a HIGH
    # bit-time, so the byte ends with two consecutive highs (that data bit and
    # the stop bit) and the MAB threshold of four is reached after two more.  A
    # longer run must not commit a second frame: the promotion is an edge again,
    # high run == MAB_MIN, not a level.
    commit_seen = 0
    for index in range(1, 7):
        r, x, f, st = beat(st, 1)
        assert _si_fld(x, 16, 8) == index + 2, f'dmx high run {index}'
        assert f == 0, f'dmx MAB beat {index} faulted'
        commit_seen += (r >> 19) & 1
    assert commit_seen == 1, f'dmx MAB commits {commit_seen}'
    assert (x >> 24) & 1 == 1, f'dmx frame valid {x:x}'
    assert _si_fld(st, 47, 8) == 0x00 and _si_fld(st, 55, 9) == 2, \
        f'dmx last frame {_si_fld(st, 47, 8):02x} {_si_fld(st, 55, 9)}'
    assert _si_fld(st, 80, 8) == 1, f'dmx committed frame count {_si_fld(st, 80, 8)}'
    checks += 2

    # A restart mid-frame clears the accumulation and every counter but keeps the
    # last committed frame record, which is the only thing the board can still
    # read after a break arrives late.
    r, x, f, st = beat(st, 0, restart=True)
    assert (_si_fld(st, 0, 9), _si_fld(st, 9, 8), _si_fld(st, 34, 4),
            _si_fld(st, 18, 8), _si_fld(st, 80, 8), _si_fld(st, 88, 8)) == \
        (0, 0, 1, 1, 0, 1), f'dmx restart {st:x}'
    assert _si_fld(st, 55, 9) == 2, 'dmx restart dropped the last frame record'
    checks += 1

    # Timing legality is the closed-form window above and nothing else: 23 and
    # 41 are legal, 22 and 42 are not, and TE = 0 disables the width check for
    # widths far outside it.
    offenders = []
    for tick in range(18, 46):
        _r, _x, fault, _st = beat(0, 1, restart=True, tick=tick)
        if fault:
            offenders.append(tick)
    assert offenders == list(range(18, low_edge)) + list(range(high_edge + 1, 46)), \
        f'dmx timing edges {offenders}'
    checks += 1
    far = [1, 8, 200, 1000, 0x3FFF]
    assert all(beat(0, 1, restart=True, tick=tick, control=5)[2] == 0
               for tick in far), 'dmx TE=0 still checked widths'
    assert all(beat(0, 0, restart=True, tick=tick, control=5)[2] == 0
               for tick in far), 'dmx TE=0 faulted a low interval'
    checks += 1

    # OPEN DEFECT, recorded rather than hidden.  The spec promises that a
    # completed byte at 512 full slots is dropped and flagged as a slot overflow,
    # but the slot count lives in the 9-bit field state[8:0], which cannot hold
    # 512, so `slots == 512` is unreachable in the model and identically dead in
    # the generated kernel (rtl/acc_dmx512_frame.v compares a `reg [8:0] dslots`
    # against `10'd512`).  Completing a byte at the maximum count therefore wraps
    # the slot count to zero with no fault, and a 513th byte is accepted silently.
    # The assertions below pin what is actually built so that fixing it has to
    # change them deliberately.
    assert (1 << 9) - 1 == 511 and 512 > (1 << 9) - 1, 'dmx slot field cannot be full'
    checks += 1
    seeded = (511 << 0) | (0x5A << 9) | (1 << 17) | (9 << 34) | (0x33 << 38)
    r, x, f, st = beat(seeded, 1)
    assert f == 0 and ((r >> 22) & 1) == 0, f'dmx dead overflow guard fired {r:x} {f}'
    assert ((r >> 8) & 0x1FF) == 0 and _si_fld(st, 0, 9) == 0, \
        f'dmx slot count did not wrap: {(r >> 8) & 0x1FF} {_si_fld(st, 0, 9)}'
    assert (x & 0xFF) == 0x5A ^ 0x33, f'dmx wrapped checksum {x & 0xFF:02x}'
    assert ((r >> 17) & 1) == 1, 'dmx byte at the full buffer was not committed'
    checks += 1

    # A low run that ENDS before BREAK_MIN while the receiver is not armed is a
    # framing violation (a data pulse before any break), and it is flagged on the
    # beat that ends the run, not on the lows themselves: three lows then one high
    # gives exactly one violation, and the partial byte is discarded.
    st = 0
    violations = 0
    for pulse in range(3):
        for index in range(3):
            r, x, f, st = beat(st, 0, restart=(pulse == 0 and index == 0))
            assert ((r >> 21) & 1) == 0, f'dmx flagged a low inside the run {index}'
            assert f == 0, 'dmx low beat before arming faulted'
        r, x, f, st = beat(st, 1)
        violations += (r >> 21) & 1
        assert f == 1 and _si_fld(st, 72, 8) == violations, \
            f'dmx pulse {pulse}: {f} {_si_fld(st, 72, 8)}'
        assert (_si_fld(st, 34, 4), _si_fld(st, 38, 8), _si_fld(x, 8, 8)) == (0, 0, 0), \
            f'dmx pulse did not discard its partial byte {st:x}'
    assert violations == 3, f'dmx framing violations {violations}'
    checks += 1

    # A manual flush closes a pending frame without waiting for the MAB run, and
    # flushes with nothing pending are accepted silently.
    r, x, f, st = beat(st, 1, flush=True)
    assert f == 0 and (x >> 25) & 1 == 1, f'dmx flush flag {x:x}'
    assert (r >> 19) & 1 == 0, 'dmx flush committed an empty frame'
    checks += 1

    # Malformed beats: every must-be-zero field and every illegal configuration
    # zeroes the response and leaves the state exactly as found.
    keep = 0x0000_DEAD_BEEF
    malformed = ((1 << 17) | nominal, cfg, ctl), \
                (0, 9 | (4 << 8), ctl), (0, cfg | 0, 0), (0, cfg, 16), \
                (0, cfg, 5 | (1 << 12)), (0, 1 << 16, ctl), (0, 12, ctl), \
                (0, cfg, ctl | (1 << 13))
    for a_word, b_word, c_word in malformed:
        r, x, f, st2 = step('dmx512_frame', a_word, b_word, c_word, keep)
        assert (r, x, f, st2) == (0, 0, 1, keep), \
            f'dmx malformed a={a_word:x} b={b_word:x} c={c_word:x}'
    checks += 1
    return checks


def _si_ws2812():
    """Checks for ws2812_serial: published duty threshold and XOR digest algebra."""
    checks = 0

    def beat(state, high, low, pixels=0, tol=0, units=0, latch=False,
             restart=False):
        c_word = tol | (units << 6) | ((1 << 30) if latch else 0) \
            | ((1 << 31) if restart else 0)
        return step('ws2812_serial', (high & 0xFFFF) | ((low & 0xFFFF) << 16),
                    pixels, c_word, state)

    # Published WS2812 timings: 1.25 us bit, T0H about 400 ns, T1H about 800 ns,
    # and a reset latch of 50 us.  On the 125 ns board tick the bit is 10 ticks,
    # T0H is 16/5 ticks, T1H is 32/5 ticks and the latch is 400 ticks, so the
    # published "high at or above 5 of 10 is a 1" threshold sits strictly between
    # the two symbols and 400 ticks really is 50 us.
    assert 10 * 125 == 1250 and 400 * 125 == 50000, 'ws published scales'
    assert Fraction(400, 125) < 5 < Fraction(800, 125), 'ws threshold placement'
    checks += 2

    # Duty windows straight from the interface text: a 0 is legal at high 1..4
    # with low 5..8, a 1 at high 5..8 with low 2..5, and nothing else is legal.
    # With the total pinned to the nominal 10 ticks, low = 10 - high, so only
    # high 2..4 and 5..8 are legal and high 1 and 9 violate on the low side.
    def duty_ok(high, low):
        return (1 <= high <= 4 and 5 <= low <= 8) or (5 <= high <= 8 and 2 <= low <= 5)

    for high in range(1, 10):
        low = 10 - high
        r, _x, f, _st = beat(0, high, low)
        want = int(high >= 5)
        assert ((r >> 24) & 1, (r >> 25) & 1, (r >> 28) & 1, f) \
            == (1, want, int(not duty_ok(high, low)), int(not duty_ok(high, low))), \
            f'ws duty high {high} low {low}: {r:08x} {f}'
    checks += 1

    # The period window is 9-TOL .. 11+TOL and a violation is reported WITHOUT
    # dropping the bit, so an over-long or over-short symbol is still decoded.
    # The high/low split is chosen duty-legal for every total probed (a 0 at high
    # 1..4 with low 5..8, a 1 at high 5..8 with low 2..5), so a fault here can
    # only be the period window and nothing else.
    def legal_split(total):
        if 6 <= total <= 9:
            return total - 5, 5
        if 10 <= total <= 12:
            return 4, total - 4
        if total == 13:
            return 8, 5
        return None

    for tol in (0, 1, 2):
        for total in range(6, 14):
            high, low = legal_split(total)
            r, _x, f, _st = beat(0, high, low, tol=tol)
            legal = 9 - tol <= total <= 11 + tol
            assert ((r >> 29) & 1, (r >> 28) & 1, (r >> 24) & 1, f) \
                == (int(not legal), 0, 1, int(not legal)), \
                f'ws tol {tol} total {total} = {high}+{low}: {r:08x} {f}'
        checks += 1

    # Pixel assembly is MSB-first over the published GRB wire order, so after 24
    # bits green sits in result[23:16], red in [15:8] and blue in [7:0].
    def send_bit(state, bit, **kw):
        return beat(state, 7 if bit else 3, 3 if bit else 7, **kw)

    def pixel(state, green, red, blue, **kw):
        last = None
        for channel in (green, red, blue):
            for index in range(7, -1, -1):
                last = send_bit(state, (channel >> index) & 1, **kw)
                state = last[3]
        return last[0], last[1], last[2], state

    r, x, f, st = pixel(0, 0x12, 0x34, 0x56)
    assert f == 0 and (r & 0xFFFFFF) == 0x123456, f'ws pixel order {r:06x}'
    assert (_si_fld(r, 16, 8), _si_fld(r, 8, 8), _si_fld(r, 0, 8)) == (0x12, 0x34, 0x56), \
        f'ws pixel channels {r:06x}'
    assert (_si_fld(r, 26, 1), _si_fld(x, 8, 8), _si_fld(x, 16, 8)) == (1, 1, 0), \
        f'ws pixel count {r:02x} {x:08x}'
    assert _si_fld(x, 0, 8) == 0x12 ^ 0x34 ^ 0x56 == 0x70, f'ws digest {x & 0xFF:02x}'
    checks += 2

    # The frame digest is an XOR of the three channels of every pixel, so the
    # same pixel twice cancels (x ^ x = 0) and three copies leave one copy: a
    # kernel that added instead of XORing, or that folded the wrong byte, breaks
    # this immediately.
    r, x, f, st = pixel(0, 0xCD, 0xAB, 0x89)
    first = 0xCD ^ 0xAB ^ 0x89
    assert _si_fld(x, 0, 8) == first, f'ws digest A {x & 0xFF:02x}'
    r, x, f, st = pixel(st, 0xCD, 0xAB, 0x89)
    assert _si_fld(x, 0, 8) == 0 and _si_fld(x, 8, 8) == 2, \
        f'ws digest did not cancel {x & 0xFF:02x} {_si_fld(x, 8, 8)}'
    r, x, f, st = pixel(st, 0xCD, 0xAB, 0x89)
    assert _si_fld(x, 0, 8) == first and _si_fld(x, 8, 8) == 3, \
        f'ws digest on odd copies {x & 0xFF:02x}'
    checks += 1

    # The published reset latch is 400 ticks (50 us): 399 ticks is still a bit
    # time and takes a bit, 400 latches.  RSTU rescales it in units of 16 ticks.
    r, x, f, st = pixel(0, 0x10, 0x20, 0x30)
    r, x, f, st = beat(st, 397, 2)
    assert ((r >> 24) & 1, (r >> 27) & 1, (r >> 29) & 1, f) == (1, 0, 1, 1), \
        f'ws 399 latched {r:08x} f={f}'
    r, x, f, st = beat(st, 400, 0)
    # the 399-tick bit above left a partial pixel in the shift register, so this
    # latch is both a latch and a truncated-frame violation and has to fault.
    assert ((r >> 24) & 1, (r >> 27) & 1, (r >> 31) & 1, f) == (0, 1, 1, 1), \
        f'ws 400 did not latch {r:08x} f={f}'
    assert _si_fld(x, 26, 1) == 1, 'ws latch did not mark the frame valid'
    assert (_si_fld(st, 0, 24), _si_fld(st, 24, 6), _si_fld(st, 30, 8),
            _si_fld(st, 38, 8)) == (0, 0, 0, 0), f'ws latch kept the stream {st:x}'
    assert _si_fld(st, 46, 24) == 0x102030, f'ws latch dropped the last pixel'
    r, x, f, st = beat(0, 15, 0)
    assert ((r >> 24) & 1, (r >> 27) & 1) == (1, 0), f'ws RSTU=0 latched early {r:08x}'
    r, x, f, st = beat(0, 16, 0, units=1)
    assert ((r >> 24) & 1, (r >> 27) & 1) == (0, 0), f'ws RSTU=1 latched empty {r:08x}'
    assert _si_fld(x, 27, 1) == 1, 'ws idle latch not reported'
    r, x, f, st = beat(0, 16, 0, units=1, pixels=1)
    # nothing is pending, so no frame latches, but PIXELS=1 against a pixel count
    # of 0 is exactly the mismatch the spec calls a frame-length violation, and
    # that violation faults regardless of the stream being empty.  Only
    # PIXELS=0 disables the length check, as the RSTU=1 beat above shows.
    assert ((r >> 27) & 1, (r >> 30) & 1, f) == (0, 1, 1), \
        f'ws RSTU=1 latch {r:08x} {f}'
    checks += 3

    # A latch on a partial pixel is a truncated frame and faults; a latch on a
    # whole pixel that disagrees with PIXELS is a frame-length violation; an idle
    # latch with PIXELS set reports nothing pending and still counts as a length
    # mismatch.  These three outcomes share one output bit pattern space, so they
    # must not be confused with each other.
    r, x, f, st = send_bit(0, 1)                 # one bit of a pixel, no latch yet
    assert _si_fld(x, 16, 8) == 1, f'ws bit position {x:08x}'
    r, x, f, st = beat(st, 500, 0)
    assert ((r >> 31) & 1, (r >> 27) & 1, f) == (1, 1, 1), f'ws truncation {r:08x} {f}'
    r, _x, f, st = pixel(0, 0, 0, 0)
    r, x, f, st = beat(st, 400, 0, pixels=2)
    assert ((r >> 30) & 1, (r >> 31) & 1, f) == (1, 0, 1), f'ws length violation {r:08x}'
    r, x, f, st = pixel(0, 0, 0, 0, pixels=3)
    assert f == 0 and (_si_fld(r, 30, 1), _si_fld(r, 26, 1)) == (0, 1), \
        f'ws three pixels against PIXELS=3 {r:08x}'
    r, x, f, st = beat(0, 400, 0, pixels=5)
    assert f == 1 and _si_fld(x, 27, 1) == 1 and ((r >> 30) & 1) == 1 and \
        ((r >> 27) & 1) == 0, f'ws idle latch {r:08x} f={f}'
    checks += 2

    # Restart clears the shift register, the bit position, the pixel count, the
    # digest and every counter, and still takes the bit on the same beat.
    seeded = (0xABCDE1 << 0) | (17 << 24) | (5 << 30) | (0x7A << 38) \
        | (0x123456 << 46) | (1 << 70) | (9 << 71) | (9 << 79) | (9 << 87) \
        | (9 << 95) | (9 << 103) | (77 << 111)
    r, x, f, st = beat(seeded, 7, 3, restart=True)
    assert ((r >> 24) & 1, (r >> 25) & 1, _si_fld(x, 24, 1)) == (1, 1, 1), \
        f'ws restart bit {r:08x} {x:08x}'
    # Restart clears the bit position, the pixel count, the digest, the last
    # pixel and every counter, then takes this beat's bit, so the shift register
    # holds exactly that one accepted bit -- the spec's clear list does not
    # include the frame-valid flag, which is why it survives here.
    assert (_si_fld(st, 0, 24), _si_fld(st, 24, 6), _si_fld(st, 30, 8),
            _si_fld(st, 38, 8), _si_fld(st, 46, 24), _si_fld(st, 70, 1),
            _si_fld(st, 71, 8), _si_fld(st, 79, 8), _si_fld(st, 87, 8),
            _si_fld(st, 95, 8), _si_fld(st, 103, 8), _si_fld(st, 111, 8)) == \
        (1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1), f'ws restart {st:x}'
    checks += 1

    # Violation counters saturate instead of wrapping, and aux shows the nibble.
    r, x, f, st = beat((255 << 79) | (3 << 111), 1, 1)   # high 1 / low 1: both wrong
    assert f == 1 and _si_fld(st, 79, 8) == 255 and \
        _si_fld(st, 87, 8) == 1 and _si_fld(st, 111, 8) == 4, \
        f'ws counters {st:x}'
    assert _si_fld(x, 28, 4) == 15, f'ws duty nibble {_si_fld(x, 28, 4)}'
    checks += 1

    # DOCUMENTED HAZARD, pinned so a change has to be deliberate: the bit total is
    # the 16-bit sum of two 16-bit fields, so a high interval near 65535 ticks
    # (8.2 ms, far outside any legal WS2812 symbol) wraps the total back below the
    # latch threshold instead of latching.  The integer model and the generated
    # kernel agree (rtl truncates `wh + wl` into a 16-bit wire), so this is a range
    # limit of the interface, not a model/RTL divergence, and no legal symbol hits
    # it.
    r, x, f, st = beat(0, 0xFFFF, 1)
    assert ((r >> 27) & 1, (r >> 24) & 1) == (0, 1), f'ws total wrapped {r:08x}'
    assert ((r >> 28) & 1, f) == (1, 1), f'ws wrapped total not flagged as duty {r:08x}'
    checks += 1

    # Malformed beats: c[29:12] and b[31:8] must be zero, and the state is kept.
    keep = 0x0000_DEAD_BEEF
    for a_word, b_word, c_word in ((0, 1 << 8, 0), (0, 1 << 31, 0), (0, 0, 1 << 12),
                                   (0, 0, 1 << 29), (0, 256, 1 << 6)):
        r, x, f, st = step('ws2812_serial', a_word, b_word, c_word, keep)
        assert (r, x, f, st) == (0, 0, 1, keep), \
            f'ws malformed a={a_word:x} b={b_word:x} c={c_word:x}'
    checks += 1
    return checks


def _si_quad():
    """Quadrature front end checked against hand-derived encoder algebra.

    The Gray walk, the illegal diagonal transitions and the x1/x2/x4 counting
    rules are read straight off the published quadrature table, and the velocity
    estimate is derived from its own recurrence -- a truncated EWMA driven by a
    constant interval stops at interval-15, which is computed here, not replayed
    from a model run.
    """
    checks = 0
    X1, X2, X4 = 0, 1, 2
    JT = 4
    INTERVAL = 256
    WALK = (0b00, 0b10, 0b11, 0b01)          # published clockwise Gray sequence

    def ctrl(mode=X4, bounce=0, chatter=0, jt=JT, origin=0):
        return mode | (bounce << 8) | (chatter << 16) | (jt << 24) | (origin << 30)

    def restart(ref, mode=X4):
        r, x, f, st = step('quadrature_jitter', ref, INTERVAL,
                           ctrl(mode) | (1 << 31), 0)
        assert (r, f) == (0, 0), f'quad restart gave pos {r:x} f={f}'
        assert (x >> 26) & 1, 'quad restart did not mark aux[26]'
        assert (x >> 20) & 1 == 0, 'quad restart counted a transition'
        assert (x >> 16) & 3 == ref, 'quad restart reference is not the state word'
        return st

    # --- the published Gray walk: forward counts +1, reverse counts -1 --------
    st = restart(0b00)
    for k in range(4):
        nxt = WALK[(k + 1) % 4]
        r, x, f, st = step('quadrature_jitter', nxt, INTERVAL, ctrl(X4), st)
        assert _si_sgn(r, 32) == k + 1, f'quad forward walk at step {k}: {r:x}'
        assert (x >> 20) & 1 and not (x >> 21) & 1, f'quad forward flag at {k}'
        assert (x >> 18) & 3 == nxt and (x >> 16) & 3 == nxt, f'quad state at {k}'
        checks += 1
    for k in range(4):
        nxt = WALK[(3 - k) % 4]
        r, x, f, st = step('quadrature_jitter', nxt, INTERVAL, ctrl(X4), st)
        assert _si_sgn(r, 32) == 3 - k, f'quad reverse walk at step {k}: {r:x}'
        assert (x >> 21) & 1, f'quad reverse walk lost its sign flag at {k}'
        checks += 1

    # --- x1 counts only A rises, x2 counts every A change, x4 every legal edge -
    for mode, expected in ((X1, 1), (X2, 2), (X4, 4)):
        st = restart(0b00, mode)
        for k in range(4):
            nxt = WALK[(k + 1) % 4]
            r, x, f, st = step('quadrature_jitter', nxt, INTERVAL, ctrl(mode), st)
        assert _si_sgn(r, 32) == expected, \
            f'quad x{1 << 0 if mode == X1 else (2 if mode == X2 else 4)} ' \
            f'counted {_si_sgn(r, 32)}, expected {expected}'
        checks += 1

    # --- diagonal transitions are illegal, fault, and do not move the position -
    for frm, to in ((0b00, 0b11), (0b11, 0b00), (0b10, 0b01), (0b01, 0b10)):
        st = restart(frm)
        r, x, f, st = step('quadrature_jitter', to, INTERVAL, ctrl(X4), st)
        assert f, f'quad diagonal {frm:02b}->{to:02b} did not fault'
        assert _si_sgn(r, 32) == 0, f'quad diagonal moved the position to {r:x}'
        assert (x >> 22) & 1, f'quad diagonal lost aux[22]'
        assert (x >> 20) & 1 == 0, 'quad diagonal applied a count'
        assert (x >> 16) & 3 == to, 'quad diagonal did not follow the observed lines'
        checks += 1

    # --- bounce rejection leaves state, position and estimate untouched --------
    st = restart(0b00)
    r, x, f, st = step('quadrature_jitter', 0b10, 5, ctrl(X4, bounce=8), st)
    assert _si_sgn(r, 32) == 0, f'quad bounce moved the position to {r:x}'
    assert (x >> 23) & 1, 'quad bounce lost aux[23]'
    assert (x >> 20) & 1 == 0, 'quad bounce applied a count'
    assert (x >> 16) & 3 == 0b00, 'quad bounce advanced the reference state'
    assert x & 0xffff == 0, 'quad bounce updated the velocity estimate'
    checks += 1

    # --- the estimator seeds on the first edge and holds a steady interval -----
    # The published recurrence is vel := clamp16u(vel + ((interval - vel) >>> 4))
    # with a zero estimate replaced by the first measured interval, so a steady
    # interval is a fixed point from the first accepted edge and never flags
    # jitter.  The 0/1 walk rails the position back to zero each pair of beats,
    # which also pins that the velocity update is not gated by the count.
    st = restart(0b00)
    hold = ctrl(X4)
    for k in range(80):
        nxt = 0b10 if k % 2 == 0 else 0b00
        r, x, f, st = step('quadrature_jitter', nxt, INTERVAL, hold, st)
        assert x & 0xffff == INTERVAL, f'quad estimate at {k} is {x & 0xffff}'
        assert f == 0, f'quad flagged a steady interval at {k}'
    assert _si_sgn(r, 32) == 0, f'quad oscillating walk left {r:x}'
    checks += 1

    # --- one-sixteenth tracking, hand-derived, and the truncation dead band ----
    # From vel = 256 with the interval stepping to 512 the published rate gives
    # 256 + (256>>4) = 272, 272 + (240>>4) = 287, 287 + (225>>4) = 301 and
    # 301 + (211>>4) = 314, every one of them outside the (vel>>4)+1 window, and
    # the arithmetic shift then truncates a gap below 16, so the estimate stalls
    # at 512 - 15 = 497 and can never reach the new interval.
    st = restart(0b00)
    for k in range(4):
        nxt = 0b10 if k % 2 == 0 else 0b00
        r, x, f, st = step('quadrature_jitter', nxt, INTERVAL, ctrl(X4), st)
    for k, expected in enumerate((272, 287, 301, 314)):
        nxt = 0b10 if k % 2 == 0 else 0b00
        r, x, f, st = step('quadrature_jitter', nxt, 512, ctrl(X4), st)
        assert x & 0xffff == expected, \
            f'quad tracking beat {k} gave {x & 0xffff}, not {expected}'
        assert f == 1, f'quad missed the jitter window at beat {k}'
        checks += 1
    for k in range(80):
        nxt = 0b10 if k % 2 == 0 else 0b00
        r, x, f, st = step('quadrature_jitter', nxt, 512, ctrl(X4), st)
    assert x & 0xffff == 512 - 15, f'quad estimate stopped at {x & 0xffff}'
    assert f == 0, 'quad flagged jitter inside the converged window'
    checks += 1

    # --- malformed control words answer zero and keep the state ---------------
    keep = restart(0b01)
    for a_word, b_word, c_word in ((0x08, INTERVAL, ctrl(X4)),        # a[3] is not a state bit
                                   (0b10, 1 << 16, ctrl(X4)),         # b[31:16] dirty
                                   (0b10, INTERVAL, 3),               # mode 3 does not exist
                                   (0b10, INTERVAL, ctrl(X4) | (1 << 27))):
        r, x, f, st = step('quadrature_jitter', a_word, b_word, c_word, keep)
        assert (r, x, f, st) == (0, 0, 1, keep), \
            f'quad malformed a={a_word:x} b={b_word:x} c={c_word:x}'
        checks += 1
    return checks


_SI_CHECKS = (
    ('mahony_ahrs', _si_mahony),        # Q11 grid anchors + Pythagoras + rational AHRS trace
    ('kalman1d', _si_kalman1),          # exact rational Riccati steady-state gain
    ('kalman2d_cv', _si_kalman2),       # constant-velocity identity/predict algebra
    ('ca_correlator', _si_ca),          # cell-average threshold vs closed-form sum
    ('manchester_io', _si_man),         # self-clocking transition density invariant
    ('crc16_modbus', _si_crc16),        # published '123456789' = 0x4B37 check value
    ('dmx512_frame', _si_dmx),          # published 4 us bit + closed-form window + UART assembly
    ('onewire_slot', _si_onewire),       # published 1-Wire windows + CRC8/MAXIM 0xA1 anchor
    ('ws2812_serial', _si_ws2812),      # published T0H/T1H duty + latch windows
    ('quadrature_jitter', _si_quad),    # Gray walk identity + estimator fixed point
)


def _si_artifacts():
    """Family-wide properties that hold independently of any single core."""
    checks = 0
    # The fabric multiplier is unsigned and corrupts any operand with bit 11 set,
    # so no generated kernel may use `*` or `/`.  Scan the kernel text itself,
    # comments stripped, exactly as generate.py would emit it.
    for core_def in CORES:
        for block in (core_def['body'], core_def.get('decl', '')):
            text = strip_comments(block)
            assert '*' not in text and '/' not in text, \
                f"{core_def['name']} kernel text uses * or /"
    checks += len(CORES)

    # Every core documents and honours the restart convention, and every core has
    # vectors so integrate.py can bind it.
    names = [core_def['name'] for core_def in CORES]
    for name in names:
        spec = next(core_def['spec'] for core_def in CORES if core_def['name'] == name)
        assert 'c[31]=1' in spec, f'{name} spec does not document c[31]=1 restart'
        assert name in CORE_VECTORS, f'{name} has no vector generator'
    checks += 2 * len(names)

    # The model is a pure function of (a, b, c, state): replaying a beat with the
    # same inputs must be bit-exact, and the 256-bit state must be truncated, not
    # widened, by every core.
    for name in names:
        r1, x1, f1, s1 = step(name, 0x1234, 0x5678, 0x9ABC, 0xFEDCBA9876543210)
        r2, x2, f2, s2 = step(name, 0x1234, 0x5678, 0x9ABC, 0xFEDCBA9876543210)
        assert (r1, x1, f1, s1) == (r2, x2, f2, s2), f'{name} step is not deterministic'
        assert s1 >> 256 == 0, f'{name} state grew past 256 bits'
    checks += len(names)
    return checks


def selftest():
    """Return the number of independent checks; raise AssertionError on failure."""
    assert len(CORES) == 10, 'sensing family must carry ten cores'
    assert {c['name'] for c in CORES} == {name for name, _ in _SI_CHECKS}, \
        'selftest core coverage list mismatch'
    checks = _si_artifacts()
    for name, block in _SI_CHECKS:
        assert callable(block), f'{name} selftest block is not implemented'
        count = block()
        assert isinstance(count, int) and count >= 3, \
            f'{name} selftest returned {count!r}, needs at least 3 checks'
        checks += count
    assert checks > 0, 'sensing selftest performed no checks'
    return checks
