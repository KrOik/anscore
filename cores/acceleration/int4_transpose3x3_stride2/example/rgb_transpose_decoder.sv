// SPDX-License-Identifier: Apache-2.0
// RGB24 -> scalar transposed convolution -> RGB24 signed-feature preview.
module rgb_transpose_decoder #(
 parameter MAX_WIDTH=64,MAX_HEIGHT=64,TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [1:0] c_op,input wire [15:0] c_row,c_word,input wire [31:0] c_weights,
 input wire signed [31:0] c_bias,input wire [15:0] c_scale,input wire [4:0] c_shift,
 input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,input wire [15:0] cmd_width,cmd_height,
 input wire [7:0] cmd_x_zero,input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [23:0] s_rgb,input wire s_sof,s_eol,s_last,
 output wire m_valid,input wire m_ready,output reg [23:0] m_rgb,
 output reg [2:0] m_clip,m_inexact,output reg [15:0] m_x,m_y,
 output reg m_sof,m_eol,m_last,output reg [TAG_W-1:0] m_tag,
 output wire rsp_valid,input wire rsp_ready,output reg [2:0] rsp_error,
 output reg [31:0] rsp_pixels,output reg [TAG_W-1:0] rsp_tag
);
 reg active,pixel_owned,out_owned,done_owned;
 reg [23:0] pixel;
 reg pixel_sof,pixel_eol,pixel_last;
 reg [1:0] input_channel,pack_channel;
 reg [15:0] pack_bytes,pack_x,pack_y;
 reg [1:0] pack_clip,pack_inexact;
 reg pack_sof;
 reg [TAG_W-1:0] pack_tag;
 wire child_cmd_ready,child_s_ready,child_m_valid,child_done,child_c_ready;
 wire [7:0] child_data;
 wire child_clip,child_inexact,child_sof,child_eol,child_last;
 wire [15:0] child_x,child_y;
 wire [TAG_W-1:0] child_tag,child_rsp_tag;
 wire [2:0] child_error;
 wire child_m_ready=active && !out_owned && !done_owned;
 assign c_ready=!rst && !active && child_c_ready;
 assign cmd_ready=!rst && !active && child_cmd_ready;
 assign s_ready=!rst && active && !done_owned && !pixel_owned && child_s_ready;
 assign m_valid=!rst && out_owned;
 assign rsp_valid=!rst && done_owned && !pixel_owned && !out_owned && pack_channel==0;
 int4_transpose3x3_stride2 #(.MAX_IN_CHANNELS(3),.MAX_OUT_CHANNELS(3),
  .MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.TAG_W(TAG_W)) core(
  .clk(clk),.rst(rst),.c_valid(c_valid && !active),.c_ready(child_c_ready),
  .c_op(c_op),.c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(c_rsp_valid),
  .c_rsp_ready(c_rsp_ready),.c_error(c_error),
  .cmd_valid(cmd_valid && !active),.cmd_ready(child_cmd_ready),
  .cmd_width(cmd_width),.cmd_height(cmd_height),.cmd_in_channels(16'd3),.cmd_out_channels(16'd3),
  .cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),
  .s_valid(pixel_owned && !done_owned),.s_ready(child_s_ready),
  .s_data(input_channel==0?pixel[23:16]:input_channel==1?pixel[15:8]:pixel[7:0]),
  .s_sof(pixel_sof && input_channel==0),.s_eol(pixel_eol && input_channel==2),
  .s_last(pixel_last && input_channel==2),
  .m_valid(child_m_valid),.m_ready(child_m_ready),.m_data(child_data),
  .m_x(child_x),.m_y(child_y),.m_tag(child_tag),.m_clip(child_clip),.m_inexact(child_inexact),
  .m_sof(child_sof),.m_eol(child_eol),.m_last(child_last),
  .rsp_valid(child_done),.rsp_ready(!done_owned),.rsp_error(child_error),.rsp_tag(child_rsp_tag));
 always @(posedge clk) begin
  if(rst) begin
   active<=0;pixel_owned<=0;out_owned<=0;done_owned<=0;input_channel<=0;pack_channel<=0;
   rsp_pixels<=0;rsp_error<=0;rsp_tag<=0;m_rgb<=0;m_clip<=0;m_inexact<=0;
   m_x<=0;m_y<=0;m_sof<=0;m_eol<=0;m_last<=0;m_tag<=0;
   pixel<=0;pixel_sof<=0;pixel_eol<=0;pixel_last<=0;pack_bytes<=0;
   pack_x<=0;pack_y<=0;pack_clip<=0;pack_inexact<=0;pack_sof<=0;pack_tag<=0;
  end else begin
   if(cmd_valid && cmd_ready) begin active<=1;rsp_pixels<=0;end
   if(s_valid && s_ready) begin
    pixel<=s_rgb;pixel_sof<=s_sof;pixel_eol<=s_eol;pixel_last<=s_last;
    input_channel<=0;pixel_owned<=1;
   end
   if(pixel_owned && !done_owned && child_s_ready) begin
    if(input_channel==2) begin pixel_owned<=0;input_channel<=0;end
    else input_channel<=input_channel+1'b1;
   end
   if(child_m_valid && child_m_ready) begin
    if(pack_channel==0) begin
     pack_bytes[15:8]<=child_data^8'h80;pack_clip[1]<=child_clip;pack_inexact[1]<=child_inexact;
     pack_x<=child_x;pack_y<=child_y;pack_sof<=child_sof;pack_tag<=child_tag;pack_channel<=1;
    end else if(pack_channel==1) begin
     pack_bytes[7:0]<=child_data^8'h80;pack_clip[0]<=child_clip;pack_inexact[0]<=child_inexact;pack_channel<=2;
    end else begin
     m_rgb<={pack_bytes,child_data^8'h80};m_clip<={pack_clip,child_clip};m_inexact<={pack_inexact,child_inexact};
     m_x<=pack_x;m_y<=pack_y;m_sof<=pack_sof;m_tag<=pack_tag;
     m_eol<=child_eol;m_last<=child_last;out_owned<=1;pack_channel<=0;
    end
   end
   if(out_owned && m_ready) begin out_owned<=0;rsp_pixels<=rsp_pixels+1'b1;end
   if(child_done && !done_owned) begin
    done_owned<=1;rsp_error<=child_error;rsp_tag<=child_rsp_tag;
    if(child_error!=0) begin pixel_owned<=0;pack_channel<=0;end
   end
   if(rsp_valid && rsp_ready) begin done_owned<=0;active<=0;end
  end
 end
endmodule
