`timescale 1ns / 1ps
// ips_isqrt_iter : digit-by-digit (radix-4) integer square root with a fixed
// 16-iteration restoring loop.
//
// Written contract, mirrored independently by models/ips_isqrt_iter.py:
//   The 16-bit signed radicand is scanned most-significant bit-pair first, and
//   the loop keeps running FRAST+1 = 8 further digit steps over zero pairs, so
//   the root is the Q8 fixed-point square root of (radicand << 16): root[15:8]
//   is the integer root iroot and root[7:0] the eight fractional bits.  One
//   enabled beat performs one digit step of the restoring recurrence
//       shifted = 4*rem + next_bit_pair          (rem starts at 0)
//       test    = 4*root + 1
//       rem     = shifted - test, root = 2*root + 1   when shifted >= test
//       rem     = shifted,       root = 2*root        otherwise
//   which leaves rem = (radicand << 16) - root^2 after every step.  When the last
//   integer digit completes (iter == FRAST) the integer residual
//   radicand - iroot^2 is captured into irem, and `exact` reports that capture
//   being zero, i.e. the radicand is a perfect square.  iter counts the digit
//   steps of the current operation.  Stage 0 idle, 1 digit loop, 2 collect,
//   4 output pulse.
//   A negative radicand aborts at capture: the sticky invalid flag is set
//   (cleared only by rst_n), root/rem/irem are cleared and the loop is skipped, so
//   exact reads low.
//   Every register is gated by clk_en and rst_n is the active-low asynchronous
//   reset (docs/IP_CORE_SOP.md trap T2).
module ips_isqrt_iter #(
    parameter ITER  = 16,
    parameter FRAST = 7
)(
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,

    input  wire               start,
    input  wire signed [15:0] radicand,

    output reg  [15:0]        root,
    output reg  [9:0]         irem,
    output reg                exact,
    output reg                invalid,
    output reg                valid,
    output wire               busy,
    output reg  [4:0]         iter,
    output reg  [3:0]         stage
);

localparam [3:0] S_IDLE = 4'sd0;
localparam [3:0] S_RUN  = 4'sd1;
localparam [3:0] S_COL  = 4'sd2;
localparam [3:0] S_OUT  = 4'sd4;
localparam [4:0] S_LAST = ITER - 5'sd1;
localparam [4:0] S_FRAC = FRAST;

assign busy = (stage != S_IDLE);

reg [16:0] rem;
reg [15:0] rad;
reg        abort;

wire        neg = radicand[15];
wire [15:0] mag = neg ? (~radicand + 16'sd1) : radicand[15:0];
wire [18:0] shifted = {rem, rad[15:14]};
wire [18:0] test    = {1'b0, root, 2'b00} + 19'sd1;
wire        fits    = (shifted >= test);
wire [18:0] rem_new = fits ? (shifted - test) : shifted;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        root    <= 16'sd0;
        irem    <= 10'sd0;
        exact   <= 1'sb0;
        invalid <= 1'sb0;
        valid   <= 1'sb0;
        stage   <= S_IDLE;
        iter    <= 5'sd0;
        rem     <= 17'sd0;
        rad     <= 16'sd0;
        abort   <= 1'sb0;
    end else if (clk_en) begin
        if (start && (stage == S_IDLE)) begin
            valid <= 1'sb0;
            iter  <= 5'sd0;
            rem   <= 17'sd0;
            root  <= 16'sd0;
            irem  <= 10'sd0;
            exact <= 1'sb0;
            rad   <= mag;
            abort <= neg;
            stage <= neg ? S_COL : S_RUN;
            if (neg) begin
                invalid <= 1'b1;
            end
        end else begin
            case (stage)
                S_RUN: begin
                    rem  <= rem_new[16:0];
                    root <= {root[14:0], fits};
                    rad  <= {rad[13:0], 2'b00};
                    iter <= iter + 5'd1;
                    if (iter == S_FRAC) begin
                        irem <= rem_new[9:0];
                    end
                    if (iter == S_LAST) begin
                        stage <= S_COL;
                    end
                end
                S_COL: begin
                    exact <= ((irem == 10'd0) && !abort);
                    stage <= S_OUT;
                end
                default: begin
                    if (stage == S_OUT) begin
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
