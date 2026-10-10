`timescale 1ns / 1ps
// tb_ips_fix_add_sat : production-line testbench for the saturating adder core.
//
// Drives BEATS deterministic three-operand beats from a shared LCG contract,
// samples the registered result one clock later (one in_valid beat per result),
// checks the saturation properties with === so X can never look like a pass
// (docs/IP_CORE_SOP.md trap T6), and folds every observed word into FNV-1a.
// The expected stream is NOT written here: models/ips_fix_add_sat.py computes it
// independently and the gate compares the two digests (trap T1).
module tb_ips_fix_add_sat;

`include "ips_tb_common.vh"

localparam integer BEATS = 512;
localparam [31:0]  SEED  = 32'hC0FFEE11;

reg                 rst_n;
reg                 clk_en;
reg                 in_valid;
reg  [31:0]         state;
reg  signed [15:0]  a;
reg  signed [15:0]  b;
reg  signed [15:0]  k;

wire signed [15:0]  y;
wire                sat_pos;
wire                sat_neg;
wire [2:0]          headroom;
wire [7:0]          clip_count;
wire signed [15:0]  y_max;
wire signed [15:0]  y_min;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.  Overriding
// parameters in the testbench would hide the defaults from the mutation station.
ips_fix_add_sat dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (in_valid),
    .a          (a),
    .b          (b),
    .k          (k),
    .y          (y),
    .sat_pos    (sat_pos),
    .sat_neg    (sat_neg),
    .headroom   (headroom),
    .clip_count (clip_count),
    .y_max      (y_max),
    .y_min      (y_min)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    in_valid  = 1'b0;
    a         = 16'd0;
    b         = 16'd0;
    k         = 16'd0;
    state     = SEED;
    bad       = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        state    = state * 32'd1664525 + 32'd1013904223;
        a        = state[15:0];
        b        = state[31:16];
        k        = state[22:7];
        in_valid = 1'b1;

        @(negedge ips_clk);
        in_valid = 1'b0;

        if (sat_pos === 1'b1 && sat_neg === 1'b1)      bad = 1'b1;
        if (sat_pos === 1'b1 && y !== 16'h7FFF)         bad = 1'b1;
        if (sat_neg === 1'b1 && y !== 16'h8000)         bad = 1'b1;
        if (sat_pos === 1'b1 && headroom[1] === 1'b1)   bad = 1'b1;
        if (sat_neg === 1'b1 && headroom[1] === 1'b0)   bad = 1'b1;
        if ((^y === 1'bx) || (^y_max === 1'bx) || (^y_min === 1'bx)) bad = 1'b1;

        ips_fnv_word({{16{y[15]}}, y});
        ips_fnv_word({29'd0, headroom});
        ips_fnv_word({30'd0, sat_pos, sat_neg});
        ips_fnv_word({{16{y_max[15]}}, y_max});
        ips_fnv_word({{16{y_min[15]}}, y_min});
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({24'd0, clip_count});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_fix_add_sat");
end

endmodule
