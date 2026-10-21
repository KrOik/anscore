`timescale 1ns / 1ps
// tb_ips_cdc_toggle_sync : production-line testbench for the toggle handshaker.
//
// src_tick is a free-running divisor mod 7 and dst_tick mod 5 on one physical
// clock, which is the series model of two unrelated clocks.  Launch attempts
// land every sixth source tick; once a transfer is outstanding and no take
// follows, the later attempts are collisions that drive err_count through its
// wrap.  Every check uses === / !== (trap T6) and the request/payload ordering
// is asserted so a violation of trap T13 cannot pass silently.  The counters
// are sampled one bit wide than the port so a widened CNT_W reaches the digest.
// The payload bus is driven and sampled one bit wider than the shipped DATA_W,
// so a widened DATA_W also reaches the digest instead of surviving as an
// equivalent mutant.  models/ips_cdc_toggle_sync.py folds the same word order
// independently.
module tb_ips_cdc_toggle_sync;

`include "ips_tb_common.vh"

   localparam integer BEATS = 600;
   localparam integer DW = 12;
   localparam integer TW = 13;    // one bit wider than the shipped DATA_W
   localparam integer CW = 4;

   integer i;
   reg     bad;

   wire src_tick = ((i % 7) == 0);
   wire dst_tick = ((i % 5) == 0);

   reg  rst_n;
   reg  clk_en;
   reg  src_start;
   reg  dst_take;
   reg  [TW-1:0] src_data;

   wire [TW-1:0] o_data_hold, o_dst_data;
   wire          o_tog_src, o_outstanding, o_pend;
   wire          o_dst_valid, o_ack_tog, o_tog_s1, o_tog_s2;
   wire          o_ack_s1, o_ack_s2, o_err_sticky;
   wire [CW:0]   o_tx_count, o_rx_count, o_err_count;   // headroom

   // values as seen during the previous beat, i.e. what this posedge samples
   reg [TW-1:0] hold_p;
   reg          ts_p, s1_p, at_p, a1_p, pend_p;

   ips_cdc_toggle_sync dut (
      .clk        (ips_clk),
      .clk_en     (clk_en),
      .rst_n      (rst_n),
      .src_tick   (src_tick),
      .dst_tick   (dst_tick),
      .src_start  (src_start),
      .src_data   (src_data),
      .dst_take   (dst_take),
      .data_hold  (o_data_hold),
      .tog_src    (o_tog_src),
      .outstanding(o_outstanding),
      .pend       (o_pend),
      .tx_count   (o_tx_count),
      .rx_count   (o_rx_count),
      .err_count  (o_err_count),
      .err_sticky (o_err_sticky),
      .dst_data   (o_dst_data),
      .dst_valid  (o_dst_valid),
      .ack_tog    (o_ack_tog),
      .tog_s1     (o_tog_s1),
      .tog_s2     (o_tog_s2),
      .ack_s1     (o_ack_s1),
      .ack_s2     (o_ack_s2));

   always @(posedge ips_clk) begin
      if (clk_en === 1'b1) begin
         ips_cycle = ips_cycle + 32'd1;
      end
   end

   // stimulus for beat n, applied at the negedge preceding its posedge
   task drive(input integer n);
      begin
         src_start = ((n % 42) == 21) || ((n >= 399) && (n <= 553) && ((n % 7) == 0));
         dst_take  = ((n % 5) == 0) && (n < 360) && (((n / 5) % 2) == 1);
         src_data  = 13'h1000 + n[TW-1:0];
      end
   endtask

   initial begin
      ips_fnv_reset();
      bad = 1'b0;
      rst_n = 1'b0;
      clk_en = 1'b0;
      src_start = 1'b0;
      dst_take = 1'b0;
      src_data = {TW{1'b0}};
      hold_p = {TW{1'b0}};
      ts_p = 1'b0; s1_p = 1'b0; at_p = 1'b0; a1_p = 1'b0; pend_p = 1'b0;
      #1 rst_n = 1'b1;
      drive(0);
      @(negedge ips_clk);
      clk_en = 1'b1;

      for (i = 0; i < BEATS; i = i + 1) begin
         @(negedge ips_clk);                        // one full step per beat
         if (o_dst_valid !== 1'b0 && o_dst_valid !== 1'b1) bad = 1'b1;
         if (o_tog_s2 !== 1'b0 && o_tog_s2 !== 1'b1)       bad = 1'b1;
         if (src_tick) begin
            // both source-side acknowledge stages only carry the previous value
            if (o_ack_s1 !== at_p || o_ack_s2 !== a1_p)                 bad = 1'b1;
            // the request toggle flips one tick after the bus was written,
            // and never in the same tick as a new payload (trap T13)
            if ((o_tog_src !== ts_p) && !(pend_p === 1'b1 && o_data_hold === hold_p)) bad = 1'b1;
            ips_fnv_word({16'd0, o_pend, o_tog_src, src_start, o_data_hold});
         end
         if (dst_tick) begin
            if (o_tog_s1 !== ts_p || o_tog_s2 !== s1_p)                 bad = 1'b1;
            // the captured payload must be the whole held bus, never partial
            if (o_dst_valid !== 1'b0 && o_dst_data !== hold_p)          bad = 1'b1;
            ips_fnv_word({18'd0, o_dst_valid, o_dst_data});
            ips_fnv_word({26'd0, o_ack_tog, o_tog_s1, o_tog_s2,
                          o_ack_s1, o_ack_s2, dst_take});
         end
         ips_fnv_word({27'd0, o_tx_count[CW:0]});
         ips_fnv_word({27'd0, o_rx_count[CW:0]});
         ips_fnv_word({27'd0, o_err_count[CW:0]});
         ips_fnv_word({31'd0, o_err_sticky});
         ips_fnv_word({31'd0, o_outstanding});
         if (bad) begin
            $display("tb_ips_cdc_toggle_sync FAIL beat %0d: dst_valid=%b dst_data=%h hold=%h s1=%b s2=%b a1=%b a2=%b tx=%h rx=%h err=%h",
                     i, o_dst_valid, o_dst_data, hold_p, o_tog_s1, o_tog_s2,
                     o_ack_s1, o_ack_s2, o_tx_count, o_rx_count, o_err_count);
            ips_verdict(1'b0, "ips_cdc_toggle_sync");
         end
         ts_p   = o_tog_src;
         s1_p   = o_tog_s1;
         at_p   = o_ack_tog;
         a1_p   = o_ack_s1;
         pend_p = o_pend;
         hold_p = o_data_hold;
         if (i != (BEATS - 1)) drive(i + 1);
      end

      clk_en = 1'b0;                                 // freeze the DUT
      @(posedge ips_clk);
      ips_fnv_word(BEATS);
      ips_verdict(!bad, "ips_cdc_toggle_sync");
   end

endmodule
