`timescale 1ns / 1ps
// ips_divider_s16 : iterative restoring signed 16/16 divider.
//
// Written contract, mirrored independently by models/ips_divider_s16.py:
//   start is accepted only in stage 0.  Capture replaces both operands by their
//   unsigned magnitudes (16-bit, so |-32768| = 32768 is representable), records
//   quotient sign = sign(dividend) ^ sign(divisor) and remainder sign =
//   sign(dividend), clears rem and iter, loads the dividend magnitude into the
//   quotient shift register and the divisor magnitude into the comparator.
//   Stage 1 then runs ITER restoring steps, one per enabled beat, counted in
//   iter: shift the {rem, qsr} pair left by one, and when the shifted remainder
//   reaches the divisor subtract it and set the incoming quotient bit, otherwise
//   clear that bit.  Stage 2 collects the signed results (truncation toward zero,
//   remainder keeps the dividend sign, so dividend == quotient * divisor +
//   remainder), quotient is 17-bit wide because -32768 / -1 = +32768 is not a
//   signed 16-bit value.  Stage PIPE pulses valid for one beat.
//   A zero divisor aborts at capture: the sticky divz flag is set (cleared only
//   by rst_n), the quotient shift register is loaded with zero instead of the
//   dividend magnitude, the restoring loop is skipped and the collected quotient
//   and remainder are therefore both zero.
//   Every register is gated by clk_en and rst_n is the active-low asynchronous
//   reset (docs/IP_CORE_SOP.md trap T2).
module ips_divider_s16 #(
    parameter ITER = 16,
    parameter PIPE = 4
)(
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,

    input  wire               start,
    input  wire signed [15:0] dividend,
    input  wire signed [15:0] divisor,

    output reg  signed [16:0] quotient,
    output reg  signed [15:0] remainder,
    output reg                divz,
    output reg                valid,
    output wire               busy,
    output reg  [4:0]         iter,
    output reg  [3:0]         stage
);

localparam [3:0] S_IDLE = 4'sd0;
localparam [3:0] S_RUN  = 4'sd1;
localparam [3:0] S_COL  = 4'sd2;
localparam [4:0] S_LAST = ITER - 5'sd1;

assign busy = (stage != S_IDLE);

reg [16:0] rem;
reg [15:0] qsr;
reg [15:0] dsv;
reg        sgn_q;
reg        sgn_r;

wire       a_neg = dividend[15];
wire       b_neg = divisor[15];
wire [15:0] am = a_neg ? (~dividend + 16'sd1) : dividend[15:0];
wire [15:0] bm = b_neg ? (~divisor + 16'sd1) : divisor[15:0];
wire        zero = (bm == 16'sd0);

wire [16:0] dsv17  = {1'b0, dsv};
wire [16:0] shifted = {rem[15:0], qsr[15]};
wire        fits = (shifted >= dsv17);

wire signed [16:0] qext = $signed({1'b0, qsr});
wire signed [16:0] rext = $signed({1'sb0, rem[15:0]});
wire signed [16:0] rq   = sgn_q ? -qext : qext;
wire signed [16:0] rr   = sgn_r ? -rext : rext;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        quotient  <= 17'sd0;
        remainder <= 16'sd0;
        divz      <= 1'sb0;
        valid     <= 1'sb0;
        stage     <= S_IDLE;
        iter      <= 5'sd0;
        rem       <= 17'sd0;
        qsr       <= 16'sd0;
        dsv       <= 16'sd0;
        sgn_q     <= 1'sb0;
        sgn_r     <= 1'sb0;
    end else if (clk_en) begin
        if (start && (stage == S_IDLE)) begin
            valid <= 1'sb0;
            iter  <= 5'sd0;
            rem   <= 17'sd0;
            qsr   <= zero ? 16'sd0 : am;
            dsv   <= bm;
            sgn_q <= (a_neg ^ b_neg);
            sgn_r <= a_neg;
            stage <= zero ? S_COL : S_RUN;
            if (zero) begin
                divz <= 1'b1;
            end
        end else begin
            case (stage)
                S_RUN: begin
                    rem  <= fits ? (shifted - dsv17) : shifted;
                    qsr  <= {qsr[14:0], (fits ? 1'b1 : 1'b0)};
                    iter <= iter + 5'd1;
                    if (iter == S_LAST) begin
                        stage <= S_COL;
                    end
                end
                S_COL: begin
                    quotient  <= rq;
                    remainder <= rr[15:0];
                    stage     <= PIPE;
                end
                default: begin
                    if (stage == PIPE) begin
                        valid <= 1'sb1;
                        stage <= S_IDLE;
                    end else begin
                        valid <= 1'sb0;
                    end
                end
            endcase
        end
    end
end

endmodule
