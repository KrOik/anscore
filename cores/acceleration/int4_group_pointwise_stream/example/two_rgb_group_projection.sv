// SPDX-License-Identifier: Apache-2.0
// Two centered RGB views -> interleaved luma/opponent features, packed per pixel.
module two_rgb_group_projection #(parameter MAX_PIXELS=64,TAG_W=8)(
 input wire clk,rst,
 input wire cmd_valid,output wire cmd_ready,input wire [15:0] cmd_pixels,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [47:0] s_rgb,input wire s_last,
 output wire m_valid,input wire m_ready,output wire [31:0] m_features,
 output wire m_last,output wire [TAG_W-1:0] m_tag,
 output wire rsp_valid,input wire rsp_ready,output wire [1:0] rsp_error,
 output wire [31:0] rsp_outputs,output wire [TAG_W-1:0] rsp_tag
);
 localparam BOOT_SEND=0,BOOT_ACK=1,READY=2;
 reg [1:0] boot_state;
 reg [1:0] boot_row;
 reg boot_meta,active,input_full,output_full;
 reg [15:0] accepted_pixels,pixels;
 reg [2:0] input_index;
 reg [47:0] input_q;
 reg input_last;
 reg [31:0] output_q;
 reg output_last;
 reg [TAG_W-1:0] output_tag;
 wire cfg_ready,cfg_valid,core_cmd_ready,core_s_ready,core_m_valid,core_rsp_valid;
 wire [1:0] cfg_error;
 wire [7:0] core_data;
 wire [15:0] core_pixel,core_channel,core_group,core_row;
 wire core_last,core_clip,core_inexact,core_busy;
 wire [TAG_W-1:0] core_tag;
 wire core_rsp_ready=rsp_ready && !output_full;
 wire accepted_command=cmd_valid && cmd_ready;
 assign cmd_ready=!rst && boot_state==READY && !active && core_cmd_ready;
 assign s_ready=!rst && active && !input_full && accepted_pixels<pixels && !core_rsp_valid;
 assign m_valid=!rst && output_full;
 assign m_features=output_q;assign m_last=output_last;assign m_tag=output_tag;
 assign rsp_valid=!rst && core_rsp_valid && !output_full;
 int4_group_pointwise_stream #(.GROUPS(2),.MAX_IN_PER_GROUP(3),.MAX_OUT_PER_GROUP(2),
  .MAX_PIXELS(MAX_PIXELS),.TAG_W(TAG_W)) projection(
  .clk(clk),.rst(rst),.c_valid(boot_state==BOOT_SEND),.c_ready(cfg_ready),
  .c_op(boot_meta?2'd1:2'd0),.c_group({15'd0,boot_row[1]}),.c_row({15'd0,boot_row[0]}),
  .c_word(16'd0),.c_weights(boot_row[0]?32'h000000f1:32'h00000142),
  .c_bias(32'sd0),.c_scale(16'd1),.c_shift(boot_row[0]?5'd0:5'd3),.c_zero(8'sd0),
  .c_rsp_valid(cfg_valid),.c_rsp_ready(boot_state==BOOT_ACK),.c_error(cfg_error),
  .cmd_valid(cmd_valid && boot_state==READY && !active),.cmd_ready(core_cmd_ready),
  .cmd_pixels(cmd_pixels),.cmd_in_per_group(16'd3),.cmd_out_per_group(16'd2),
  .cmd_x_zero(8'd128),.cmd_shuffle(1'b1),.cmd_tag(cmd_tag),
  .s_valid(input_full),.s_ready(core_s_ready),.s_data(input_q[input_index*8+:8]),
  .s_last(input_last && input_index==5),
  .m_valid(core_m_valid),.m_ready(!output_full),.m_data(core_data),
  .m_pixel(core_pixel),.m_channel(core_channel),.m_group(core_group),.m_row(core_row),
  .m_last(core_last),.m_tag(core_tag),.m_clip(core_clip),.m_inexact(core_inexact),
  .rsp_valid(core_rsp_valid),.rsp_ready(core_rsp_ready),.rsp_error(rsp_error),
  .rsp_outputs(rsp_outputs),.rsp_tag(rsp_tag),.busy(core_busy)
 );
 always @(posedge clk)begin
  if(rst)begin
   boot_state<=BOOT_SEND;boot_row<=0;boot_meta<=0;active<=0;
   input_full<=0;output_full<=0;accepted_pixels<=0;pixels<=0;input_index<=0;
  end else begin
   if(boot_state==BOOT_SEND && cfg_ready)boot_state<=BOOT_ACK;
   if(boot_state==BOOT_ACK && cfg_valid)begin
    if(!boot_meta)begin boot_meta<=1;boot_state<=BOOT_SEND;end
    else if(boot_row==3)boot_state<=READY;
    else begin boot_row<=boot_row+1'b1;boot_meta<=0;boot_state<=BOOT_SEND;end
   end
   if(accepted_command)begin active<=1;pixels<=cmd_pixels;accepted_pixels<=0;end
   if(s_valid && s_ready)begin
    input_q<=s_rgb;input_last<=s_last;input_full<=1;input_index<=0;
    accepted_pixels<=accepted_pixels+1'b1;
   end
   if(input_full && core_s_ready)begin
    if(input_index==5)begin input_full<=0;input_index<=0;end
    else input_index<=input_index+1'b1;
   end
   if(output_full && m_ready)output_full<=0;
   if(core_m_valid && !output_full)begin
    output_q[core_channel[1:0]*8+:8]<=core_data;
    if(core_channel==3)begin output_full<=1;output_last<=core_last;output_tag<=core_tag;end
   end
   if(core_rsp_valid && core_rsp_ready)begin active<=0;input_full<=0;end
  end
 end
endmodule
