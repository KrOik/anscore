// SPDX-License-Identifier: Apache-2.0
// Actual signed8 branch addition with output saturation, boot-configured once.
module signed8_residual #(parameter MAX_PIXELS=256,TAG_W=8)(
 input wire clk,rst,input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_pixels,input wire [TAG_W-1:0] cmd_tag,
 input wire a_valid,output wire a_ready,input wire signed [7:0] a_data,input wire a_last,
 input wire b_valid,output wire b_ready,input wire signed [7:0] b_data,input wire b_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_pixel,output wire m_last,output wire [TAG_W-1:0] m_tag,
 output wire m_clip,m_inexact,output wire rsp_valid,input wire rsp_ready,
 output wire [1:0] rsp_error,output wire [31:0] rsp_outputs,output wire [TAG_W-1:0] rsp_tag
);
 reg [1:0] boot;
 wire cr,cv;wire [1:0] ce;wire child_cmd_ready;
 wire [15:0] ignored_channel;wire bad_a,bad_b,busy;
 always @(posedge clk)begin
  if(rst)boot<=0;
  else if(boot==0 && cr)boot<=1;
  else if(boot==1 && cv)boot<=2;
 end
 assign cmd_ready=boot==2 && child_cmd_ready;
 quantized_residual_add #(.MAX_CHANNELS(1),.MAX_PIXELS(MAX_PIXELS),.TAG_W(TAG_W)) engine(
  .clk(clk),.rst(rst),.c_valid(boot==0),.c_ready(cr),.c_op(2'd0),.c_channel(16'd0),
  .c_scale_a(16'd1),.c_scale_b(16'd1),.c_shift(5'd0),.c_zero_a(8'd128),.c_zero_b(8'd128),
  .c_zero_out(8'sd0),.c_min(-8'sd128),.c_max(8'sd127),.c_rsp_valid(cv),.c_rsp_ready(boot==1),.c_error(ce),
  .cmd_valid(cmd_valid && boot==2),.cmd_ready(child_cmd_ready),.cmd_pixels(cmd_pixels),.cmd_channels(16'd1),.cmd_tag(cmd_tag),
  .a_valid(a_valid),.a_ready(a_ready),.a_data(a_data^8'h80),.a_last(a_last),
  .b_valid(b_valid),.b_ready(b_ready),.b_data(b_data^8'h80),.b_last(b_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_pixel(m_pixel),.m_channel(ignored_channel),.m_last(m_last),
  .m_tag(m_tag),.m_clip(m_clip),.m_inexact(m_inexact),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
  .rsp_error(rsp_error),.rsp_outputs(rsp_outputs),.rsp_tag(rsp_tag),.rsp_bad_a(bad_a),.rsp_bad_b(bad_b),.busy(busy)
 );
endmodule
