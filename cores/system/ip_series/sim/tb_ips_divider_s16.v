`timescale 1ns / 1ps
// tb_ips_divider_s16 : production-line testbench for the restoring divider core.
//
// One divide per OPB beats, corner cases (min/-1 which needs the 17-bit quotient,
// two divide-by-zero aborts, negative remainder, exact division) plus LCG-random
// pairs, and one logical beat per enabled clock edge.  Outputs are sampled after
// the edge, checked with === / !== for self-consistent invariants only (sticky
// divz, valid vs busy, no unknown bits -- docs/IP_CORE_SOP.md trap T6) and folded
// into FNV-1a.  Value correctness lives in the digest, which the gate compares
// against models/ips_divider_s16.py computed from the written contract (trap T1).
module tb_ips_divider_s16;

`include "ips_tb_common.vh"

localparam integer BEATS = 288;
localparam integer OPB   = 24;
localparam [31:0]  SEED  = 32'hD1E1DE00;

reg                rst_n;
reg                clk_en;
reg                start;
reg  [31:0]        state;
reg  signed [15:0] dividend;
reg  signed [15:0] divisor;

wire signed [16:0] quotient;
wire signed [15:0] remainder;
wire               divz;
wire               valid;
wire               busy;
wire [4:0]         iter;
wire [3:0]         stage;

ips_divider_s16 dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .dividend   (dividend),
    .divisor    (divisor),
    .quotient   (quotient),
    .remainder  (remainder),
    .divz       (divz),
    .valid      (valid),
    .busy       (busy),
    .iter       (iter),
    .stage      (stage)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer k;
reg     divz_seen;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b0;
    start       = 1'b0;
    state       = SEED;
    dividend    = 16'd0;
    divisor     = 16'd0;
    divz_seen   = 1'b0;
    bad         = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        clk_en    = 1'b1;
        state     = state * 32'd1664525 + 32'd1013904223;
        dividend  = state[15:0];
        divisor   = state[31:16];
        k         = i % OPB;
        if (k == 0) begin
            case ((i / OPB) % 6)
                0: begin dividend = 16'h8000; divisor = 16'hFFFF; end
                1: begin dividend = 16'h0007; divisor = 16'h0000; end
                2: begin dividend = 16'h8000; divisor = 16'h0003; end
                3: begin dividend = 16'h0064; divisor = 16'hFFF9; end
                4: begin dividend = 16'h7FFF; divisor = 16'h7FFF; end
                default: begin end
            endcase
        end
        start = (k == 0) ? 1'b1 : 1'b0;

        @(negedge ips_clk);
        clk_en = 1'b0;
        start  = 1'b0;

        if (divz_seen && (divz !== 1'b1)) begin
            bad = 1'b1;
        end
        if (divz === 1'b1) begin
            divz_seen = 1'b1;
        end
        if (valid === 1'b1 && busy === 1'b1) begin
            bad = 1'b1;
        end
        if ((^quotient === 1'bx) || (^remainder === 1'bx) || (^iter === 1'bx)
            || (^stage === 1'bx) || (divz === 1'bx) || (valid === 1'bx)
            || (busy === 1'bx)) begin
            bad = 1'b1;
        end

        ips_fnv_word({20'd0, divz, valid, busy, stage, iter});
        ips_fnv_word({15'd0, quotient});
        ips_fnv_word({16'd0, remainder});
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({20'd0, divz, valid, busy, stage, iter});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_divider_s16");
end

endmodule
