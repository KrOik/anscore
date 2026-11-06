// SPDX-License-Identifier: Apache-2.0
// One signed32 prefix quantizer slot before the resident ReGLU projection.
module reglu32_input #(
 parameter MAX_HIDDEN=4,MAX_COLS=16,TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [2:0] c_op,input wire c_branch,
 input wire [15:0] c_row,c_word,input wire [31:0] c_weights,input wire signed [31:0] c_bias,
 input wire [15:0] c_scale,input wire [4:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,input wire [15:0] cmd_hidden,cmd_cols,
 input wire [4:0] cmd_input_shift,input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire signed [31:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_index,output wire [TAG_W-1:0] m_tag,
 output wire m_last,m_clip,m_inexact,m_project_clip,m_project_inexact,m_gate_closed,
 output wire m_input_clip,m_input_inexact,output wire [2:0] m_error,output wire busy
);
 reg owner,pending,input_clip,input_inexact;
 reg [4:0] shift;
 wire q_ready,q_valid,q_last,q_clip,q_inexact,core_ready;
 wire [7:0] q_data;
 wire prefix_offer=owner && !pending && core_ready && s_valid;
 assign s_ready=!rst && owner && !pending && core_ready && q_ready;
 assign m_input_clip=input_clip;
 assign m_input_inexact=input_inexact;
 stream_requantize #(.IN_W(32),.OUT_W(8),.TAG_W(1)) prefix_quant(
  .clk(clk),.rst(rst),.s_valid(prefix_offer),.s_ready(q_ready),.s_data(s_data),.s_shift({1'b0,shift}),.s_tag(s_last),
  .m_valid(q_valid),.m_ready(core_ready),.m_data(q_data),.m_clip(q_clip),.m_inexact(q_inexact),.m_tag(q_last));
 int4_reglu #(.MAX_HIDDEN(MAX_HIDDEN),.MAX_COLS(MAX_COLS),.TAG_W(TAG_W)) core(
  .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_branch(c_branch),
  .c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
  .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
  .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_hidden(cmd_hidden),.cmd_cols(cmd_cols),.cmd_x_zero(8'd128),.cmd_tag(cmd_tag),
  .s_valid(q_valid),.s_ready(core_ready),.s_data({~q_data[7],q_data[6:0]}),.s_last(q_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_index(m_index),.m_tag(m_tag),.m_last(m_last),
  .m_clip(m_clip),.m_inexact(m_inexact),.m_project_clip(m_project_clip),.m_project_inexact(m_project_inexact),
  .m_gate_closed(m_gate_closed),.m_error(m_error),.busy(busy));
 always @(posedge clk)begin
  if(rst)begin owner<=0;pending<=0;input_clip<=0;input_inexact<=0;shift<=0;end
  else begin
   if(cmd_valid && cmd_ready)begin owner<=1;input_clip<=0;input_inexact<=0;shift<=cmd_input_shift;end
   if(s_valid && s_ready)pending<=1;
   if(q_valid && core_ready)begin pending<=0;input_clip<=input_clip || q_clip;input_inexact<=input_inexact || q_inexact;end
   if(m_valid && m_ready && m_last)owner<=0;
  end
 end
endmodule
