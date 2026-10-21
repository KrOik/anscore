`timescale 1ns / 1ps
// tb_ips_booth_mult_s16 : production-line testbench for the radix-4 Booth core.
//
// Drives BEATS deterministic beats from the shared LCG contract, one multiply per
// OPB beats plus a deliberate start-while-busy collision at beat 5 of every op,
// and corner operands (min*min, max*-1, zero, min*-1) on every fifth op.  The
// registered DUT outputs are sampled one clock after the stimulus edge, checked
// with === / !== so X can never look like a pass (docs/IP_CORE_SOP.md trap T6)
// and folded into FNV-1a.  The run ends after a fixed number of edges.  Expected
// values are NOT written here: models/ips_booth_mult_s16.py computes the same
// stream independently and the gate compares the two digests (trap T1).
module tb_ips_booth_mult_s16;

`include "ips_tb_common.vh"

localparam integer BEATS = 288;
localparam integer OPB   = 16;
localparam [31:0]  SEED  = 32'h51A7E51A;

reg                rst_n;
reg                clk_en;
reg                start;
reg  [31:0]        state;
reg  signed [15:0] operand_a;
reg  signed [15:0] operand_b;

wire signed [31:0] product;
wire               ovf;
wire               valid;
wire               busy;
wire [3:0]         stage;
wire [3:0]         ppc;
wire               [7:0] err_start;
wire [31:0]        ext16;

ips_booth_mult_s16 dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .operand_a  (operand_a),
    .operand_b  (operand_b),
    .product    (product),
    .ovf        (ovf),
    .valid      (valid),
    .busy       (busy),
    .stage      (stage),
    .ppc        (ppc),
    .err_start  (err_start)
);

assign ext16 = {{16{product[15]}}, product[15:0]};

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer k;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    clk_en     = 1'b0;
    start      = 1'b0;
    state      = SEED;
    operand_a  = 16'd0;
    operand_b  = 16'd0;
    bad        = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        clk_en    = 1'b1;
        state     = state * 32'd1664525 + 32'd1013904223;
        operand_a = state[15:0];
        operand_b = state[31:16];
        k         = i % OPB;
        if (k == 0) begin
            case ((i / OPB) % 5)
                0: begin operand_a = 16'h8000; operand_b = 16'h8000; end
                1: begin operand_a = 16'h7FFF; operand_b = 16'hFFFF; end
                2: begin operand_a = 16'h0000; operand_b = 16'h7FFF; end
                3: begin operand_a = 16'h8000; operand_b = 16'hFFFF; end
                default: begin end
            endcase
        end
        start = (k == 0 || k == 5) ? 1'b1 : 1'b0;

        @(negedge ips_clk);
        clk_en = 1'b0;
        start  = 1'b0;

        if (ovf === 1'b1 && product === ext16)   bad = 1'b1;
        if (ovf === 1'b0 && product !== ext16)   bad = 1'b1;
        if (valid === 1'b1 && busy === 1'b1)     bad = 1'b1;
        if (stage > 4'd5)                        bad = 1'b1;
        if (ppc > 4'd9)                          bad = 1'b1;
        if ((^product === 1'bx) || (^stage === 1'bx) || (^ppc === 1'bx)
            || (^err_start === 1'bx) || (ovf === 1'bx) || (valid === 1'bx)
            || (busy === 1'bx)) begin
            bad = 1'b1;
        end

        ips_fnv_word({21'd0, ovf, valid, busy, stage, ppc});
        ips_fnv_word(product);
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({24'd0, err_start});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_booth_mult_s16");
end

endmodule
