`timescale 1ns / 1ps
// tb_ips_i2s_rx_slave : production-line testbench for the I2S receive slave.
//
// A deterministic virtual I2S source is synthesised from the beat index: with
// OSO = 2 ticks per SCLK half period a bit lasts BIT_BEATS = 4 ticks, a slot
// lasts SLOT_B bits and a stereo frame FRAME_BITS bits.  One core cycle per beat
// (clk_en is high for exactly one clock edge per beat), so the tick the core
// sees is the series divisor and the Python model replays every edge.
//
// Malformed-input cases, all deterministic:
//   * STALL window   : the bit clock is held low, the watchdog must report lost
//                      clock ticks and the misaligned restart must slip slots;
//   * GLITCH window  : the bit clock doubles, bit_count over-runs the slot and
//                      slip_count walks into its saturation;
//   * BP1 / BP2      : rx_ready drops for long enough that pending words are
//                      overwritten, which walks drop_count into DROP_MAX;
//   * IDLE window    : tick itself is withdrawn, the core must simply freeze.
// Observed with === / !== plus unknown-bit checks and folded into ips_fnv_word;
// no expectation lives here (docs/IP_CORE_SOP.md trap T1).
module tb_ips_i2s_rx_slave;

`include "ips_tb_common.vh"

localparam integer BEATS      = 1600;
localparam integer OSO        = 2;
localparam integer BIT_BEATS  = 4;
localparam integer SLOT_BITS  = 17;
localparam integer FRAME_BITS = 34;
localparam integer FRAME_BEATS= 136;
localparam integer WORD_BITS  = 16;
localparam integer STALL_A    = 300;
localparam integer STALL_L    = 50;
localparam integer GLITCH_A   = 700;
localparam integer GLITCH_L   = 10;
localparam integer IDLE_A     = 1000;
localparam integer IDLE_W     = 6;
localparam integer BP1_A      = 400;
localparam integer BP1_L      = 300;
localparam integer BP2_A      = 900;
localparam integer BP2_L      = 300;
localparam [31:0]  SEED       = 32'h5A1710E2;

reg                 rst_n;
reg                 clk_en;
reg                 tick;
reg                 sclk_i;
reg                 lrclk_i;
reg                 sd_i;
reg                 rx_ready;
reg  [31:0]         fstate;
reg  [15:0]         cur_l;
reg  [15:0]         cur_r;

wire signed [15:0]  rx_word;
wire                rx_valid;
wire                rx_chan;
wire [5:0]          bit_count;
wire [7:0]          cap_count;
wire [7:0]          drop_count;
wire [3:0]          slip_count;
wire [3:0]          lost_count;
wire                slip_sticky;
wire                lost_sticky;
wire                sclk_q;
wire                lrclk_q;

reg  [31:0]         w1;
reg  [31:0]         w2;
reg  [31:0]         w3;
reg                 dump;

ips_i2s_rx_slave dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .tick       (tick),
    .sclk_i     (sclk_i),
    .lrclk_i    (lrclk_i),
    .sd_i       (sd_i),
    .rx_ready   (rx_ready),
    .rx_word    (rx_word),
    .rx_valid   (rx_valid),
    .rx_chan    (rx_chan),
    .bit_count  (bit_count),
    .cap_count  (cap_count),
    .drop_count (drop_count),
    .slip_count (slip_count),
    .lost_count (lost_count),
    .slip_sticky(slip_sticky),
    .lost_sticky(lost_sticky),
    .sclk_q     (sclk_q),
    .lrclk_q    (lrclk_q)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer m;
integer fp;
integer q;
reg     bad;
reg     in_stall;
reg     in_glitch;

initial begin
    ips_fnv_reset();
    dump     = $test$plusargs("DUMP");
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    tick     = 1'b0;
    sclk_i   = 1'b0;
    lrclk_i  = 1'b0;
    sd_i     = 1'b0;
    rx_ready = 1'b1;
    fstate   = SEED;
    cur_l    = 16'd0;
    cur_r    = 16'd0;
    bad      = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        if ((i % FRAME_BEATS) == 0) begin
            fstate = fstate * 32'd1664525 + 32'd1013904223;
            cur_l  = fstate[15:0];
            cur_r  = fstate[31:16];
        end

        m  = i / BIT_BEATS;
        fp = m % FRAME_BITS;
        q  = fp % SLOT_BITS;

        in_stall  = ((i >= STALL_A) && (i < STALL_A + STALL_L));
        in_glitch = ((i >= GLITCH_A) && (i < GLITCH_A + GLITCH_L));

        if (in_stall) begin
            sclk_i = 1'b0;
        end else if (in_glitch) begin
            sclk_i = i[0];
        end else begin
            sclk_i = (((i / OSO) % 2) == 1);
        end

        lrclk_i = (fp >= SLOT_BITS);
        if (q == 0) begin
            sd_i = 1'b0;
        end else begin
            sd_i = (fp >= SLOT_BITS) ? cur_r[WORD_BITS - q] : cur_l[WORD_BITS - q];
        end

        tick     = ~((i >= IDLE_A) && (i < IDLE_A + IDLE_W));
        rx_ready = ~(((i >= BP1_A) && (i < BP1_A + BP1_L)) ||
                     ((i >= BP2_A) && (i < BP2_A + BP2_L)));
        clk_en   = 1'b1;

        @(negedge ips_clk);
        clk_en = 1'b0;

        if ((^rx_word === 1'bx) || (^bit_count === 1'bx))                    bad = 1'b1;
        if ((^cap_count === 1'bx) || (^drop_count === 1'bx))                 bad = 1'b1;
        if ((^slip_count === 1'bx) || (^lost_count === 1'bx))                bad = 1'b1;
        if ((rx_valid === 1'bx) || (rx_chan === 1'bx) || (sclk_q === 1'bx))  bad = 1'b1;
        if ((lrclk_q === 1'bx) || (slip_sticky === 1'bx) || (lost_sticky === 1'bx)) bad = 1'b1;
        if ((slip_sticky === 1'b0 && slip_count !== 4'h0) ||
            (lost_sticky === 1'b0 && lost_count !== 4'h0))                   bad = 1'b1;
        if ((drop_count !== 8'h00 && cap_count === 8'h00) ||
            (cap_count === 8'h00 && rx_word !== 16'h0000))                  bad = 1'b1;

        w1 = {13'd0, rx_valid, rx_chan, slip_sticky, lost_sticky, sclk_q, lrclk_q,
              bit_count, slip_count, lost_count};
        w2 = {16'd0, rx_word};
        w3 = {16'd0, cap_count, drop_count};
        ips_fnv_word(w1);
        ips_fnv_word(w2);
        ips_fnv_word(w3);
        if (dump) $display("DBG %0d %h %h %h", i, w1, w2, w3);
    end

    repeat (2) @(negedge ips_clk);
    w1 = {13'd0, rx_valid, rx_chan, slip_sticky, lost_sticky, sclk_q, lrclk_q,
          bit_count, slip_count, lost_count};
    w2 = {16'd0, rx_word};
    w3 = {16'd0, cap_count, drop_count};
    ips_fnv_word(w1);
    ips_fnv_word(w2);
    ips_fnv_word(w3);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_i2s_rx_slave");
end

function [0:0] half_of;
    input integer idx;
    begin
        half_of = ((idx / OSO) % 2);
    end
endfunction

endmodule
