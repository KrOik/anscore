`timescale 1ns / 1ps
// tb_ips_iir_biquad : production-line testbench for the transposed biquad section.
//
// One sample per OPB-beat window, corners (+full scale, -full scale, zero, half
// scale, -0.723, small positive) plus LCG-random mid bits, and a second start beat
// three cycles into every window so the busy-start guard is exercised.  The
// stimulus swings hard enough to make the shared accumulator clamp on some steps,
// which is what sat_cnt / satur record.  Outputs are sampled after the enabled
// edge, checked with === / !== for self-consistent invariants only (sticky satur,
// satur versus sat_cnt, valid versus busy, no unknown bits -- docs/IP_CORE_SOP.md
// trap T6) and folded into FNV-1a.  headroom is sampled one bit wider than GUARD so
// the guard-slice width shows up in the digest.  Value correctness lives in the
// digest, compared with models/ips_iir_biquad.py written from the contract (T1).
module tb_ips_iir_biquad;

`include "ips_tb_common.vh"

localparam integer BEATS = 288;
localparam integer OPB   = 6;
localparam [31:0]  SEED  = 32'h2C0DE5E5;

reg                rst_n;
reg                clk_en;
reg                start;
reg  [31:0]        state;
reg  signed [11:0] x_in;

wire signed [11:0] y_out;
wire signed [11:0] state1;
wire signed [11:0] state2;
wire [3:0]         headroom;
wire [7:0]         sat_cnt;
wire [7:0]         nsmp;
wire               satur;
wire               valid;
wire               busy;
wire [2:0]         stage;
wire [1:0]         step;

ips_iir_biquad dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .x_in       (x_in),
    .y_out      (y_out),
    .state1     (state1),
    .state2     (state2),
    .headroom   (headroom),
    .sat_cnt    (sat_cnt),
    .nsmp       (nsmp),
    .satur      (satur),
    .valid      (valid),
    .busy       (busy),
    .stage      (stage),
    .step       (step)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer k;
reg     satur_seen;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b0;
    start       = 1'b0;
    state       = SEED;
    x_in        = 12'sd0;
    satur_seen  = 1'b0;
    bad         = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        clk_en    = 1'b1;
        state     = state * 32'd1664525 + 32'd1013904223;
        x_in      = state[15:4];
        k         = i % OPB;
        if (k == 0) begin
            case ((i / OPB) % 6)
                0: x_in = 12'sd2047;
                1: x_in = 12'h800;
                2: x_in = 12'sd0;
                3: x_in = 12'sd1024;
                4: x_in = -12'sd1481;
                default: x_in = 12'sd341;
            endcase
        end
        start = ((k == 0) || (k == 3)) ? 1'b1 : 1'b0;

        @(negedge ips_clk);
        clk_en = 1'b0;
        start  = 1'b0;

        if (satur_seen && (satur !== 1'b1)) begin
            bad = 1'b1;
        end
        if (satur === 1'b1) begin
            satur_seen = 1'b1;
        end
        if (satur === 1'b1 && sat_cnt === 8'h00) begin
            bad = 1'b1;
        end
        if (valid === 1'b1 && busy === 1'b1) begin
            bad = 1'b1;
        end
        if ((^y_out === 1'bx) || (^state1 === 1'bx) || (^state2 === 1'bx)
            || (^headroom === 1'bx) || (^sat_cnt === 1'bx) || (^nsmp === 1'bx)
            || (^stage === 1'bx) || (^step === 1'bx) || (satur === 1'bx)
            || (valid === 1'bx) || (busy === 1'bx)) begin
            bad = 1'b1;
        end

        ips_fnv_word({8'd0, satur, valid, busy, stage, step, headroom, y_out});
        ips_fnv_word({8'd0, state1, state2});
        ips_fnv_word({8'd0, nsmp, sat_cnt});
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({8'd0, satur, valid, busy, stage, step, headroom, y_out});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_iir_biquad");
end

endmodule
