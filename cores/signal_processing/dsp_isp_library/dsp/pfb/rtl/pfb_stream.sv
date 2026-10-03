// ============================================================================
// DSP-16 pfb_stream -- polyphase filter bank channelizer, small M.
//
// Structure: complex (or real, im=0) input stream -> sample commutator ->
// M polyphase FIR branches (P taps each, prototype-LPF coefficients from the
// generated `pfb_coeffs.vh` LUT) -> M-point radix-2 DIT FFT -> per-channel
// Q2.16 gain -> tagged output beats.
//
// Frame / rate contract (critically sampled: channel rate = fs_in / M):
//   frame f covers input beats n = f*M + r, r = 0..M-1; beat r is steered to
//   branch r.  v_f[m] = sum_{p=0}^{P-1} h[p*M+m] * x[(f-p)*M+m].  The M-point
//   DFT of v_f is emitted as one burst of M beats: m_tid = bin index k
//   (channel centre = k/M cycles per input sample, bins > M/2 are negative
//   frequencies), m_tlast on k==M-1, m_tuser = frame tag (mod 256).
//
// The compute engine is serialized: after a frame of M samples is captured,
// the FIR walks its M*P branch/tap pairs, the FFT walks (M/2)*log2(M)
// butterflies, then one snapshot cycle; the output burst drains concurrently
// with the next frame's capture.  Sustained input contract: M samples accepted
// per
//   T_frame = M + (3*M*P + 2*M) + 4*(M/2)*log2(M) + 1   clock cycles
// (plus output-drain wait if a whole burst stalls).  s_tready is pure
// backpressure; there is no per-frame II=1 claim.
//
// Why the arithmetic is spread over several cycles per tap and per butterfly:
// a silicon measurement of this core (board/eth_rate_harness, CORE 6) showed
// every emitted word wrong, differently on each repeat of the same request,
// while the cycle counters matched the model exactly -- control intact, data
// path broken, which is the signature of a combinational cone that does not
// settle in one 50 MHz cycle.  The original one-cycle-per-tap cone chained a
// 64:1 history mux, an 18x16 multiply, a 40-bit ripple accumulate, a 41-bit
// rounding add, four 41-bit magnitude compares and a saturation mux; the
// butterfly chained three 17x17 shift-add multipliers (each a five-level tree
// of 32-bit ripple adds) into two more ripple adds and two 18-bit adds.  Each
// stage now registers between one arithmetic step and the next, so every cycle
// holds at most a multiply plus one add, and the twiddle multiplier is reduced
// with carry-save compression instead of a ripple tree (see mul17).  The
// arithmetic itself is unchanged and still bit-exact against models/model.py.
//
// Fixed point: input/output signed16 Q1.15; coefficients signed18 Q1.17;
// FIR accumulator 40 bits, branch output sat16((acc + 2^16) >>> 17); FFT
// twiddles Q1.15 with (a +/- t) >>> 1 truncation to 16 bits, so the emitted
// value is DFT(v)/M; gain product sat16((g*x + 2^15) >>> 16).
//
// Configuration: cfg_valid && cfg_ready commits gain[cfg_addr] atomically at
// a frame boundary while the drain is idle; cfg_addr >= M raises cfg_error
// and changes nothing.  Static parameters outside M in {4,8,16}, P in
// 1..16, M*P <= 256 are rejected at elaboration.
// ============================================================================
module pfb_stream #(
    parameter integer M = 8,        // channels: 4, 8 or 16 (power of two)
    parameter integer P = 8         // taps per branch: 1..16, M*P <= 256
) (
    input  wire        clk,
    input  wire        rst_n,       // synchronous active-low reset
    // input stream: {im[31:16], re[15:0]} signed16 each; real users tie im=0
    input  wire [31:0] s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    // output stream: one M-beat burst per frame
    output reg  [31:0] m_tdata,     // {im,re} signed16, gain-scaled
    output reg  [3:0]  m_tid,       // channel / FFT bin index 0..M-1
    output reg  [7:0]  m_tuser,     // frame sequence tag (cnt_frames mod 256)
    output reg         m_tlast,     // high on the tid==M-1 beat of a burst
    output reg         m_tvalid,
    input  wire        m_tready,
    // atomic per-channel gain write, signed18 Q2.16 (65536 = 1.0)
    input  wire        cfg_valid,
    output wire        cfg_ready,
    input  wire [4:0]  cfg_addr,
    input  wire signed [17:0] cfg_gain,
    output reg         cfg_done,
    output reg         cfg_error,
    // observability
    output wire        busy,
    output reg  [19:0] cnt_in,      // accepted input beats
    output reg  [15:0] cnt_frames,  // completed output bursts
    output reg  [19:0] cnt_out,     // accepted output beats
    output reg         clip_sticky  // any FIR/gain saturation since reset
);

`include "pfb_coeffs.vh"            // localparam PFB_NCOEF, PFB_COEF

localparam integer L2  = (M == 16) ? 4 : ((M == 8) ? 3 : 2);
localparam integer NP  = M * P;
localparam [1:0] ST_CAP = 2'd0, ST_FIR = 2'd1, ST_FFT = 2'd2, ST_SNP = 2'd3;
// Sub-phases inside ST_FIR: one tap is read (F_LD), multiplied (F_MP) and
// accumulated (F_AC); the end of a branch rounds (F_RN) and then clips/writes
// (F_CL).  Inside ST_FFT: operands (S_LD), products (S_MP), twiddle collapse
// (S_TR), butterfly write (S_BT).
localparam [2:0] F_LD = 3'd0, F_MP = 3'd1, F_AC = 3'd2, F_RN = 3'd3, F_CL = 3'd4;
localparam [2:0] S_LD = 3'd0, S_MP = 3'd1, S_TR = 3'd2, S_BT = 3'd3;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// Low 32 bits of a signed 17x17 product, reduced with carry-save compression
// (0 DSP).  The value is bit-identical to the plain shift-add tree it replaces:
// the terms are the same 17 partial products mod 2^32, and a 3:2 compression
// step (sum = x^y^z, carry = majority<<1) preserves the sum of the pool exactly.
// It is only the SHAPE that differs: a ripple tree of 32-bit adds needs five
// levels of 32 carry bits, ~160 carry steps, while this needs six single-level
// compression steps and one collapse -- the reason the butterfly could not
// settle inside one 50 MHz cycle before.
function signed [31:0] mul17;
    input signed [16:0] a;
    input signed [16:0] b;
    reg signed [31:0] sa;
    reg [32*17-1:0] pool;              // live terms, packed at the front
    reg [63:0] p;
    integer i;
    begin
        sa = a;
        // The same 17 partial products the ripple tree summed, mod 2^32.
        for (i = 0; i < 17; i = i + 1) pool[i*32 +: 32] = 32'd0;
        for (i = 0; i < 16; i = i + 1)
            pool[i*32 +: 32] = b[i] ? (sa <<< i) : 32'd0;
        pool[16*32 +: 32] = b[16] ? -(sa <<< 16) : 32'd0;
        // Six 3:2 levels: 17 -> 12 -> 8 -> 6 -> 4 -> 3 -> 2 live terms.  Within
        // a level the write head (2 per triple) always trails the read head
        // (3 per triple), and the triple is captured into p before it is
        // written back, so the pool can be compressed in place.
        for (i = 0; i < 15; i = i + 3) begin
            p = cs3(pool[i*32 +: 32], pool[(i+1)*32 +: 32],
                    pool[(i+2)*32 +: 32]);
            pool[(2*(i/3))*32 +: 32] = p[31:0];
            pool[(2*(i/3)+1)*32 +: 32] = p[63:32];
        end
        pool[10*32 +: 32] = pool[15*32 +: 32];
        pool[11*32 +: 32] = pool[16*32 +: 32];
        for (i = 0; i < 12; i = i + 3) begin
            p = cs3(pool[i*32 +: 32], pool[(i+1)*32 +: 32],
                    pool[(i+2)*32 +: 32]);
            pool[(2*(i/3))*32 +: 32] = p[31:0];
            pool[(2*(i/3)+1)*32 +: 32] = p[63:32];
        end
        for (i = 0; i < 6; i = i + 3) begin
            p = cs3(pool[i*32 +: 32], pool[(i+1)*32 +: 32],
                    pool[(i+2)*32 +: 32]);
            pool[(2*(i/3))*32 +: 32] = p[31:0];
            pool[(2*(i/3)+1)*32 +: 32] = p[63:32];
        end
        pool[4*32 +: 32] = pool[6*32 +: 32];
        pool[5*32 +: 32] = pool[7*32 +: 32];
        for (i = 0; i < 6; i = i + 3) begin
            p = cs3(pool[i*32 +: 32], pool[(i+1)*32 +: 32],
                    pool[(i+2)*32 +: 32]);
            pool[(2*(i/3))*32 +: 32] = p[31:0];
            pool[(2*(i/3)+1)*32 +: 32] = p[63:32];
        end
        p = cs3(pool[0*32 +: 32], pool[1*32 +: 32], pool[2*32 +: 32]);
        pool[0*32 +: 32] = p[31:0];
        pool[1*32 +: 32] = p[63:32];
        pool[2*32 +: 32] = pool[3*32 +: 32];
        p = cs3(pool[0*32 +: 32], pool[1*32 +: 32], pool[2*32 +: 32]);
        pool[0*32 +: 32] = p[31:0];
        pool[1*32 +: 32] = p[63:32];
        mul17 = pool[0*32 +: 32] + pool[1*32 +: 32];
    end
endfunction

// One 3:2 carry-save step: {carry, sum} of three terms, whose arithmetic sum is
// exactly the three inputs reduced mod 2^32.
function [63:0] cs3;
    input [31:0] x, y, z;
    begin
        cs3 = {((x & y) | (z & (x ^ y))) << 1, x ^ y ^ z};
    end
endfunction

function [3:0] bitrev4;
    input [3:0] v;
    begin bitrev4 = {v[0], v[1], v[2], v[3]}; end
endfunction

// W_16^t = cos(2 pi t/16) - j sin(2 pi t/16), Q1.15, stored as (cos, +sin)
// saturated to +-32767 (fft64 convention: t = b*(c - j*s) uses s directly).
// Covers every twiddle for M = 4/8/16 via twa = pos << (4 - stage).
function [31:0] twrom;
    input [2:0] t;
    begin
        case (t)
            3'd0: twrom = { 16'sd32767,  16'sd0};
            3'd1: twrom = { 16'sd30274,  16'sd12540};
            3'd2: twrom = { 16'sd23170,  16'sd23170};
            3'd3: twrom = { 16'sd12540,  16'sd30274};
            3'd4: twrom = { 16'sd0,      16'sd32767};
            3'd5: twrom = {-16'sd12540,  16'sd30274};
            3'd6: twrom = {-16'sd23170,  16'sd23170};
            default: twrom = {-16'sd30274, 16'sd12540};
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------
reg  [1:0]  st;
reg  [2:0]  fs;                  // sub-phase inside ST_FIR / ST_FFT
reg  [3:0]  rpos;                // commutator position inside the frame
reg         draining;            // output burst in progress (indep. of st)
reg         dp;                  // drain phase: 0 forms the product, 1 emits
reg  [3:0]  ok;                  // drain channel index
reg  [4:0]  ndepth;              // frames of valid branch history, 0..P
reg  [3:0]  fm;                  // FIR branch index
reg  [4:0]  fp;                  // FIR tap index
reg  [2:0]  stage;               // FFT stage 1..L2
reg  [3:0]  bf;                  // FFT butterfly index within stage
reg signed [39:0] acc_re, acc_im;

// Registered boundaries between the arithmetic steps of one tap / one
// butterfly.  Every one of them is written in the sub-phase before the one
// that reads it, so none of them needs a reset value.
reg signed [17:0] coef_r;
reg signed [15:0] hs_re_r, hs_im_r;
reg signed [33:0] pr_re_r, pr_im_r;
reg signed [40:0] q_re_r, q_im_r;
reg signed [15:0] ar_r, ai_r, br_r, bi_r, twc_r, tws_r;
reg signed [16:0] bsum_r;
reg signed [31:0] g0_r, g1_r, g2_r;
reg signed [16:0] t_re_r, t_im_r;
reg signed [33:0] gpr_re, gpr_im;   // drain gain product, one cycle per phase

reg signed [15:0] h_re  [0:NP-1];   // h[m*P+p]; p=0 newest
reg signed [15:0] h_im  [0:NP-1];
reg signed [15:0] xr    [0:M-1];    // FFT working array (bit-rev in)
reg signed [15:0] xi    [0:M-1];
reg signed [15:0] outr  [0:M-1];    // drain snapshot
reg signed [15:0] outi  [0:M-1];
reg signed [17:0] gain  [0:M-1];    // Q2.16

assign s_tready  = rst_n && (st == ST_CAP);
assign cfg_ready = rst_n && (st == ST_CAP) && (rpos == 0) && !draining;
assign busy      = (st != ST_CAP) || (rpos != 0) || m_tvalid || draining;
wire s_fire = s_tvalid && s_tready;

// ---------------------------------------------------------------------------
// FIR slice, one step per cycle: (fm, fp) selects the coefficient and the
// branch history word (F_LD), the latched pair multiplies (F_MP), the product
// accumulates (F_AC), the branch sum rounds (F_RN), the rounded value clips and
// is written to the FFT array (F_CL).
// ---------------------------------------------------------------------------
wire [8:0]        cidx  = fp * M + fm;
wire signed [17:0] fcoef = PFB_COEF[cidx*18 +: 18];
wire              hok   = (fp < ndepth);
wire signed [15:0] hs_re = hok ? h_re[fm*P + fp] : 16'sd0;
wire signed [15:0] hs_im = hok ? h_im[fm*P + fp] : 16'sd0;
wire signed [33:0] fpr_re = coef_r * hs_re_r;
wire signed [33:0] fpr_im = coef_r * hs_im_r;
wire signed [39:0] facc_re = acc_re + {{6{pr_re_r[33]}}, pr_re_r};
wire signed [39:0] facc_im = acc_im + {{6{pr_im_r[33]}}, pr_im_r};
// signed add (NOT a concat: concatenations are unsigned and would turn the
// arithmetic >>> into a logical shift for negative accumulators)
wire signed [40:0] vq_re = (acc_re + 40'sd65536) >>> 17;
wire signed [40:0] vq_im = (acc_im + 40'sd65536) >>> 17;
wire              vclip = (q_re_r > 41'sd32767) || (q_re_r < -41'sd32768)
                       || (q_im_r > 41'sd32767) || (q_im_r < -41'sd32768);
wire signed [15:0] v_re = (q_re_r > 41'sd32767)  ? 16'sh7fff
                        : (q_re_r < -41'sd32768) ? 16'sh8000
                        : q_re_r[15:0];
wire signed [15:0] v_im = (q_im_r > 41'sd32767)  ? 16'sh7fff
                        : (q_im_r < -41'sd32768) ? 16'sh8000
                        : q_im_r[15:0];
wire [3:0] fir_waddr = bitrev4(fm) >> (4 - L2);   // DIT bit-reversed write

// ---------------------------------------------------------------------------
// FFT slice, one step per cycle: the two array words and the twiddle are read
// (S_LD), the three 17x17 products are formed (S_MP), they collapse to the
// rotated difference (S_TR), and the butterfly writes the array back (S_BT).
// stage/bf hold still across the four, so bi/bj address the same pair throughout.
// ---------------------------------------------------------------------------
wire [3:0] half  = 4'd1 << (stage - 3'd1);
wire [3:0] bpos  = bf & (half - 4'd1);
wire [3:0] bblk  = bf >> (stage - 3'd1);
wire [3:0] bi    = (bblk << stage) | bpos;
wire [3:0] bj    = bi + half;
wire [2:0] twa   = (bpos << (3'd4 - stage));      // W_16 index 0..7
wire [31:0] twd   = twrom(twa);
wire signed [15:0] twc = twd[31:16];
wire signed [15:0] tws = twd[15:0];
wire signed [15:0] a_re = xr[bi];
wire signed [15:0] a_im = xi[bi];
wire signed [15:0] b_re = xr[bj];
wire signed [15:0] b_im = xi[bj];
wire signed [16:0] bsum = {b_re[15], b_re} + {b_im[15], b_im};
wire signed [16:0] scd  = {tws_r[15], tws_r} - {twc_r[15], twc_r};
wire signed [16:0] css  = {twc_r[15], twc_r} + {tws_r[15], tws_r};
wire signed [31:0] g0n = mul17(bsum_r, {twc_r[15], twc_r});
wire signed [31:0] g1n = mul17({bi_r[15], bi_r}, scd);
wire signed [31:0] g2n = mul17({br_r[15], br_r}, css);
wire signed [16:0] t_re = (g0_r + g1_r + 32'sh00004000) >>> 15;
wire signed [16:0] t_im = (g0_r - g2_r + 32'sh00004000) >>> 15;
wire signed [17:0] s_re = {{2{ar_r[15]}}, ar_r} + {t_re_r[16], t_re_r};
wire signed [17:0] d_re = {{2{ar_r[15]}}, ar_r} - {t_re_r[16], t_re_r};
wire signed [17:0] s_im = {{2{ai_r[15]}}, ai_r} + {t_im_r[16], t_im_r};
wire signed [17:0] d_im = {{2{ai_r[15]}}, ai_r} - {t_im_r[16], t_im_r};
wire signed [16:0] oi_re = s_re >>> 1;
wire signed [16:0] oi_im = s_im >>> 1;
wire signed [16:0] oj_re = d_re >>> 1;
wire signed [16:0] oj_im = d_im >>> 1;

// ---------------------------------------------------------------------------
// drain combinational slice: per-channel gain on the snapshot.  The product is
// formed one cycle earlier (gpr_*) so no cycle holds both the multiplier and the
// 35-bit rounding add: DSP clock pins are tied low in this flow, so a
// multiplier's real delay never appears in the timing report.
// ---------------------------------------------------------------------------
wire signed [17:0] og    = gain[ok];
wire signed [33:0] gp_re = og * outr[ok];
wire signed [33:0] gp_im = og * outi[ok];
// signed add, same reasoning as vq_*
wire signed [34:0] gq_re = (gpr_re + 34'sd32768) >>> 16;
wire signed [34:0] gq_im = (gpr_im + 34'sd32768) >>> 16;
wire              gclip = (gq_re > 35'sd32767) || (gq_re < -35'sd32768)
                       || (gq_im > 35'sd32767) || (gq_im < -35'sd32768);
wire signed [15:0] g_re = (gq_re > 35'sd32767)  ? 16'sh7fff
                        : (gq_re < -35'sd32768) ? 16'sh8000
                        : gq_re[15:0];
wire signed [15:0] g_im = (gq_im > 35'sd32767)  ? 16'sh7fff
                        : (gq_im < -35'sd32768) ? 16'sh8000
                        : gq_im[15:0];

// ---------------------------------------------------------------------------
// sequential
// ---------------------------------------------------------------------------
integer ii;
always @(posedge clk) begin
    if (!rst_n) begin
        st <= ST_CAP;  rpos <= 4'd0;
        fs <= F_LD;
        draining <= 1'b0;  dp <= 1'b0;
        ok <= 4'd0; ndepth <= 5'd0;
        fm <= 4'd0; fp <= 5'd0; stage <= 3'd0; bf <= 4'd0;
        acc_re <= 40'sd0; acc_im <= 40'sd0;
        m_tvalid <= 1'b0; m_tdata <= 32'd0; m_tid <= 4'd0;
        m_tuser <= 8'd0; m_tlast <= 1'b0;
        cfg_done <= 1'b0; cfg_error <= 1'b0;
        cnt_in <= 20'd0; cnt_frames <= 16'd0; cnt_out <= 20'd0;
        clip_sticky <= 1'b0;
        for (ii = 0; ii < M; ii = ii + 1) gain[ii] <= 18'sd65536;
    end else begin
        cfg_done  <= 1'b0;
        cfg_error <= 1'b0;
        // output slot: accept clears, reload below keeps bursts back-to-back
        if (m_tvalid && m_tready) begin
            m_tvalid <= 1'b0;
            cnt_out  <= cnt_out + 20'd1;
        end
        // atomic gain commit at a frame boundary with an idle drain
        if (cfg_valid && cfg_ready) begin
            if (cfg_addr < M) begin
                gain[cfg_addr] <= cfg_gain;
                cfg_done <= 1'b1;
            end else begin
                cfg_error <= 1'b1;
            end
        end
        // drain burst (runs while st==CAP captures the next frame): one cycle
        // forms the gain product, the next rounds, clips and presents the word
        if (draining) begin
            if (!dp) begin
                gpr_re <= gp_re;
                gpr_im <= gp_im;
                dp     <= 1'b1;
            end else if (!m_tvalid || m_tready) begin
                m_tvalid <= 1'b1;
                m_tdata  <= {g_im, g_re};
                m_tid    <= ok;
                m_tuser  <= cnt_frames[7:0];
                m_tlast  <= (ok == M - 1);
                if (gclip) clip_sticky <= 1'b1;
                if (ok == M - 1) begin
                    draining   <= 1'b0;
                    cnt_frames <= cnt_frames + 16'd1;
                end else begin
                    ok <= ok + 4'd1;
                    dp <= 1'b0;
                end
            end
        end
        case (st)
            ST_CAP: if (s_fire) begin
                for (ii = 1; ii < P; ii = ii + 1) begin
                    h_re[rpos*P + ii] <= h_re[rpos*P + ii - 1];
                    h_im[rpos*P + ii] <= h_im[rpos*P + ii - 1];
                end
                h_re[rpos*P] <= s_tdata[15:0];
                h_im[rpos*P] <= s_tdata[31:16];
                cnt_in <= cnt_in + 20'd1;
                if (rpos == M - 1) begin
                    rpos   <= 4'd0;
                    st     <= ST_FIR;
                    fs     <= F_LD;
                    fm     <= 4'd0;
                    fp     <= 5'd0;
                    acc_re <= 40'sd0;
                    acc_im <= 40'sd0;
                    if (ndepth < P) ndepth <= ndepth + 5'd1;
                end else begin
                    rpos <= rpos + 4'd1;
                end
            end
            ST_FIR: case (fs)
                F_LD: begin
                    coef_r <= fcoef;
                    hs_re_r <= hs_re;
                    hs_im_r <= hs_im;
                    fs <= F_MP;
                end
                F_MP: begin
                    pr_re_r <= fpr_re;
                    pr_im_r <= fpr_im;
                    fs <= F_AC;
                end
                F_AC: begin
                    acc_re <= facc_re;
                    acc_im <= facc_im;
                    if (fp == P - 1) begin
                        fs <= F_RN;
                    end else begin
                        fp <= fp + 5'd1;
                        fs <= F_LD;
                    end
                end
                F_RN: begin
                    q_re_r <= vq_re;
                    q_im_r <= vq_im;
                    fs <= F_CL;
                end
                default: begin                        // F_CL
                    xr[fir_waddr] <= v_re;
                    xi[fir_waddr] <= v_im;
                    if (vclip) clip_sticky <= 1'b1;
                    fp     <= 5'd0;
                    acc_re <= 40'sd0;
                    acc_im <= 40'sd0;
                    if (fm == M - 1) begin
                        st    <= ST_FFT;
                        fs    <= S_LD;
                        stage <= 3'd1;
                        bf    <= 4'd0;
                    end else begin
                        fm <= fm + 4'd1;
                        fs <= F_LD;
                    end
                end
            endcase
            ST_FFT: case (fs)
                S_LD: begin
                    ar_r <= a_re;
                    ai_r <= a_im;
                    br_r <= b_re;
                    bi_r <= b_im;
                    twc_r <= twc;
                    tws_r <= tws;
                    bsum_r <= bsum;
                    fs <= S_MP;
                end
                S_MP: begin
                    g0_r <= g0n;
                    g1_r <= g1n;
                    g2_r <= g2n;
                    fs <= S_TR;
                end
                S_TR: begin
                    t_re_r <= t_re;
                    t_im_r <= t_im;
                    fs <= S_BT;
                end
                default: begin                        // S_BT
                    xr[bi] <= oi_re[15:0];
                    xi[bi] <= oi_im[15:0];
                    xr[bj] <= oj_re[15:0];
                    xi[bj] <= oj_im[15:0];
                    if (bf == M/2 - 1) begin
                        bf <= 4'd0;
                        fs <= S_LD;
                        if (stage == L2) st <= ST_SNP;
                        else stage <= stage + 3'd1;
                    end else begin
                        bf <= bf + 4'd1;
                        fs <= S_LD;
                    end
                end
            endcase
            ST_SNP: if (!draining) begin
                for (ii = 0; ii < M; ii = ii + 1) begin
                    outr[ii] <= xr[ii];
                    outi[ii] <= xi[ii];
                end
                draining <= 1'b1;
                ok       <= 4'd0;
                dp       <= 1'b0;
                st       <= ST_CAP;
            end
            default: st <= ST_CAP;
        endcase
    end
end

`ifndef SYNTHESIS
initial begin
    if (M != 4 && M != 8 && M != 16)
        $fatal(1, "pfb_stream: M=%0d unsupported (4/8/16)", M);
    if (P < 1 || P > 16)
        $fatal(1, "pfb_stream: P=%0d out of range (1..16)", P);
    if (M * P > 256)
        $fatal(1, "pfb_stream: M*P=%0d exceeds 256", M * P);
    if (PFB_NCOEF != M * P)
        $fatal(1, "pfb_stream: pfb_coeffs.vh has %0d taps, need %0d",
               PFB_NCOEF, M * P);
end
`endif
endmodule
