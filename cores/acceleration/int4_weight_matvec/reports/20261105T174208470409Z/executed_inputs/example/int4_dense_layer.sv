// SPDX-License-Identifier: Apache-2.0
// Minimal named-port integration: configure once, then submit U8 vectors.
module int4_dense_layer(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [15:0] c_row,c_word,input wire [31:0] c_weights,
 input wire signed [31:0] c_bias,input wire [15:0] c_scale,
 input wire [4:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,input wire [7:0] cmd_x_zero,
 input wire [15:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_row,m_tag,output wire m_last,m_clip,m_inexact,
 output wire [1:0] m_error,output wire busy
);
 int4_weight_matvec #(.MAX_ROWS(8),.MAX_COLS(64),.TAG_W(16)) layer(
  .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
  .c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(c_rsp_valid),
  .c_rsp_ready(c_rsp_ready),.c_error(c_error),.cmd_valid(cmd_valid),
  .cmd_ready(cmd_ready),.cmd_rows(16'd8),.cmd_cols(16'd64),
  .cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),.s_valid(s_valid),.s_ready(s_ready),
  .s_data(s_data),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),
  .m_data(m_data),.m_row(m_row),.m_tag(m_tag),.m_last(m_last),
  .m_clip(m_clip),.m_inexact(m_inexact),.m_error(m_error),.busy(busy));
endmodule
