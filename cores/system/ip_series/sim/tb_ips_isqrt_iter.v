`timescale 1ns / 1ps
// tb_ips_isqrt_iter : production-line testbench for the digit-by-digit isqrt core.
//
// One radicand per OPB-beat window, corners (perfect squares 0, 1, 9, 32761 =
// 181*181, the non-squares 2 and 32767, a negative radicand that must raise the
// sticky invalid flag) plus LCG-random values, and a second start beat one cycle
// into every window so the busy-start guard is exercised.  The radicand port is
// signed, so only non-negative values root.  Outputs are sampled after the enabled
// edge, checked with === / !== for self-consistent invariants only (sticky
// invalid, valid versus busy, exact versus the reported residual, no unknown bits
// -- docs/IP_CORE_SOP.md trap T6) and folded into FNV-1a.  Value correctness lives
// in the digest, which the gate compares against models/ips_isqrt_iter.py, written
// from the contract (trap T1).
module tb_ips_isqrt_iter;

`include "ips_tb_common.vh"

localparam integer BEATS = 480;
localparam integer OPB   = 20;
localparam [31:0]  SEED  = 32'h15A7E5D0;

reg                rst_n;
reg                clk_en;
reg                start;
reg  [31:0]        state;
reg  signed [15:0] radicand;

wire [15:0]        root;
wire [9:0]         irem;
wire               exact;
wire               invalid;
wire               valid;
wire               busy;
wire [4:0]         iter;
wire [3:0]         stage;

ips_isqrt_iter dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .radicand   (radicand),
    .root       (root),
    .irem       (irem),
    .exact      (exact),
    .invalid    (invalid),
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
reg     invalid_seen;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n         = 1'b0;
    clk_en        = 1'b0;
    start         = 1'b0;
    state         = SEED;
    radicand      = 16'sd0;
    invalid_seen  = 1'b0;
    bad           = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        clk_en    = 1'b1;
        state     = state * 32'd1664525 + 32'd1013904223;
        radicand  = state[15:0];
        k         = i % OPB;
        if (k == 0) begin
            case ((i / OPB) % 7)
                0: radicand = 16'sd9;
                1: radicand = 16'sd2;
                2: radicand = 16'sd32761;
                3: radicand = 16'h8000;
                4: radicand = 16'sd32767;
                5: radicand = 16'sd0;
                default: radicand = 16'sd1;
            endcase
        end
        start = ((k == 0) || (k == 1)) ? 1'b1 : 1'b0;

        @(negedge ips_clk);
        clk_en = 1'b0;
        start  = 1'b0;

        if (invalid_seen && (invalid !== 1'b1)) begin
            bad = 1'b1;
        end
        if (invalid === 1'b1) begin
            invalid_seen = 1'b1;
        end
        if (valid === 1'b1 && busy === 1'b1) begin
            bad = 1'b1;
        end
        if (exact === 1'b1 && (irem !== 10'd0)) begin
            bad = 1'b1;
        end
        if ((^root === 1'bx) || (^irem === 1'bx) || (^iter === 1'bx)
            || (^stage === 1'bx) || (exact === 1'bx) || (invalid === 1'bx)
            || (valid === 1'bx) || (busy === 1'bx)) begin
            bad = 1'b1;
        end

        ips_fnv_word({19'd0, invalid, exact, valid, busy, stage, iter});
        ips_fnv_word({16'd0, root});
        ips_fnv_word({22'd0, irem});
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({19'd0, invalid, exact, valid, busy, stage, iter});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_isqrt_iter");
end

endmodule
