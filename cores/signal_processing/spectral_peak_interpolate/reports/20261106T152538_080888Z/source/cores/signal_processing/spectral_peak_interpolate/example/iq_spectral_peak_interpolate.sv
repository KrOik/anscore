// SPDX-License-Identifier: Apache-2.0
// Natural-order complex FFT bins, not time-domain samples.
module iq_spectral_peak_interpolate #(
 parameter integer MAX_LOG2N=8,TAG_W=8
)(
 input wire clk,rst,input wire c_valid,output wire c_ready,
 input wire [31:0] c_log2n,c_low,c_high,c_min_power,input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [31:0] s_iq,input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,output wire [2:0] m_status,
 output wire [TAG_W-1:0] m_tag,output wire [31:0] m_log2n,m_low,m_high,m_min_power,
 output wire [12:0] m_received,output wire [31:0] m_peak_index,m_left,m_center,m_right,
 output wire signed [33:0] m_curvature,output wire signed [17:0] m_offset_q16,
 output wire [31:0] m_bin_q16,output wire m_interp_valid
);
 reg support_n;reg [12:0] input_left;
 reg [3:0] last_pipe,invalid_pipe;
 wire power_valid,power_ready,iq_ready,power_clip,cfg_ready,cfg_done,cfg_error;
 wire [31:0] power;
 wire advance=!power_valid || power_ready;
 wire input_fire=s_valid && s_ready;
 wire iq_valid=!rst && s_valid && input_left!=0 && power_ready;
 assign s_ready=!rst && support_n && input_left!=0 && power_ready && iq_ready;
 always @(posedge clk)begin
  if(rst)begin support_n<=0;input_left<=0;last_pipe<=0;invalid_pipe<=0;end
  else begin
   support_n<=1;
   if(c_valid && c_ready)
    input_left<=(c_log2n>=4 && c_log2n<=MAX_LOG2N && c_low>=1 && c_low<=c_high &&
      c_high<=((32'd1<<c_log2n)-2))?(13'd1<<c_log2n):13'd0;
   else if(input_fire)input_left<=(s_last || s_invalid)?13'd0:input_left-1'b1;
   if(advance)begin
    last_pipe<={last_pipe[2:0],input_fire && s_last};
    invalid_pipe<={invalid_pipe[2:0],input_fire && s_invalid};
   end
  end
 end
 mag_squared magnitude(.clk(clk),.rst_n(support_n),.s_tdata(s_iq),.s_tvalid(iq_valid),.s_tready(iq_ready),
  .m_tdata(power),.m_tuser(power_clip),.m_tvalid(power_valid),.m_tready(power_ready),
  .cfg_valid(1'b0),.cfg_ready(cfg_ready),.cfg_shift(5'd0),.cfg_done(cfg_done),.cfg_error(cfg_error));
 spectral_peak_interpolate #(.MAX_LOG2N(MAX_LOG2N),.TAG_W(TAG_W)) instrument(
  .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_log2n(c_log2n),.c_low(c_low),
  .c_high(c_high),.c_min_power(c_min_power),.c_tag(c_tag),.s_valid(power_valid),.s_ready(power_ready),
  .s_power(power),.s_last(last_pipe[3]),.s_invalid(invalid_pipe[3] || power_clip),
  .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_log2n(m_log2n),
  .m_low(m_low),.m_high(m_high),.m_min_power(m_min_power),.m_received(m_received),
  .m_peak_index(m_peak_index),.m_left(m_left),.m_center(m_center),.m_right(m_right),
  .m_curvature(m_curvature),.m_offset_q16(m_offset_q16),.m_bin_q16(m_bin_q16),.m_interp_valid(m_interp_valid));
endmodule
