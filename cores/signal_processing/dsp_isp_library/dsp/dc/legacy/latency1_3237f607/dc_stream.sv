// Synchronous reset, signed Q1.15; details and quantization in ../SPEC.md.
module dc_stream (
 input wire clk, rst_n,
 input wire signed [15:0] s_tdata, input wire s_tvalid, output wire s_tready,
 output reg [31:0] m_tdata, output reg m_tvalid, input wire m_tready,
 input wire cfg_valid, output wire cfg_ready,
 input wire [1:0] cfg_mode, input wire [15:0] cfg_pole,
 input wire [3:0] cfg_window_log2,
 output reg cfg_done, cfg_error
);
 reg [1:0] mode;
 reg [15:0] pole;
 reg [3:0] lg;
 reg signed [15:0] previous_x;
 reg signed [33:0] state;
 reg signed [25:0] total;
 reg [7:0] ptr;
 reg [8:0] count;
 wire [8:0] length = 9'd1 << lg;
 wire [7:0] next_ptr = (ptr == length-1) ? 8'd0 : ptr+1'b1;
 assign cfg_ready = rst_n && !m_tvalid;
 assign s_tready = rst_n && !cfg_valid && (!m_tvalid || m_tready);
 wire accept = s_tvalid && s_tready;
 // Synchronous read-ahead; no RAM reset. Count masks unwritten history.
 reg signed [15:0] ring [0:255];
 reg signed [15:0] oldest;
 wire [7:0] rdaddr = accept ? next_ptr : ptr;
 always @(posedge clk) begin
   oldest <= ring[rdaddr];
   if (accept && mode == 1) ring[ptr] <= s_tdata;
 end
 function signed [63:0] round_even;
   input signed [63:0] value;
   input integer shift;
   reg [63:0] magnitude, quotient, remainder, half;
   begin
     magnitude = value < 0 ? -value : value;
     quotient = magnitude >> shift;
     remainder = magnitude & ((64'd1 << shift)-1);
     half = shift == 0 ? 0 : 64'd1 << (shift-1);
     if (shift != 0 && ((remainder > half) ||
         (remainder == half && quotient[0]))) quotient = quotient+1;
     round_even = value < 0 ? -$signed(quotient) : $signed(quotient);
   end
 endfunction
 // Floor quotient plus nonnegative low-bit remainder gives signed ties-even
 // without magnitude negation. Mean numerators fit signed 26 bits for N<=256.
 function signed [25:0] mean_round;
   input signed [25:0] value;
   input [3:0] shift;
   reg signed [25:0] q;
   reg [25:0] rem, half;
   begin
     q=value >>> shift;
     rem=$unsigned(value) & ((26'd1 << shift)-1);
     half=0;
     if(shift!=0) begin
       half=26'd1 << (shift-1);
       if(rem>half || (rem==half && q[0])) q=q+26'sd1;
     end
     mean_round=q;
   end
 endfunction
 function [15:0] sat;
   input signed [63:0] value;
   begin
     if (value > 32767) sat=16'h7fff;
     else if (value < -32768) sat=16'h8000;
     else sat=value[15:0];
   end
 endfunction
 reg signed [63:0] xwide, state_next, y, b, feedback, weighted;
 reg signed [25:0] mean_sum, mean_num, mean_x;
 always @* begin
   xwide = {{48{s_tdata[15]}},s_tdata};
   feedback = $signed({1'b0,pole}) * state;
   weighted = $signed(18'd65536-{2'b0,pole}) * xwide;
   mean_x={{10{s_tdata[15]}},s_tdata};
   mean_sum=total+mean_x;
   if(count>=length) mean_sum=mean_sum-$signed({{10{oldest[15]}},oldest});
   if(lg==0) mean_sum=mean_x;
   mean_num=(mean_x <<< lg)-mean_sum;
   state_next = state;
   y=0; b=0;
   case (mode)
     0: begin
       state_next = ((xwide-previous_x) <<< 16) + round_even(feedback,16);
       y=round_even(state_next,16);
       b=round_even((xwide <<< 16)-state_next,16);
     end
     1: begin
       if(lg==0) begin y=0; b=xwide; end
       else begin y=mean_round(mean_num,lg); b=mean_round(mean_sum,lg); end
     end
     2: begin
       state_next=round_even(feedback+(weighted <<< 16),16);
       b=round_even(state_next,16);
       y=round_even((xwide <<< 16)-state_next,16);
     end
   endcase
 end
 always @(posedge clk) begin
   if (!rst_n) begin
     mode<=0; pole<=65024; lg<=4;
     state<=0; previous_x<=0; total<=0; ptr<=0; count<=0;
     m_tvalid<=0; m_tdata<=0; cfg_done<=0; cfg_error<=0;
   end else begin
     cfg_done<=0; cfg_error<=0;
     if (m_tready) m_tvalid<=0;
     if (cfg_valid && cfg_ready) begin
       cfg_done<=1;
       if (cfg_mode == 3 || cfg_window_log2 > 8) cfg_error<=1;
       else begin
         mode<=cfg_mode; pole<=cfg_pole; lg<=cfg_window_log2;
         state<=0; previous_x<=0; total<=0; ptr<=0; count<=0;
       end
     end
     if (accept) begin
       m_tdata<={sat(b),sat(y)}; m_tvalid<=1;
       state<=state_next[33:0]; previous_x<=s_tdata;
       if (mode == 1) begin
         total<=mean_sum; ptr<=next_ptr;
         if (count < length) count<=count+1'b1;
       end
     end
   end
 end
endmodule
