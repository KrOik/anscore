// SPDX-License-Identifier: Apache-2.0
// Actual boot-configured 3-channel, one-hidden-neuron frame recalibration.
`default_nettype none
module rgb_channel_excitation #(
 parameter MAX_PIXELS=256,TAG_W=8
)(
 input wire clk,rst,
 input wire cmd_valid,output wire cmd_ready,input wire [15:0] cmd_pixels,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire signed [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_pixel,m_channel,output wire [8:0] m_gate,
 output wire m_last,output wire [TAG_W-1:0] m_tag,
 output wire m_inexact,m_mean_inexact,m_projection_clip,m_projection_inexact,
 output wire m_gate_inexact,m_gate_clamped,
 output wire rsp_valid,input wire rsp_ready,output wire [2:0] rsp_error,
 output wire [1:0] rsp_stage,rsp_child_error,output wire [23:0] rsp_inputs,rsp_outputs,
 output wire [TAG_W-1:0] rsp_tag,output reg boot_fault,output wire busy
);
 reg [3:0] boot_index;
 reg boot_wait,boot_done;
 wire cfg_ready,cfg_response,core_cmdready;
 wire [1:0] cfg_error;
 wire bank=boot_index>=2;
 wire [15:0] row=bank?((boot_index-4'd2)>>1):16'd0;
 wire [31:0] weights=boot_index==0?32'h00000111:
                         boot_index==2?32'h0000000f:boot_index==6?32'h00000001:32'd0;
 assign cmd_ready=boot_done && !boot_fault && core_cmdready && !rst;
 int4_squeeze_excite_frame #(.MAX_CHANNELS(3),.MAX_HIDDEN(1),.MAX_PIXELS(MAX_PIXELS),.TAG_W(TAG_W)) core(
  .clk(clk),.rst(rst),.c_valid(!boot_done && !boot_wait && !boot_fault && !rst),.c_ready(cfg_ready),
  .c_bank(bank),.c_op({1'b0,boot_index[0]}),.c_row(row),.c_word(16'd0),
  .c_weights(weights),.c_bias(32'sd0),.c_scale(16'd1),.c_shift(5'd0),.c_zero(8'sd0),
  .c_rsp_valid(cfg_response),.c_rsp_ready(!boot_done && boot_wait),.c_error(cfg_error),
  .cmd_valid(cmd_valid && boot_done && !boot_fault && !rst),.cmd_ready(core_cmdready),
  .cmd_pixels(cmd_pixels),.cmd_channels(16'd3),.cmd_hidden(16'd1),.cmd_tag(cmd_tag),
  .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_pixel(m_pixel),.m_channel(m_channel),
  .m_gate(m_gate),.m_last(m_last),.m_tag(m_tag),.m_inexact(m_inexact),
  .m_mean_inexact(m_mean_inexact),.m_projection_clip(m_projection_clip),.m_projection_inexact(m_projection_inexact),
  .m_gate_inexact(m_gate_inexact),.m_gate_clamped(m_gate_clamped),
  .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),.rsp_stage(rsp_stage),
  .rsp_child_error(rsp_child_error),.rsp_inputs(rsp_inputs),.rsp_outputs(rsp_outputs),.rsp_tag(rsp_tag),.busy(busy));
 always @(posedge clk)begin
  if(rst)begin boot_index<=0;boot_wait<=0;boot_done<=0;boot_fault<=0;end
  else if(!boot_done && !boot_fault)begin
   if(!boot_wait && cfg_ready)boot_wait<=1;
   if(boot_wait && cfg_response)begin
    boot_wait<=0;
    if(cfg_error!=0)boot_fault<=1;
    else if(boot_index==7)boot_done<=1;
    else boot_index<=boot_index+1'b1;
   end
  end
 end
endmodule
`default_nettype wire
