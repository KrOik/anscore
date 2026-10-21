`timescale 1ns / 1ps
// ips_iir_biquad : transposed direct-form II biquad section, one shared
// accumulator, saturating state update.
//
// Written contract, mirrored independently by models/ips_iir_biquad.py:
// Samples and states are signed Q11 (12 bit, full scale 2047); the five
//   coefficients B0, B1, B2, C1, C2 are integer parameters re-cast as signed Q6
//   taps (8 bit two's complement, LSB 1/64).  With the negated denominator
//   coefficients folded into C1 = -a1 and C2 = -a2 the transposed recursion is
//       y(n)    = b0*x(n) + s1(n-1)
//       s1(n)   = b1*x(n) + s2(n-1) + c1*y(n)
//       s2(n)   = b2*x(n) + c2*y(n)
//   Each coefficient product is rounded to nearest and rescaled by QDIV,
//       t = (x * c + PRND) >>> QDIV      with PRND = 2**(QDIV-1) = 32,
//   then the three terms of the current step are summed in a 16-bit signed
//   accumulator and clamped back to Q11: an out-of-range sum writes -2048 or
//   +2047, increments sat_cnt and latches the sticky satur flag.  headroom
//   carries the GUARD slice of the unclipped sum, sum[11+GUARD:12], of the last
//   step that ran.
//   One sample takes six enabled beats: capture x, the three accumulation steps
//   (step = 0, 1, 2), collect (y_out takes the saturated y) and the output pulse.
//   Stage 0 idle, 1 accumulation, 2 collect, 3 output; nsmp counts completed
//   samples.  start is ignored while the section is busy.  Every register is
//   gated by clk_en and rst_n is the active-low asynchronous reset
//   (docs/IP_CORE_SOP.md trap T2).
module ips_iir_biquad #(
    parameter B0    = 6,
    parameter B1    = 13,
    parameter B2    = 6,
    parameter C1    = 90,
    parameter C2    = -38,
    parameter QDIV  = 6,
    parameter GUARD = 3
)(
    input  wire                clk,
    input  wire                clk_en,
    input  wire                rst_n,

    input  wire                start,
    input  wire signed [11:0]  x_in,

    output reg  signed [11:0]  y_out,
    output reg  signed [11:0]  state1,
    output reg  signed [11:0]  state2,
    output reg  [GUARD-1:0]    headroom,
    output reg  [7:0]          sat_cnt,
    output reg  [7:0]          nsmp,
    output reg                 satur,
    output reg                 valid,
    output wire                busy,
    output wire [2:0]          stage,
    output reg  [1:0]          step
);

localparam [2:0]  S_STEP = 3'd1;
localparam [2:0]  S_COL  = 3'd2;
localparam [2:0]  S_OUT  = 3'd3;
localparam        S_IDLE = 3'd0;

localparam signed [19:0] PRND   = 20'd32;
localparam signed [11:0] Q_MAX  = 12'h7ff;
localparam signed [11:0] Q_MIN  = 12'h800;

// The coefficient parameters are untyped so the packaging tool can read the
// header; they are re-cast here as signed Q6 taps, which is what the products use.
localparam signed [7:0]  KB0    = B0;
localparam signed [7:0]  KB1    = B1;
localparam signed [7:0]  KB2    = B2;
localparam signed [7:0]  KC1    = C1;
localparam signed [7:0]  KC2    = C2;

assign busy = (stage != S_IDLE);

reg signed [11:0] lx;
reg signed [11:0] yr;
reg [2:0]         stage_r;

assign stage = stage_r;

wire signed [19:0] p_b0 = lx * KB0;
wire signed [19:0] p_b1 = lx * KB1;
wire signed [19:0] p_b2 = lx * KB2;
wire signed [19:0] p_c1 = yr * KC1;
wire signed [19:0] p_c2 = yr * KC2;

wire signed [19:0] t_b0 = (p_b0 + PRND) >>> QDIV;
wire signed [19:0] t_b1 = (p_b1 + PRND) >>> QDIV;
wire signed [19:0] t_b2 = (p_b2 + PRND) >>> QDIV;
wire signed [19:0] t_c1 = (p_c1 + PRND) >>> QDIV;
wire signed [19:0] t_c2 = (p_c2 + PRND) >>> QDIV;

wire signed [13:0] q_b0 = t_b0[13:0];
wire signed [13:0] q_b1 = t_b1[13:0];
wire signed [13:0] q_b2 = t_b2[13:0];
wire signed [13:0] q_c1 = t_c1[13:0];
wire signed [13:0] q_c2 = t_c2[13:0];

wire signed [15:0] e_s1 = state1;
wire signed [15:0] e_s2 = state2;

wire signed [15:0] op_a = (step == 2'd0) ? q_b0 : ((step == 2'd1) ? q_b1 : q_b2);
wire signed [15:0] op_b = (step == 2'd0) ? e_s1 : ((step == 2'd1) ? e_s2 : 16'sd0);
wire signed [15:0] op_c = (step == 2'd0) ? 16'sd0 : ((step == 2'd1) ? q_c1 : q_c2);

wire signed [15:0] sum  = op_a + op_b + op_c;
wire signed [15:0] sext = {{4{sum[11]}}, sum[11:0]};

wire                overflow = (sum != sext);
wire                over_neg = (overflow &&  sum[15]);
wire signed [11:0]  clamped  = overflow ? (over_neg ? Q_MIN : Q_MAX) : sum[11:0];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lx      <= 12'sd0;
        yr      <= 12'sd0;
        y_out   <= 12'sd0;
        state1  <= 12'sd0;
        state2  <= 12'sd0;
        headroom <= 3'h00;
        sat_cnt  <= 8'h00;
        nsmp     <= 8'h00;
        satur    <= 1'b0;
        valid    <= 1'b0;
        stage_r  <= S_IDLE;
        step     <= 2'd0;
    end else if (clk_en) begin
        if (start && (stage_r == S_IDLE)) begin
            lx     <= x_in;
            yr     <= 12'sd0;
            stage_r <= S_STEP;
            step   <= 2'd0;
            valid  <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (stage_r)
                S_STEP: begin
                    headroom <= sum[11+GUARD:12];
                    if (overflow) begin
                        sat_cnt <= sat_cnt + 8'h01;
                        satur   <= 1'b1;
                    end
                    case (step)
                        2'd0:    yr     <= clamped;
                        2'd1:    state1 <= clamped;
                        default: state2 <= clamped;
                    endcase
                    if (step == 2'd2) begin
                        stage_r <= S_COL;
                        step    <= 2'd0;
                    end else begin
                        step <= step + 2'd1;
                    end
                end
                S_COL: begin
                    y_out   <= yr;
                    stage_r <= S_OUT;
                end
                S_OUT: begin
                    valid   <= 1'b1;
                    nsmp    <= nsmp + 8'h01;
                    stage_r <= S_IDLE;
                end
                default: begin
                    stage_r <= S_IDLE;
                end
            endcase
        end
    end
end

endmodule
