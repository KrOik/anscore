`timescale 1ns / 1ps
// ips_i2s_rx_slave : I2S stereo receive slave for the ip_series_20k line.
//
// The three receive pins (SCLK, WS/LRCLK, SD) are driven by the testbench as
// explicit levels, one level per `tick`, so the golden model replays every edge
// the synchroniser sees (no board, no bus simulator).
//
// Written contract (models/ips_i2s_rx_slave.py implements the same rules):
//   * Every tick pushes one sample through the pin synchroniser: q1 <= pin,
//     q2 <= q1.  A bit-clock rising edge is q1 & ~q2, a word-select edge is
//     (l1 ^ l2); SD is taken from the q2 tap of its own chain, which is the
//     level the pin held when the edge was recognised.
//   * Each recognised bit-clock edge shifts one SD bit, MSB first, into a
//     WORD_W-deep capture register and advances bit_count.  bit_count saturates
//     at its top value so a run-away clock can never wrap silently.
//   * A word is published (rx_valid set, rx_word latched, rx_chan = the
//     word-select level of the slot being closed, cap_count incremented) as soon
//     as bit_count reaches WORD_W bits.  A publish while the previous word is
//     still pending and not accepted by rx_ready overwrites it and bumps
//     drop_count, saturating at DROP_MAX: that is the dropped-frame counter.
//   * rx_ready together with a pending word consumes it on the same tick, so a
//     consume and a publish in the same tick is not a drop.
//   * At every word-select edge the slot length is checked against SLOT_B:
//     bit_count == SLOT_B is a well framed slot, anything else is a bit slip -
//     slip_sticky is set, slip_count increments and saturates, and bit_count
//     restarts the new slot.
//   * Bit-clock loss is watchdogged separately: TIMEOUT_T ticks without a
//     recognised rising edge set lost_sticky, bump lost_count (saturating) and
//     re-arm the watchdog.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).
module ips_i2s_rx_slave #(
    parameter WORD_W = 16,
    parameter SLOT_B = 17,
    parameter TIMEOUT_T = 40,
    parameter DROP_MAX = 3
)(
    input  wire                     clk,
    input  wire                     clk_en,
    input  wire                     rst_n,

    input  wire                     tick,
    input  wire                     sclk_i,
    input  wire                     lrclk_i,
    input  wire                     sd_i,
    input  wire                     rx_ready,

    output reg signed [WORD_W-1:0]  rx_word,
    output reg                      rx_valid,
    output reg                      rx_chan,
    output reg  [5:0]               bit_count,
    output reg  [7:0]               cap_count,
    output reg  [7:0]               drop_count,
    output reg  [3:0]               slip_count,
    output reg  [3:0]               lost_count,
    output reg                      slip_sticky,
    output reg                      lost_sticky,
    output reg                      sclk_q,
    output reg                      lrclk_q
);

reg               sclk_q1;
reg               sclk_q2;
reg               lrclk_q1;
reg               lrclk_q2;
reg               sd_q1;
reg               sd_q2;
reg [WORD_W-1:0]  cap;
reg [7:0]         idle_cnt;

wire [5:0] cnt_top = {6{1'b1}};
wire       rise    = sclk_q1 & ~sclk_q2;
wire       ws_edge = lrclk_q1 ^ lrclk_q2;
wire [WORD_W-1:0] cap_next = {cap[WORD_W-2:0], sd_q2};
wire [5:0] cnt_next = rise ? ((bit_count == cnt_top) ? cnt_top : (bit_count + 6'd1))
                           : bit_count;
wire       take      = rx_valid & rx_ready;
wire       still     = rx_valid & ~take;
wire [WORD_W-1:0] done_word = rise ? cap_next : cap;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_word     <= {WORD_W{1'b0}};
        rx_valid    <= 1'b0;
        rx_chan     <= 1'b0;
        bit_count   <= 6'd0;
        cap_count   <= 8'h00;
        drop_count  <= 8'h00;
        slip_count  <= 4'h0;
        lost_count  <= 4'h0;
        slip_sticky <= 1'b0;
        lost_sticky <= 1'b0;
        sclk_q      <= 1'b0;
        lrclk_q     <= 1'b0;
        sclk_q1     <= 1'b0;
        sclk_q2     <= 1'b0;
        lrclk_q1    <= 1'b0;
        lrclk_q2    <= 1'b0;
        sd_q1       <= 1'b0;
        sd_q2       <= 1'b0;
        cap         <= {WORD_W{1'b0}};
        idle_cnt    <= 8'h00;
    end else if (clk_en) begin
        if (tick) begin
            sclk_q1  <= sclk_i;
            lrclk_q1 <= lrclk_i;
            sd_q1    <= sd_i;
            sclk_q2  <= sclk_q1;
            lrclk_q2 <= lrclk_q1;
            sd_q2    <= sd_q1;
            sclk_q   <= sclk_i;
            lrclk_q  <= lrclk_i;

            if (take) begin
                rx_valid <= 1'b0;
            end

            if (rise) begin
                cap <= cap_next;
            end

            if (cnt_next == WORD_W) begin
                if (still) begin
                    if (drop_count < DROP_MAX) begin
                        drop_count <= drop_count + 8'h01;
                    end
                end
                rx_word <= done_word;
                rx_chan <= lrclk_q2;
                rx_valid <= 1'b1;
                if (cap_count != 8'hFF) begin
                    cap_count <= cap_count + 8'h01;
                end
            end

            if (ws_edge) begin
                if (cnt_next != SLOT_B) begin
                    slip_sticky <= 1'b1;
                    if (slip_count != 4'hF) begin
                        slip_count <= slip_count + 4'h1;
                    end
                end
                bit_count <= 6'd0;
            end else if (rise) begin
                bit_count <= cnt_next;
            end

            if (rise) begin
                idle_cnt <= 8'h00;
            end else if (idle_cnt >= TIMEOUT_T) begin
                idle_cnt    <= 8'h00;
                lost_sticky <= 1'b1;
                if (lost_count != 4'hF) begin
                    lost_count <= lost_count + 4'h1;
                end
            end else begin
                idle_cnt <= idle_cnt + 8'h01;
            end
        end
    end
end

endmodule
