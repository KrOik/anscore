`timescale 1ns / 1ps
// tb_ips_i2s_tx_master : production-line testbench for the I2S transmit master.
//
// BEATS deterministic beats.  One core cycle per beat: clk_en is the series
// divisor (one enabled clock edge per beat) and `tick` is the oversample tick the
// master divides down to SCLK.  The stimulus is a deterministic pattern, not a
// recorded one:
//   * samples are offered every 64th beat while k < OFFER_END, plus one offer
//     that coincides with a slot start (COIN) to pin down the latch priority;
//   * the tick stream stops for IDLE_W beats at IDLE_A and for IDLE_BW beats at
//     IDLE_B -- the malformed-input cases, the master must hold its bit phase;
//   * once the offer window closes, every slot start re-runs the latched word,
//     which walks the under-run counter into its UNDER_MAX saturation.
// Outputs are sampled with === / !== and an unknown-bit check, then folded into
// ips_fnv_word.  No expectation lives here: models/ips_i2s_tx_master.py derives
// the same stream from the written contract (docs/IP_CORE_SOP.md trap T1).
module tb_ips_i2s_tx_master;

`include "ips_tb_common.vh"

localparam integer BEATS   = 2560;
localparam integer OFFER_END = 600;
localparam integer COIN    = 1028;
localparam integer IDLE_A  = 1200;
localparam integer IDLE_W  = 24;
localparam integer IDLE_B  = 2100;
localparam integer IDLE_BW = 3;
localparam [31:0]  SEED    = 32'h1DEEA2E5;

reg                 rst_n;
reg                 clk_en;
reg                 tick;
reg                 ch_valid;
reg  [31:0]         state;
reg  signed [19:0]  ch_l;
reg  signed [19:0]  ch_r;

wire                sclk;
wire                lrclk;
wire                sd;
wire                fresh_l;
wire                fresh_r;
wire [6:0]          bit_idx;
wire [3:0]          div_idx;
wire [7:0]          word_count;
wire [7:0]          under_count;
wire                underflow_sticky;

reg  [31:0]         w1;
reg  [31:0]         w2;
reg                 dump;

// Input registers are 20 bits wide while the core declares WORD_W = 16: the low
// slice is what the shipped default sees, and widening WORD_W reaches the extra
// bits instead of silently leaving the parameter unobservable.
ips_i2s_tx_master dut (
    .clk              (ips_clk),
    .clk_en           (clk_en),
    .rst_n            (rst_n),
    .tick             (tick),
    .ch_valid         (ch_valid),
    .ch_l             (ch_l),
    .ch_r             (ch_r),
    .sclk             (sclk),
    .lrclk            (lrclk),
    .sd               (sd),
    .fresh_l          (fresh_l),
    .fresh_r          (fresh_r),
    .bit_idx          (bit_idx),
    .div_idx          (div_idx),
    .word_count       (word_count),
    .under_count      (under_count),
    .underflow_sticky (underflow_sticky)
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
    dump      = $test$plusargs("DUMP");
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    tick      = 1'b0;
    ch_valid  = 1'b0;
    ch_l      = 20'd0;
    ch_r      = 20'd0;
    state     = SEED;
    bad       = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);
        state = state * 32'd1664525 + 32'd1013904223;
        ch_l  = {state[3:0],  state[31:16]};
        ch_r  = {~state[3:0], state[15:0]};
        tick  = ~(((i >= IDLE_A) && (i < IDLE_A + IDLE_W)) ||
                  ((i >= IDLE_B) && (i < IDLE_B + IDLE_BW)));
        ch_valid = (((i < OFFER_END) && ((i % 64) == 0)) || (i == COIN));
        clk_en   = 1'b1;

        @(negedge ips_clk);
        clk_en = 1'b0;

        if ((^bit_idx === 1'bx) || (^div_idx === 1'bx))             bad = 1'b1;
        if ((^word_count === 1'bx) || (^under_count === 1'bx))       bad = 1'b1;
        if ((sclk === 1'bx) || (lrclk === 1'bx) || (sd === 1'bx))    bad = 1'b1;
        if ((fresh_l === 1'bx) || (fresh_r === 1'bx))                bad = 1'b1;
        if ((underflow_sticky === 1'bx) || (underflow_sticky === 1'b0 && under_count !== 8'h00)) bad = 1'b1;

        w1 = {15'd0, fresh_r, fresh_l, underflow_sticky, sclk, lrclk, sd, bit_idx, div_idx};
        w2 = {16'd0, word_count, under_count};
        ips_fnv_word(w1);
        ips_fnv_word(w2);
        if (dump) $display("DBG %0d %h %h", i, w1, w2);
    end

    repeat (2) @(negedge ips_clk);
    w1 = {15'd0, fresh_r, fresh_l, underflow_sticky, sclk, lrclk, sd, bit_idx, div_idx};
    w2 = {16'd0, word_count, under_count};
    ips_fnv_word(w1);
    ips_fnv_word(w2);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_i2s_tx_master");
end

endmodule
