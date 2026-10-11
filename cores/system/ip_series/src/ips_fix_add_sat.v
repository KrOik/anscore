`timescale 1ns / 1ps
// ips_fix_add_sat : three-operand fixed-point saturating adder with headroom
// reporting and running min/max tracking.
//
// Signed Q(WIDTH-1).(WIDTH-1) operands are extended by GUARD bits, summed, and
// clamped back into WIDTH.  headroom carries the guard slice of the unclipped
// sum so an integrator can see how far past full scale the beat was.  One
// registered result per in_valid beat; sat_pos / sat_neg flag the direction and
// clip_count counts saturating beats (8-bit, wraps).  Every register is gated by
// clk_en, and rst_n is the active-low asynchronous reset, per docs/IP_CORE_SOP.md.
module ips_fix_add_sat #(
    parameter WIDTH = 16,
    parameter GUARD = 2
)(
    input  wire                     clk,
    input  wire                     clk_en,
    input  wire                     rst_n,

    input  wire                     in_valid,
    input  wire  signed [WIDTH-1:0] a,
    input  wire  signed [WIDTH-1:0] b,
    input  wire  signed [WIDTH-1:0] k,

    output reg   signed [WIDTH-1:0] y,
    output reg                      sat_pos,
    output reg                      sat_neg,
    output reg      [GUARD-1:0]     headroom,
    output reg      [7:0]           clip_count,
    output reg   signed [WIDTH-1:0] y_max,
    output reg   signed [WIDTH-1:0] y_min
);

localparam signed [WIDTH-1:0] VAL_MAX = {1'b0, {(WIDTH - 1){1'b1}}};
localparam signed [WIDTH-1:0] VAL_MIN = {1'b1, {(WIDTH - 1){1'b0}}};

wire signed [WIDTH+GUARD-1:0] ea = {{GUARD{a[WIDTH-1]}}, a};
wire signed [WIDTH+GUARD-1:0] eb = {{GUARD{b[WIDTH-1]}}, b};
wire signed [WIDTH+GUARD-1:0] ek = {{GUARD{k[WIDTH-1]}}, k};

wire signed [WIDTH+GUARD-1:0] sum  = ea + eb + ek;
wire signed [WIDTH+GUARD-1:0] sext = {{GUARD{sum[WIDTH-1]}}, sum[WIDTH-1:0]};

wire                     overflow  = (sum != sext);
// The clip direction comes from the sign bit of the widened word, not from bit
// WIDTH-1: a sum that overflowed past +full scale can still show a positive low
// slice once it has wrapped past 2**WIDTH.
wire                     over_pos  = (overflow && !sum[WIDTH+GUARD-1]);
wire                     over_neg  = (overflow &&  sum[WIDTH+GUARD-1]);
wire signed [WIDTH-1:0]  clamped   = overflow ? (over_neg ? VAL_MIN : VAL_MAX)
                                              : sum[WIDTH-1:0];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        y         <= {(WIDTH){1'b0}};
        sat_pos   <= 1'b0;
        sat_neg   <= 1'b0;
        headroom  <= {(GUARD){1'b0}};
        clip_count <= 8'h00;
        y_max     <= VAL_MIN;
        y_min     <= VAL_MAX;
    end else if (clk_en) begin
        if (in_valid) begin
            y        <= clamped;
            sat_pos  <= over_pos;
            sat_neg  <= over_neg;
            headroom <= sum[WIDTH+GUARD-1:WIDTH];
            if (overflow) begin
                clip_count <= clip_count + 8'h01;
            end
            if (clamped > y_max) begin
                y_max <= clamped;
            end
            if (clamped < y_min) begin
                y_min <= clamped;
            end
        end
    end
end

endmodule
