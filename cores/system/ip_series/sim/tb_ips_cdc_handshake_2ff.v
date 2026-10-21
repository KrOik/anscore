`timescale 1ns / 1ps
// tb_ips_cdc_handshake_2ff : production-line testbench for the 4-phase crossing.
//
// src_tick is a free-running divisor mod 7 and dst_tick mod 5 on one physical
// clock, which is the series model of two unrelated clocks.  Launches land every
// tenth source tick; takes stop for a long window so the handshake stalls with
// busy set, later launch attempts become collisions that drive err_count
// through its wrap, and the four phase transitions all land in the digest.  The
// payload buses are driven and sampled one bit wider than the shipped DATA_W and
// the counters one bit wider than CNT_W, so both parameter defaults are visible
// and a widened parameter cannot survive the mutation station.  Checks use
// === / !== only (trap T6); models/ips_cdc_handshake_2ff.py folds the same word
// order independently (trap T1).
module tb_ips_cdc_handshake_2ff;

`include "ips_tb_common.vh"

   localparam integer BEATS = 500;
   localparam integer DW = 16;
   localparam integer TW = 17;    // one bit wider than the shipped DATA_W
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

   wire [TW-1:0] o_data_hold, o_data_dst;
   wire          o_req, o_pend, o_busy, o_phase, o_err_sticky;
   wire          o_valid, o_ack, o_req_s1, o_req_s2, o_ack_s1, o_ack_s2;
   wire [CW:0]   o_tx_count, o_rx_count, o_err_count, o_hop_count;   // headroom

   // values as seen during the previous beat, i.e. what this posedge samples
   reg [TW-1:0] hold_p;
   reg          req_p, ack_p, s1_p, a1_p, pend_p;

   ips_cdc_handshake_2ff dut (
      .clk        (ips_clk),
      .clk_en     (clk_en),
      .rst_n      (rst_n),
      .src_tick   (src_tick),
      .dst_tick   (dst_tick),
      .src_start  (src_start),
      .src_data   (src_data),
      .dst_take   (dst_take),
      .data_hold  (o_data_hold),
      .req        (o_req),
      .pend       (o_pend),
      .busy       (o_busy),
      .phase      (o_phase),
      .tx_count   (o_tx_count),
      .err_count  (o_err_count),
      .err_sticky (o_err_sticky),
      .ack_s1     (o_ack_s1),
      .ack_s2     (o_ack_s2),
      .data_dst   (o_data_dst),
      .valid      (o_valid),
      .ack        (o_ack),
      .rx_count   (o_rx_count),
      .hop_count  (o_hop_count),
      .req_s1     (o_req_s1),
      .req_s2     (o_req_s2));

   always @(posedge ips_clk) begin
      if (clk_en === 1'b1) begin
         ips_cycle = ips_cycle + 32'd1;
      end
   end

   // stimulus for beat n, applied at the negedge preceding its posedge
   task drive(input integer n);
      begin
         src_start = ((n % 70) == 21) || ((n >= 330) && ((n % 7) == 0));
         dst_take  = ((n % 5) == 0) && (((n / 5) % 3) == 1) &&
                     !((n >= 320) && (n < 470));
         src_data  = 17'h10000 + n[TW-1:0];
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
      req_p = 1'b0; ack_p = 1'b0; s1_p = 1'b0; a1_p = 1'b0; pend_p = 1'b0;
      #1 rst_n = 1'b1;
      drive(0);
      @(negedge ips_clk);
      clk_en = 1'b1;

      for (i = 0; i < BEATS; i = i + 1) begin
         @(negedge ips_clk);                        // one full step per beat
         if (o_valid !== 1'b0 && o_valid !== 1'b1)   bad = 1'b1;
         if (o_req_s2 !== 1'b0 && o_req_s2 !== 1'b1) bad = 1'b1;
         if (^o_data_dst === 1'bx || ^o_data_hold === 1'bx)     bad = 1'b1;
         // a word on display at the destination is the word still held by the
         // source, and the source cannot have gone idle while it is displayed
         if (o_valid === 1'b1 && o_data_dst !== o_data_hold) bad = 1'b1;
         if (o_valid === 1'b1 && o_busy !== 1'b1)            bad = 1'b1;
         // phase three holds req low until the destination has released ack
         if (o_req === 1'b1 && o_phase === 1'b1)             bad = 1'b1;
         if (src_tick) begin
            // the request only rises one source tick after the bus was written
            if ((o_req !== req_p) && (o_req === 1'b1) &&
                !(pend_p === 1'b1 && o_data_hold === hold_p))           bad = 1'b1;
            // both acknowledge stages only carry the previous value
            if (o_ack_s1 !== ack_p || o_ack_s2 !== a1_p)                bad = 1'b1;
            ips_fnv_word({10'd0, o_pend, o_busy, o_phase, o_req, src_start, o_data_hold});
         end
         if (dst_tick) begin
            if (o_req_s1 !== req_p || o_req_s2 !== s1_p)                bad = 1'b1;
            ips_fnv_word({10'd0, o_valid, o_ack, o_req_s1, o_req_s2, dst_take, o_data_dst});
         end
         ips_fnv_word({27'd0, o_tx_count[CW:0]});
         ips_fnv_word({27'd0, o_rx_count[CW:0]});
         ips_fnv_word({27'd0, o_err_count[CW:0]});
         ips_fnv_word({27'd0, o_hop_count[CW:0]});
         ips_fnv_word({31'd0, o_err_sticky});
         ips_fnv_word({31'd0, o_busy});
         if (bad) begin
            $display("tb_ips_cdc_handshake_2ff FAIL beat %0d: req=%b ack=%b valid=%b phase=%b busy=%b hold=%h dst=%h s1=%b s2=%b a1=%b a2=%b tx=%h rx=%h err=%h hop=%h",
                     i, o_req, o_ack, o_valid, o_phase, o_busy, o_data_hold, o_data_dst,
                     o_req_s1, o_req_s2, o_ack_s1, o_ack_s2,
                     o_tx_count, o_rx_count, o_err_count, o_hop_count);
            ips_verdict(1'b0, "ips_cdc_handshake_2ff");
         end
         req_p  = o_req;
         ack_p  = o_ack;
         s1_p   = o_req_s1;
         a1_p   = o_ack_s1;
         pend_p = o_pend;
         hold_p = o_data_hold;
         if (i != (BEATS - 1)) drive(i + 1);
      end

      clk_en = 1'b0;                                 // freeze the DUT
      @(posedge ips_clk);
      ips_fnv_word(BEATS);
      ips_verdict(!bad, "ips_cdc_handshake_2ff");
   end

endmodule
