`timescale 1ns / 1ps
// tb_ips_ewma_moving_avg : production-line testbench for the EWMA + moving-average
// core.
//
// One sample per OPB-beat window.  Corners walk the input through full scale, the
// negative rail, zero and small values: the 0 -> 5 step is what drives the EWMA into
// its truncation limit cycle and latches the sticky stall flag, while the first eight
// windows are the moving-average warm-up during which cnt, not NTAP, is the divisor.
// A second start beat seven cycles into every window collides with a running division
// so the busy-start guard is exercised.  Outputs are sampled after the enabled edge
// and checked with === / !== for self-consistent invariants only (sticky stall,
// |rem| < cnt, valid versus busy, iteration count, no unknown bits --
// docs/IP_CORE_SOP.md trap T6), then folded into FNV-1a.  Value correctness lives in
// the digest, compared with models/ips_ewma_moving_avg.py written from the contract
// (trap T1).
module tb_ips_ewma_moving_avg;

`include "ips_tb_common.vh"

localparam integer BEATS = 480;
localparam integer OPB   = 15;
localparam [31:0]  SEED  = 32'h6E0DA505;

reg                rst_n;
reg                clk_en;
reg                start;
reg  [31:0]        state;
reg  signed [7:0]  x_in;

wire signed [7:0]  ewma;
wire signed [7:0]  mean;
wire signed [10:0] msum;
wire [3:0]         rem;
wire [3:0]         frac;
wire               stall;
wire               valid;
wire               busy;
wire [2:0]         stage;
wire [3:0]         wptr;
wire [3:0]         cnt;
wire [4:0]         it;

ips_ewma_moving_avg dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .x_in       (x_in),
    .ewma       (ewma),
    .mean       (mean),
    .msum       (msum),
    .rem        (rem),
    .frac       (frac),
    .stall      (stall),
    .valid      (valid),
    .busy       (busy),
    .stage      (stage),
    .wptr       (wptr),
    .cnt        (cnt),
    .it         (it)
);

wire signed [4:0] remse = $signed(rem);
wire [4:0]        remab = remse[4] ? (~remse + 5'sd1) : remse;

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer k;
reg     stall_seen;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b0;
    start       = 1'b0;
    state       = SEED;
    x_in        = 8'sd0;
    stall_seen  = 1'b0;
    bad         = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        clk_en    = 1'b1;
        state     = state * 32'd1664525 + 32'd1013904223;
        x_in      = state[9:2];
        k         = i % OPB;
        if (k == 0) begin
            case ((i / OPB) % 10)
                0: x_in = 8'sd0;
                1: x_in = 8'sd5;
                2: x_in = 8'sd127;
                3: x_in = 8'h80;
                4: x_in = 8'sd0;
                5: x_in = 8'sd64;
                6: x_in = 8'hA4;
                7: x_in = 8'sd7;
                default: begin end
            endcase
        end
        start = ((k == 0) || (k == 7)) ? 1'b1 : 1'b0;

        @(negedge ips_clk);
        clk_en = 1'b0;
        start  = 1'b0;

        if (stall_seen && (stall !== 1'b1)) begin
            bad = 1'b1;
        end
        if (stall === 1'b1) begin
            stall_seen = 1'b1;
        end
        if (valid === 1'b1 && busy === 1'b1) begin
            bad = 1'b1;
        end
        if ((cnt !== 4'd0) && (remab >= {1'b0, cnt})) begin
            bad = 1'b1;
        end
        if (it > 5'd20) begin
            bad = 1'b1;
        end
        if ((^ewma === 1'bx) || (^mean === 1'bx) || (^msum === 1'bx)
            || (^rem === 1'bx) || (^frac === 1'bx) || (^stage === 1'bx)
            || (^wptr === 1'bx) || (^cnt === 1'bx) || (^it === 1'bx)
            || (stall === 1'bx) || (valid === 1'bx) || (busy === 1'bx)) begin
            bad = 1'b1;
        end

        ips_fnv_word({16'd0, ewma, mean});
        ips_fnv_word({13'd0, msum, frac, rem});
        ips_fnv_word({13'd0, stall, valid, busy, stage, wptr, cnt, it});
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({16'd0, ewma, mean});
    ips_fnv_word({13'd0, msum, frac, rem});
    ips_fnv_word({13'd0, stall, valid, busy, stage, wptr, cnt, it});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_ewma_moving_avg");
end

endmodule
