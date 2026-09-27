"""Hard-multiplier arithmetic kernels built on the GW5A MULT12X12 slice.

yosys will not infer MULT12X12 from a Verilog `*`, and with `synth_gowin -noalu`
an inferred 12x12 product costs hundreds of LUTs and a combinatorial depth that
50 MHz cannot close.  Every core here instantiates the hard block directly and
the Python model computes the same product with exact integers, which is the
independent definition of what the slice must return.

Simulation needs `sim/mult12x12_model.v` on the file list because OSS CAD Suite
ships the cell with an empty body; synthesis never reads that file, so the
bitstream always contains the real hardware multiplier.

Template body vocabulary (all re-initialised on every evaluation):
    r x f temp mask pa pb pc ph pl ext wide wide2 swide swide2 sa sb sc data
    i j idx lane sh state_r state_n
Anything else comes from `decl`, which is inserted at module scope and may hold
instances -- that is how the slices are attached.
"""
from itertools import product
from random import Random

FAMILY = 'dsp'
MASK = (1 << 32) - 1
MODEL = 'sim/mult12x12_model.v'

CORES = []


def core(name, spec, body, advantage, lanes, decl='', stateful=False):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body, decl=decl,
                      advantage=advantage, lanes=lanes, stateful=stateful,
                      sim_extra=[MODEL]))


def custom(name, spec, module, advantage, lanes, latency, mutation):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, module=module,
                      advantage=advantage, lanes=lanes, latency=latency,
                      mutation=mutation, sim_extra=[MODEL]))


def slice_decl(out, xa, xb):
    """One combinational MULT12X12: `out` is the signed 24-bit product."""
    return (f'wire [23:0] {out}_raw;\n'
            f'wire signed [23:0] {out} = $signed({out}_raw);\n'
            f'MULT12X12 u_{out} (.DOUT({out}_raw), .A({xa}), .B({xb}), '
            f".CLK(2'b00), .CE(2'b00), .RESET(2'b00));\n")


def operands(*names):
    return 'reg [11:0] ' + ', '.join(names) + ';\n'


# ---------------------------------------------------------------- product/acc
core('dsp_mac_s12',
    "Signed 12x12 multiply-accumulate. Only a[11:0] and b[11:0] are read, both "
    "two's complement; a nonzero a[31:12] or b[31:12] is a malformed beat "
    "(result=aux=0, fault=1, state kept). The product is added to a 48-bit "
    "signed accumulator in state[47:0]; c[31] clears that accumulator before "
    "this beat. result=the accumulator clamped to signed 32-bit, and fault=1 "
    "whenever that clamp bites. aux[15:0]=accumulator[15:0] and "
    "aux[31:16]=accumulator[47:32] keep the untruncated magnitude visible.",
    "mac_a=a[11:0]; mac_b=b[11:0];\n"
    "if(a[31:12]!=0 || b[31:12]!=0) f=1'b1;\n"
    "else begin\n"
    "    acc_old = c[31] ? 48'sd0 : $signed(state_r[47:0]);\n"
    "    acc_new = acc_old + mac;\n"
    "    if(acc_new > 48'sd2147483647) begin r=32'h7fffffff; f=1'b1; end\n"
    "    else if(acc_new < -48'sd2147483648) begin r=32'h80000000; f=1'b1; end\n"
    "    else r = acc_new[31:0];\n"
    "    x = {acc_new[47:32], acc_new[15:0]};\n"
    "    state_n = {208'd0, acc_new};\n"
    "end",
    "One multiply and one accumulate retire per enabled beat with no load/store "
    "round trip, which is exactly the filter inner loop a CPU must re-fetch "
    "every tap.", 1,
    operands('mac_a', 'mac_b') +
    "reg signed [47:0] acc_old, acc_new;\n" + slice_decl('mac', 'mac_a', 'mac_b'), stateful=True)

core('dsp_q12x2_round_sat',
    "Two independent Q12 signed multiplies per beat: lane k multiplies "
    "a[12k+:12] by b[12k+:12] (k=0,1; bits 31:24 are don't care), rounds the "
    "Q24 product half-up and shifts it right by c[4k+:4], then crops to signed "
    "16-bit. result=the two 16-bit lanes, lane 0 low. aux[7:0]=c[7:0] echoed, "
    "aux[8+k]=lane k was cropped, aux[31:9]=0. fault=1 on a cropped lane or on "
    "nonzero c[31:8] (malformed control, result=aux=0).",
    "qa_a=a[11:0]; qa_b=b[11:0]; qb_a=a[23:12]; qb_b=b[23:12];\n"
    "if(c[31:8]!=0) f=1'b1;\n"
    "else begin\n"
    "    for(lane=0;lane<2;lane=lane+1) begin\n"
    "        sh=lane==0 ? c[3:0] : c[7:4];\n"
    "        qv=lane==0 ? qa : qb;\n"
    "        if(sh==0) swide=qv;\n"
    "        else swide=(qv+(24'sd1<<<(sh-1)))>>>sh;\n"
    "        if(swide>64'sd32767) begin r[lane*16+:16]=16'h7fff; x[8+lane]=1'b1; f=1'b1; end\n"
    "        else if(swide<-64'sd32768) begin r[lane*16+:16]=16'h8000; x[8+lane]=1'b1; f=1'b1; end\n"
    "        else r[lane*16+:16]=swide[15:0];\n"
    "    end\n"
    "    x[7:0]=c[7:0];\n"
    "end",
    "A stereo gain stage with per-channel requantisation and saturation "
    "reporting: two slices do in one beat what costs a CPU two multiply-high "
    "sequences plus two fix-up branches.", 2,
    operands('qa_a', 'qa_b', 'qb_a', 'qb_b') +
    "reg signed [23:0] qv;\n" + slice_decl('qa', 'qa_a', 'qa_b')
    + slice_decl('qb', 'qb_a', 'qb_b'))

core('dsp_complex_mul_s12',
    "One complex multiply per beat on Q12 components: A=(a[11:0] real, a[23:12] "
    "imaginary), B=(b[11:0], b[23:12]); bits 31:24 are don't care. "
    "real=A.re*B.re-A.im*B.im and imag=A.re*B.im+A.im*B.re, each rounded "
    "half-up, shifted right by c[3:0] (real) and c[7:4] (imag), then cropped to "
    "signed 16-bit. result[15:0]=real, result[31:16]=imag. aux[7:0]=c[7:0] "
    "echoed, aux[8]=real cropped, aux[9]=imag cropped, aux[31:10]=0. fault=1 on "
    "any crop or on nonzero c[31:8] (result=aux=0).",
    "rr_a=a[11:0]; rr_b=b[11:0]; ii_a=a[23:12]; ii_b=b[23:12];\n"
    "ri_a=a[11:0]; ri_b=b[23:12]; ir_a=a[23:12]; ir_b=b[11:0];\n"
    "if(c[31:8]!=0) f=1'b1;\n"
    "else begin\n"
    "    re_full = rr - ii;\n"
    "    im_full = ri + ir;\n"
    "    for(lane=0;lane<2;lane=lane+1) begin\n"
    "        sh=lane==0 ? c[3:0] : c[7:4];\n"
    "        cv=lane==0 ? re_full : im_full;\n"
    "        if(sh==0) swide=cv;\n"
    "        else swide=(cv+(26'sd1<<<(sh-1)))>>>sh;\n"
    "        if(swide>64'sd32767) begin r[lane*16+:16]=16'h7fff; x[8+lane]=1'b1; f=1'b1; end\n"
    "        else if(swide<-64'sd32768) begin r[lane*16+:16]=16'h8000; x[8+lane]=1'b1; f=1'b1; end\n"
    "        else r[lane*16+:16]=swide[15:0];\n"
    "    end\n"
    "    x[7:0]=c[7:0];\n"
    "end",
    "Four slices retire a full complex multiply in one beat: this is the QAM "
    "equaliser and OFDM subcarrier step that needs four multiplies and two "
    "reduction branches on a CPU.", 2,
    operands('rr_a', 'rr_b', 'ii_a', 'ii_b', 'ri_a', 'ri_b', 'ir_a', 'ir_b') +
    "reg signed [25:0] re_full, im_full, cv;\n"
    + slice_decl('rr', 'rr_a', 'rr_b') + slice_decl('ii', 'ii_a', 'ii_b')
    + slice_decl('ri', 'ri_a', 'ri_b') + slice_decl('ir', 'ir_a', 'ir_b'))

core('dsp_dot2_mac_s12',
    "Two-tap dot product folded into a long accumulator: x0=a[11:0], "
    "x1=a[23:12], g0=b[11:0], g1=b[23:12] (all signed Q12). A nonzero a[31:24] "
    "or b[31:24] is a malformed beat (result=aux=0, fault=1, state kept). "
    "dot=x0*g0+x1*g1 is added to a 48-bit signed accumulator in "
    "state[47:0]; c[31] clears the accumulator before this beat. result=the "
    "accumulator clamped to signed 32-bit, fault=1 when that clamp bites. "
    "aux[15:0]=accumulator[15:0], aux[31:16]=accumulator[47:32].",
    "d0_a=a[11:0]; d0_b=b[11:0]; d1_a=a[23:12]; d1_b=b[23:12];\n"
    "if(a[31:24]!=0 || b[31:24]!=0) f=1'b1;\n"
    "else begin\n"
    "    acc_old = c[31] ? 48'sd0 : $signed(state_r[47:0]);\n"
    "    dot = d0 + d1;\n"
    "    acc_new = acc_old + dot;\n"
    "    if(acc_new > 48'sd2147483647) begin r=32'h7fffffff; f=1'b1; end\n"
    "    else if(acc_new < -48'sd2147483648) begin r=32'h80000000; f=1'b1; end\n"
    "    else r = acc_new[31:0];\n"
    "    x = {acc_new[47:32], acc_new[15:0]};\n"
    "    state_n = {208'd0, acc_new};\n"
    "end",
    "Two multipliers and one accumulate inside a single enabled beat: a 2-tap "
    "section of a larger filter runs at II=1 with no coefficient fetch.", 2,
    operands('d0_a', 'd0_b', 'd1_a', 'd1_b') +
    "reg signed [25:0] dot;\nreg signed [47:0] acc_old, acc_new;\n"
    + slice_decl('d0', 'd0_a', 'd0_b') + slice_decl('d1', 'd1_a', 'd1_b'),
    stateful=True)

core('dsp_iir_lpf_s12',
    "One-pole IIR low pass on signed 11-bit samples: x=a[10:0], gain g=b[10:0] "
    "as an unsigned Q10 coefficient (unity at 1024, up to 1.999); all other bits "
    "of a and b are don't care. state[10:0] holds the previous output y and "
    "c[31] seeds it from x instead (filter restart). e=x-y, "
    "delta=round_half_up(e*g>>>10), y_new=clamp_s11(y+delta). result[10:0]="
    "y_new, result[31:11]=0. aux[11:0]=e, aux[12]=clamped high, aux[13]=clamped "
    "low, aux[26:14]=delta, aux[31:26]=0. fault=1 only when the 11-bit output "
    "saturated, which needs a gain above about 1.5.",
    "xs={a[10], a[10:0]};\n"
    "yold = c[31] ? xs : {state_r[10], state_r[10:0]};\n"
    "ie = xs - yold;\n"
    "ig = {1'b0, b[10:0]};\n"
    "lp_a=ie; lp_b=ig;\n"
    "ds = (lp + 24'sd512) >>> 10;\n"
    "yn = yold + ds;\n"
    "if(yn > 13'sd1023) begin r={21'd0, 11'h3ff}; x[12]=1'b1; f=1'b1; state_n={245'd0, 11'h3ff}; end\n"
    "else if(yn < -13'sd1024) begin r={21'd0, 11'h400}; x[13]=1'b1; f=1'b1; state_n={245'd0, 11'h400}; end\n"
    "else begin r={21'd0, yn[10:0]}; state_n={245'd0, yn[10:0]}; end\n"
    "x[11:0]=ie;\n"
    "x[26:14]=ds;",
    "A recursive filter needs its feedback loop closed inside one enabled beat; "
    "the slice does multiply-then-accumulate every cycle, which a soft-"
    "processor loop cannot sustain at a fixed control rate.", 1,
    operands('lp_a', 'lp_b') +
    "reg signed [11:0] xs, yold, ie, ig;\nreg signed [12:0] ds;\n"
    "reg signed [13:0] yn;\n" + slice_decl('lp', 'lp_a', 'lp_b'), stateful=True)

core('dsp_fir3_s12',
    "Three-tap FIR with runtime coefficients. State layout: [11:0]=w0, "
    "[23:12]=w1, [35:24]=w2, [47:36]=h0 (previous input), [59:48]=h1 (the one "
    "before). A config beat (c[31]=1) loads w0=a[11:0], w1=a[23:12], w2=b[11:0], "
    "keeps the history, and echoes it: result[11:0]=w2, aux[11:0]=w0, "
    "aux[23:12]=w1, all other bits zero. A data beat (c[31]=0) takes x=a[11:0] "
    "and computes y=round_half_up((x*w0+h0*w1+h1*w2)>>>c[7:4]) cropped to "
    "signed 16-bit: result[15:0]=y, result[31:16]=0, aux[11:0]=x, aux[23:12]=h0, "
    "aux[24]=cropped, aux[31:25]=0; then h1<=h0 and h0<=x. Any nonzero c[30:8] "
    "is a malformed beat (result=aux=0, fault=1, state kept); fault is also set "
    "when y is cropped.",
    "t0_a=a[11:0]; t0_b=state_r[11:0];\n"
    "t1_a=state_r[47:36]; t1_b=state_r[23:12];\n"
    "t2_a=state_r[59:48]; t2_b=state_r[35:24];\n"
    "if(c[30:8]!=0) f=1'b1;\n"
    "else if(c[31]) begin\n"
    "    state_n = {196'd0, state_r[59:36], b[11:0], a[23:12], a[11:0]};\n"
    "    r = {20'd0, b[11:0]};\n"
    "    x = {8'd0, a[23:12], a[11:0]};\n"
    "end else begin\n"
    "    sum = t0 + t1 + t2;\n"
    "    sh=c[7:4];\n"
    "    if(sh==0) swide=sum;\n"
    "    else swide=(sum+(26'sd1<<<(sh-1)))>>>sh;\n"
    "    if(swide>64'sd32767) begin r={16'd0, 16'h7fff}; x[24]=1'b1; f=1'b1; end\n"
    "    else if(swide<-64'sd32768) begin r={16'd0, 16'h8000}; x[24]=1'b1; f=1'b1; end\n"
    "    else r={16'd0, swide[15:0]};\n"
    "    x[11:0]=a[11:0];\n"
    "    x[23:12]=state_r[47:36];\n"
    "    state_n = {196'd0, state_r[47:36], a[11:0], state_r[35:0]};\n"
    "end",
    "Coefficient reload plus a 3-tap kernel in one beat: the fabric holds the "
    "history in registers and applies three products in parallel, so retuning a "
    "filter is one write instead of a rebuilt inner loop.", 1,
    operands('t0_a', 't0_b', 't1_a', 't1_b', 't2_a', 't2_b') +
    "reg signed [25:0] sum;\n" + slice_decl('t0', 't0_a', 't0_b')
    + slice_decl('t1', 't1_a', 't1_b') + slice_decl('t2', 't2_a', 't2_b'),
    stateful=True)

# ------------------------------------------------------------ registered tree
DOT4 = """module acc_dsp_dot4_s12_pipe (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
// Fixed 512/1536/1536/512 Q12 decimator on four MULT12X12 slices.  Samples,
// products and the adder tree are each registered, so only the requantise shift
// and crop share a pipeline stage: one operator per level at 50 MHz.
localparam signed [11:0] C0 = 12'sd512, C1 = 12'sd1536;
localparam signed [11:0] C2 = 12'sd1536, C3 = 12'sd512;
reg signed [11:0] x0q, x1q, x2q, x3q;
reg signed [23:0] p0q, p1q, p2q, p3q;
reg signed [26:0] sumq;
reg [3:0] s1q, s2q, s3q;
reg v1, v2, v3;
wire [23:0] q0_raw, q1_raw, q2_raw, q3_raw;
wire signed [23:0] q0 = $signed(q0_raw);
wire signed [23:0] q1 = $signed(q1_raw);
wire signed [23:0] q2 = $signed(q2_raw);
wire signed [23:0] q3 = $signed(q3_raw);
MULT12X12 u_q0 (.DOUT(q0_raw), .A(x0q), .B(C0), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
MULT12X12 u_q1 (.DOUT(q1_raw), .A(x1q), .B(C1), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
MULT12X12 u_q2 (.DOUT(q2_raw), .A(x2q), .B(C2), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
MULT12X12 u_q3 (.DOUT(q3_raw), .A(x3q), .B(C3), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire signed [26:0] e0 = {{3{p0q[23]}}, p0q};
wire signed [26:0] e1 = {{3{p1q[23]}}, p1q};
wire signed [26:0] e2 = {{3{p2q[23]}}, p2q};
wire signed [26:0] e3 = {{3{p3q[23]}}, p3q};
wire signed [26:0] sum_next = e0 + e1 + e2 + e3;
reg signed [63:0] shifted;
reg [15:0] res_r;
reg [31:0] res_aux;
reg res_f;
always @* begin
    if(s3q==0) shifted = sumq;
    else shifted = (sumq + (27'sd1<<<(s3q-4'd1))) >>> s3q;
    if(shifted > 64'sd32767) begin res_r=16'h7fff; res_f=1'b1; end
    else if(shifted < -64'sd32768) begin res_r=16'h8000; res_f=1'b1; end
    else begin res_r=shifted[15:0]; res_f=1'b0; end
    res_aux = {s3q, res_f, sumq[26:0]};
end
assign in_ready = clk_en && (!out_valid || out_ready);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x0q<=12'sd0; x1q<=12'sd0; x2q<=12'sd0; x3q<=12'sd0;
        p0q<=24'sd0; p1q<=24'sd0; p2q<=24'sd0; p3q<=24'sd0;
        sumq<=27'sd0; s1q<=0; s2q<=0; s3q<=0;
        v1<=0; v2<=0; v3<=0;
        out_valid<=0; result<=0; aux<=0; fault<=0;
    end else if(in_ready) begin
        x0q<=a[11:0]; x1q<=a[23:12]; x2q<=b[11:0]; x3q<=b[23:12];
        s1q<=c[3:0];
        p0q<=q0; p1q<=q1; p2q<=q2; p3q<=q3;
        s2q<=s1q;
        sumq<=sum_next;
        s3q<=s2q;
        v3<=v2;
        v2<=v1;
        v1<=in_valid;
        result<={16'd0, res_r};
        aux<=res_aux;
        fault<=res_f;
        out_valid<=v3;
    end
end
endmodule
"""


custom('dsp_dot4_s12_pipe',
    "Four-tap fixed-kernel decimator on Q12 signed samples: x0=a[11:0], "
    "x1=a[23:12], x2=b[11:0], x3=b[23:12] (bits 31:24 don't care) against the "
    "binomial taps 512/1536/1536/512 (Q12, unity gain at shift 12), so "
    "sum=x0*512+x1*1536+x2*1536+x3*512. sum is "
    "rounded half-up, shifted right by c[3:0] and cropped to signed 16-bit into "
    "result[15:0] (result[31:16]=0). aux[26:0]=sum, aux[27]=1 when the crop "
    "fired, aux[31:28]=the shift actually applied. fault=1 when the crop fired. "
    "Response latency is 4 enabled beats and the pipeline accepts one beat per "
    "enabled cycle while the tail is ready.",
    DOT4,
    "Four hard slices plus a registered adder tree retire a 4-tap kernel every "
    "enabled beat; a soft processor would need four multiply instructions and "
    "three adds in one instruction slot.", 4, 4,
    ("result<={16'd0, res_r};", "result<={16'd0, res_r^16'd1};"))


# --------------------------------------------------------------------- models
ACC48 = (1 << 48) - 1
TAPS = (512, 1536, 1536, 512)


def s_bits(value, width):
    value &= (1 << width) - 1
    return value - (1 << width) if value >> (width - 1) else value


def s12(value):
    return s_bits(value, 12)


def s11(value):
    return s_bits(value, 11)


def round_shift(value, shift):
    return value if shift == 0 else (value + (1 << (shift - 1))) >> shift


def crop16(value):
    clamped = max(-32768, min(32767, value))
    return clamped, clamped != value


def accumulate(acc):
    """Shared 32-bit view plus 48-bit telemetry of one long accumulator."""
    aux = (((acc >> 32) & 0xffff) << 16) | (acc & 0xffff)
    if acc > (1 << 31) - 1:
        return 0x7fffffff, aux, 1
    if acc < -(1 << 31):
        return 0x80000000, aux, 1
    return acc & MASK, aux, 0


def step(name, a, b, c, state=0):
    if name == 'dsp_mac_s12':
        if a >> 12 or b >> 12:
            return 0, 0, 1, state
        acc = (0 if (c >> 31) & 1 else s_bits(state, 48)) + s12(a) * s12(b)
        r, x, f = accumulate(acc)
        return r, x, f, acc & ACC48
    if name == 'dsp_dot2_mac_s12':
        if a >> 24 or b >> 24:
            return 0, 0, 1, state
        acc = (0 if (c >> 31) & 1 else s_bits(state, 48)) + (
            s12(a) * s12(b) + s12(a >> 12) * s12(b >> 12))
        r, x, f = accumulate(acc)
        return r, x, f, acc & ACC48
    if name == 'dsp_q12x2_round_sat':
        if c >> 8:
            return 0, 0, 1, state
        r = x = f = 0
        for k in range(2):
            value = round_shift(s12(a >> 12*k) * s12(b >> 12*k), (c >> 4*k) & 15)
            clamped, hit = crop16(value)
            r |= (clamped & 0xffff) << 16*k
            if hit:
                x |= 1 << (8+k)
                f = 1
        return r, x | (c & 0xff), f, state
    if name == 'dsp_complex_mul_s12':
        if c >> 8:
            return 0, 0, 1, state
        real_a, imag_a = s12(a), s12(a >> 12)
        real_b, imag_b = s12(b), s12(b >> 12)
        r = x = f = 0
        for k, value in enumerate((real_a*real_b - imag_a*imag_b,
                                   real_a*imag_b + imag_a*real_b)):
            clamped, hit = crop16(round_shift(value, (c >> 4*k) & 15))
            r |= (clamped & 0xffff) << 16*k
            if hit:
                x |= 1 << (8+k)
                f = 1
        return r, x | (c & 0xff), f, state
    if name == 'dsp_iir_lpf_s12':
        sample = s11(a)
        previous = sample if (c >> 31) & 1 else s11(state)
        error = sample - previous
        delta = round_shift(error * (b & 0x7ff), 10)
        updated = previous + delta
        clamped = max(-1024, min(1023, updated))
        hit = clamped != updated
        aux = (error & 0xfff) | (int(clamped < updated) << 12) \
            | (int(clamped > updated) << 13) | ((delta & 0x1fff) << 14)
        return clamped & 0x7ff, aux, int(hit), clamped & 0x7ff
    if name == 'dsp_fir3_s12':
        if c & 0x7FFFFF00:
            return 0, 0, 1, state
        weight0, weight1, weight2 = (s_bits(state, 12), s_bits(state >> 12, 12),
                                     s_bits(state >> 24, 12))
        history0, history1 = s_bits(state >> 36, 12), s_bits(state >> 48, 12)
        sample = s12(a)
        if (c >> 31) & 1:
            new_state = ((history1 & 0xfff) << 48) | ((history0 & 0xfff) << 36) \
                | ((b & 0xfff) << 24) | (((a >> 12) & 0xfff) << 12) | (a & 0xfff)
            return (b & 0xfff), (((a >> 12) & 0xfff) << 12) | (a & 0xfff), 0, new_state
        clamped, hit = crop16(round_shift(sample*weight0 + history0*weight1
                                          + history1*weight2, (c >> 4) & 15))
        new_state = ((history0 & 0xfff) << 48) | ((sample & 0xfff) << 36) \
            | (state & ((1 << 36) - 1))
        aux = (sample & 0xfff) | ((history0 & 0xfff) << 12) | (int(hit) << 24)
        return clamped & 0xffff, aux, int(hit), new_state
    if name == 'dsp_dot4_s12_pipe':
        total = sum(s12(a >> 12*k) * tap for k, tap in enumerate(TAPS[:2])) \
            + sum(s12(b >> 12*k) * tap for k, tap in enumerate(TAPS[2:]))
        shift = c & 15
        clamped, hit = crop16(round_shift(total, shift))
        aux = (shift << 28) | (int(hit) << 27) | (total & 0x7ffffff)
        return clamped & 0xffff, aux, int(hit), state
    raise ValueError(name)


# ------------------------------------------------------------------- vectors
EDGE12 = (-2048, -2047, -1024, -1, 0, 1, 1023, 2047)
EDGE11 = (-1024, -1023, -512, -1, 0, 1, 511, 1023)


def w12(value):
    return value & 0xfff


def w11(value):
    return value & 0x7ff


def pair(lo, hi):
    return w12(lo) | (w12(hi) << 12)


def pad(name, rng):
    """One in-range random beat: padding rows must stay discriminating, and a
    raw 32-bit word is almost always malformed, which collapses the responses."""
    value = lambda: rng.randrange(-2048, 2048)
    if name == 'dsp_iir_lpf_s12':
        return (w11(value()), rng.randrange(0, 2048),
                (1 << 31) if rng.randrange(8) == 0 else 0)
    if name == 'dsp_fir3_s12':
        if rng.randrange(6) == 0:
            return (pair(value(), value()), w12(value()), 1 << 31)
        return (pair(value(), 0), 0, rng.randrange(9, 16) << 4)
    a, b = pair(value(), value()), pair(value(), value())
    if name == 'dsp_mac_s12':
        return (w12(value()), w12(value()), (1 << 31) if rng.randrange(8) == 0 else 0)
    if name == 'dsp_dot2_mac_s12':
        return (a, b, (1 << 31) if rng.randrange(8) == 0 else 0)
    if name in ('dsp_q12x2_round_sat', 'dsp_complex_mul_s12'):
        return (a, b, rng.randrange(11, 16) | (rng.randrange(11, 16) << 4))
    return (a, b, rng.randrange(0, 16))


def vectors(name, count=320):
    """Board set first: rows 0..127 are the hardware set, so they are structured.

    Each sweep is deliberately short (about 90 rows) and mostly non-saturating:
    a long crop run collapses onto one saturated response and stops
    discriminating, so the edges are shown once and the padding rows carry the
    variety. Padding uses in-range operands for the same reason.
    """
    rows = []
    if name == 'dsp_mac_s12':
        rows.append((0, 0, 1 << 31))
        for index, (x, y) in enumerate(product(EDGE12, EDGE12)):
            rows.append((w12(x), w12(y), (1 << 31) if index % 32 == 0 else 0))
        for k in range(24):
            rows.append((w12(2047 - k), w12(2047), 0))
        for k in range(8):
            rows.append((w12(-2048 + k), w12(2047), 1 << 31))
        rows += [(0x1000 + k, 0x2000 + k, 0) for k in range(4)]
    elif name == 'dsp_dot2_mac_s12':
        rows.append((0, 0, 1 << 31))
        for index, (lo, hi) in enumerate(product(EDGE12, EDGE12)):
            rows.append((pair(lo, hi), pair(hi, lo),
                         (1 << 31) if index % 16 == 0 else 0))
        for k in range(16):
            rows.append((pair(2047, 2046 - k), pair(2047, 2047), 0))
        for k in range(4):
            rows.append((0x01000000 + k, 0x02000000 + k, 0))
        rows.append((pair(-2048, 2047), pair(2047, -2048), 1 << 31))
    elif name == 'dsp_q12x2_round_sat':
        mid = (-1023, -900, -700, -512, -300, -256, 256, 300, 512, 700, 900, 1023)
        combos = list(product(mid, mid))
        for index in range(84):
            a_pair = combos[index % len(combos)]
            b_pair = combos[(index * 37) % len(combos)]
            shift = (5, 6, 7)[index % 3]
            rows.append((pair(*a_pair), pair(*b_pair), shift | (shift << 4)))
        for a_value, b_value in product(EDGE12[:3], EDGE12[-3:]):
            rows.append((pair(a_value, -a_value), pair(b_value, -b_value), 0))
        rows += [(0, 0, 0x100), (0, 0, 0x10000), (pair(1, 2), pair(3, 4), 1 << 31)]
    elif name == 'dsp_complex_mul_s12':
        corners = ((0, 0), (1024, 1024), (2047, -2048), (-1, 1023),
                   (1024, -1024), (-1024, 0), (0, 2047), (-2047, -1))
        mild = ((600, -300), (-512, 700), (900, 256), (-1023, -900),
                (300, 1023), (-700, -256), (512, 900), (-900, 600),
                (1023, 300), (-256, -1023), (700, 700), (-512, 1023))
        for k in range(72):
            a_pair = mild[k % 12]
            b_pair = mild[(k // 12) % 12]
            shift = (8, 10, 12)[k % 3]
            rows.append((pair(*a_pair), pair(*b_pair), shift | (shift << 4)))
        for index, (a_pair, b_pair) in enumerate(product(corners, corners[:4])):
            shift = (0, 12)[index % 2]
            rows.append((pair(*a_pair), pair(*b_pair), shift | (shift << 4)))
        rows += [(0, 0, 0x100), (0, 0, 0x100000)]
    elif name == 'dsp_iir_lpf_s12':
        rows.append((w11(500), 0, 1 << 31))
        for sample in range(-1000, 1024, 32):
            rows.append((w11(sample), 1024, 0))
        for gain in (2047, 1500, 1024, 512, 0, 2047):
            rows.append((w11(1023), gain, 0))
            rows.append((w11(-1024), gain, 0))
        rows += [(w11(0), 2047, 1 << 31), (w11(-1024), 2047, 0),
                 (w11(1023), 2047, 0), (w11(-1024), 2047, 0)]
        for sample in EDGE11:
            for gain in (0, 512, 1024, 2047):
                rows.append((w11(sample), gain, 0))
    elif name == 'dsp_fir3_s12':
        weights = ((1365, 1365, 1366), (2047, -2048, 1024), (0, 1024, 0),
                   (512, 512, 512), (-1, -1, -1), (1024, 2048, 0))
        for index, (w0, w1, w2) in enumerate(weights):
            rows.append((pair(w0, w1), w12(w2), 1 << 31))
            for k, shift in enumerate((9, 11, 13)):
                for j in range(6):
                    step_value = (-2048, -1000, 0, 1, 1000, 2047)[(j + 2 * k + index) % 6]
                    rows.append((pair(step_value, 0), 0, shift << 4))
            if index < 2:
                for shift in (0, 2, 4, 6):
                    rows.append((pair(2047, 0), 0, shift << 4))
                    rows.append((pair(-2048, 0), 0, shift << 4))
        rows += [(0, 0, 0x100), (0, 0, 0x40000), (0, 0, (1 << 31) | 0x800)]
    elif name == 'dsp_dot4_s12_pipe':
        corners = ((0, 0), (1024, 1024), (2047, -2048), (-1, 1023),
                   (1024, -1024), (-1024, 0), (0, 2047), (-2047, -1))
        for a_pair, b_pair, shift in product(corners, corners, (0, 8, 12)):
            rows.append((pair(*a_pair), pair(*b_pair), shift))
    else:
        raise ValueError(name)
    rng = Random(0xD5A00000 + sum(name.encode()))
    while len(rows) < count:
        rows.append(pad(name, rng))
    return rows[:count]


# ------------------------------------------------------------------ selftest
def selftest():
    """Reference checks derived from published values and hand-run traces."""
    checks = 0
    # The slice is SIGNED: (-2048)*(-2048)=+4194304, not a two's-complement wrap.
    r, x, f, state = step('dsp_mac_s12', w12(-2048), w12(-2048), 1 << 31)
    assert (r, f, state) == (4194304, 0, 4194304)
    checks += 1
    # 12x12 products accumulate without rounding: 3*2047*2047 exactly.
    acc = 0
    for _ in range(3):
        r, x, f, acc = step('dsp_mac_s12', 2047, 2047, 0, acc)
    assert r == 3 * 2047 * 2047 and f == 0 and x == r & 0xffff
    checks += 1
    # A long same-sign run must saturate the 32-bit view but keep the true sum.
    acc = 0
    for _ in range(2000):
        r, x, f, acc = step('dsp_mac_s12', 2047, 2047, 0, acc)
    assert r == 0x7fffffff and f == 1 and acc == 2000 * 2047 * 2047
    assert x == ((acc >> 32) & 0xffff) << 16 | (acc & 0xffff)
    checks += 2
    # Malformed width is rejected without disturbing the accumulator.
    held = acc
    r, x, f, state = step('dsp_mac_s12', 0x1234, 0x1, 0, held)
    assert (r, x, f, state) == (0, 0, 1, held)
    checks += 1
    # Q12 lanes hold +/-0.5, so 0.25*0.25 = 0.0625 -> 256 counts at shift 12.
    r, x, f, _ = step('dsp_q12x2_round_sat', pair(1024, 1024), pair(1024, 1024),
                      12 | (12 << 4))
    assert (r, f, x) == (256 * 0x10001, 0, 0xCC)
    checks += 1
    # Shift 0 keeps the raw Q24 product, so both lanes must crop and flag.
    r, x, f, _ = step('dsp_q12x2_round_sat', pair(2047, -2048), pair(2047, -2048), 0)
    assert r == 0x7fff7fff and x & 0x300 == 0x300 and f == 1
    checks += 1
    # Malformed control leaves result and aux at zero.
    assert step('dsp_q12x2_round_sat', 1, 1, 0x100)[:3] == (0, 0, 1)
    checks += 1
    # (0.25+0.25j) * (0.25+0j) -> re=im=1024*1024/4096 = 256 exactly.
    r, x, f, _ = step('dsp_complex_mul_s12', pair(1024, 1024), pair(1024, 0), 12 | (12 << 4))
    assert (r, f) == (0x01000100, 0)
    checks += 1
    # 0.25j * 0.25 rotates into the imaginary half only.
    r, x, f, _ = step('dsp_complex_mul_s12', pair(0, 1024), pair(1024, 0), 12 | (12 << 4))
    assert (r, f) == (0x01000000, 0)
    checks += 1
    # A times conj(A) is purely real: 2*1024^2/4096 = 512 in the real half.
    r, x, f, _ = step('dsp_complex_mul_s12', pair(1024, 1024), pair(1024, -1024),
                      12 | (12 << 4))
    assert (r & 0xffff) == 512 and (r >> 16) == 0 and f == 0
    checks += 1
    # Complex magnitude never exceeds 2*2^22, so shift 12 always fits 16 bits.
    for corner in ((2047, 2047), (-2048, 2047), (-2048, -2048)):
        r, x, f, _ = step('dsp_complex_mul_s12', pair(*corner), pair(*corner), 12 | (12 << 4))
        assert f == 0 and abs(r & 0xffff) <= 32767
        checks += 1
    # The binomial kernel has unity DC gain at shift 12: 1 -> 1 (4096/4096).
    r, x, f, _ = step('dsp_dot4_s12_pipe', pair(1, 1), pair(1, 1), 12)
    assert (r, f, x >> 28) == (1, 0, 12)
    assert x & 0x7ffffff == 4096
    checks += 1
    assert step('dsp_dot4_s12_pipe', pair(2047, 2047), pair(2047, 2047), 0)[2] == 1
    assert step('dsp_dot4_s12_pipe', pair(2047, 2047), pair(2047, 2047), 12)[2] == 0
    checks += 2
    # Hand-run IIR trace: restart seeds y from x, then a half-gain step.
    r, x, f, state = step('dsp_iir_lpf_s12', 500, 1024, 1 << 31)
    assert (r, f, state) == (500, 0, 500)
    r, x, f, state = step('dsp_iir_lpf_s12', w11(-500), 512, 0, state)
    assert (r, f, state) == (0, 0, 0)
    assert s_bits(x & 0xfff, 12) == -1000 and s_bits(x >> 14, 13) == -500
    checks += 2
    # A gain of 1.999 over-shoots, so the 11-bit output must clamp to -1024.
    r, x, f, state = step('dsp_iir_lpf_s12', 1023, 2047, 1 << 31)
    assert (r, f, state) == (1023, 0, 1023)
    r, x, f, state = step('dsp_iir_lpf_s12', w11(-1024), 2047, 0, state)
    assert (r, f, s_bits(state, 11), (x >> 13) & 1) == (0x400, 1, -1024, 1)
    assert s_bits(x & 0xfff, 12) == -2047 and s_bits(x >> 14, 13) == -4092
    checks += 2
    # FIR with a third-of-unity kernel: one beat of x=900 gives 300 at shift 12.
    state = 0
    r, x, f, state = step('dsp_fir3_s12', pair(1365, 1365), 1366, 1 << 31, state)
    assert (r, x, f) == (1366, (1365 << 12) | 1365, 0)
    r, x, f, state = step('dsp_fir3_s12', pair(900, 0), 0, 12 << 4, state)
    assert (r, f) == (300, 0)
    checks += 2
    # The same kernel at shift 0 must crop, and history must advance by one tap.
    r, x, f, state2 = step('dsp_fir3_s12', pair(900, 0), 0, 0, state)
    assert f == 1 and (x >> 24) & 1 == 1
    assert s_bits((state2 >> 36) & 0xfff, 12) == 900
    checks += 2
    # Malformed control never touches the coefficient store.
    r, x, f, kept = step('dsp_fir3_s12', 1, 1, 0x8000, state2)
    assert (r, x, f, kept) == (0, 0, 1, state2)
    checks += 1
    # Rounding identity: every crop-free result is within half an LSB of exact.
    for a_value, b_value in product(range(-2048, 2048, 257), range(0, 2048, 257)):
        for shift in range(13):
            r, x, f, _ = step('dsp_q12x2_round_sat', pair(a_value, 0), pair(b_value, 0), shift)
            if not f:
                assert abs(s_bits(r & 0xffff, 16) - a_value * b_value / (1 << shift)) < 1
            checks += 1
    # Two-tap MAC must equal the sum of two independent single-tap runs.
    left = right = 0
    for x0, x1, g0, g1 in ((100, -200, 300, 400), (5, 6, 7, 8), (-2048, 2047, 1, -1)):
        _, _, _, left = step('dsp_dot2_mac_s12', pair(x0, x1), pair(g0, g1), 0, left)
        _, _, _, right = step('dsp_mac_s12', w12(x0), w12(g0), 0, right)
        _, _, _, right = step('dsp_mac_s12', w12(x1), w12(g1), 0, right)
    assert left == right
    checks += 1
    return checks
