`timescale 1ns / 1ps
// tb_ips_pdm_decim16 : production-line testbench for the PDM decimator.
//
// One core cycle per beat (clk_en is high for exactly one clock edge per beat)
// and the oversample tick is an explicit input, so the golden model replays every
// integrator step and every comb frame.  The 1-bit stream is a deterministic
// pattern suite rather than a recorded one:
//   [0,    W_DC_HI)  alternating 1010  -> half-scale silence, no saturation
//   [W_DC_HI, W_DC_LO)  stuck high     -> positive full scale, saturates high
//   [W_DC_LO, W_RAMP)   stuck low      -> negative full scale, saturates low
//   [W_RAMP, W_NOISE)   duty ramp 0..R -> walks through the linear region
//   [W_NOISE, W_GAP)    LCG dither     -> pseudo-random density
//   [W_GAP, W_CORRUPT)  corrupt frame  -> input stuck high while pdm_tick is
//                                        withdrawn for a few beats: the filter
//                                        must simply hold its phase and counts
//   [W_CORRUPT, W_ALT2) alternating again, then stuck high once more so the
//                       saturation counter walks into SAT_MAX.
// Folded: status bits + phase, the signed PCM word, and the saturating counters.
// Observed with === / !== plus unknown-bit checks; the expected stream is not
// written here (docs/IP_CORE_SOP.md trap T1).
module tb_ips_pdm_decim16;

`include "ips_tb_common.vh"

localparam integer BEATS    = 1200;
localparam integer W_DC_HI  = 120;
localparam integer W_DC_LO  = 240;
localparam integer W_RAMP   = 360;
localparam integer W_RAMP_L = 20;
localparam integer W_NOISE  = 700;
localparam integer W_GAP    = 960;
localparam integer W_CORR   = 1000;
localparam integer W_ALT2   = 1120;
localparam [31:0]  SEED     = 32'h9ADDECA5;

reg         rst_n;
reg         clk_en;
reg         pdm_tick;
reg         pdm_in;
reg  [31:0] state;

wire signed [15:0] pcm;
wire [3:0]         pcm_hr;
wire               pcm_valid;
wire               sat_pos;
wire               sat_neg;
wire               sat_sticky;
wire [7:0]         sat_count;
wire [7:0]         out_count;
wire [4:0]         phase;

reg [31:0] w1;
reg [31:0] w2;
reg [31:0] w3;
reg        dump;

ips_pdm_decim16 dut (
    .clk       (ips_clk),
    .clk_en    (clk_en),
    .rst_n     (rst_n),
    .pdm_tick  (pdm_tick),
    .pdm_in    (pdm_in),
    .pcm       (pcm),
    .pcm_hr    (pcm_hr),
    .pcm_valid (pcm_valid),
    .sat_pos   (sat_pos),
    .sat_neg   (sat_neg),
    .sat_sticky(sat_sticky),
    .sat_count (sat_count),
    .out_count (out_count),
    .phase     (phase)
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
    dump     = $test$plusargs("DUMP");
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    pdm_tick = 1'b0;
    pdm_in   = 1'b0;
    state    = SEED;
    bad      = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        state = state * 32'd1664525 + 32'd1013904223;

        if (i < W_DC_HI) begin
            pdm_in = i[0];
        end else if (i < W_DC_LO) begin
            pdm_in = 1'b1;
        end else if (i < W_RAMP) begin
            pdm_in = 1'b0;
        end else if (i < W_NOISE) begin
            pdm_in = ((i % 16) < ((i - W_RAMP) / W_RAMP_L));
        end else if (i < W_GAP) begin
            pdm_in = state[7];
        end else if (i < W_CORR) begin
            pdm_in = 1'b1;
        end else if (i < W_ALT2) begin
            pdm_in = i[0];
        end else begin
            pdm_in = 1'b1;
        end

        pdm_tick = ~((i >= W_GAP) && (i < W_CORR - 34));
        clk_en   = 1'b1;

        @(negedge ips_clk);
        clk_en = 1'b0;

        if ((^pcm === 1'bx) || (^pcm_hr === 1'bx) || (^phase === 1'bx))     bad = 1'b1;
        if ((^sat_count === 1'bx) || (^out_count === 1'bx))                 bad = 1'b1;
        if ((pcm_valid === 1'bx) || (sat_pos === 1'bx) || (sat_neg === 1'bx)) bad = 1'b1;
        if ((sat_sticky === 1'bx) || (sat_pos === 1'b1 && sat_neg === 1'b1)) bad = 1'b1;
        if ((sat_sticky === 1'b0 && sat_count !== 8'h00) ||
            (out_count === 8'h00 && pcm !== 16'h0000))                       bad = 1'b1;

        w1 = {19'd0, pcm_valid, sat_pos, sat_neg, sat_sticky, pcm_hr, phase};
        w2 = {16'd0, pcm};
        w3 = {16'd0, sat_count, out_count};
        ips_fnv_word(w1);
        ips_fnv_word(w2);
        ips_fnv_word(w3);
        if (dump && (i % 16) == 15) $display("DBG %0d %h %h %h", i, w1, w2, w3);
    end

    repeat (2) @(negedge ips_clk);
    w1 = {19'd0, pcm_valid, sat_pos, sat_neg, sat_sticky, pcm_hr, phase};
    w2 = {16'd0, pcm};
    w3 = {16'd0, sat_count, out_count};
    ips_fnv_word(w1);
    ips_fnv_word(w2);
    ips_fnv_word(w3);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_pdm_decim16");
end

endmodule
