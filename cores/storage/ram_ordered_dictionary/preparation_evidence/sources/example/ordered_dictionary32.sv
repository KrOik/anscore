// SPDX-License-Identifier: Apache-2.0
// Ordinary ready/valid. Every functional port is exposed, with default widths.
module ordered_dictionary32(
 input wire clk,rst_n,s_valid, output wire s_ready,
 input wire [2:0] s_op,input wire [31:0] s_key,s_value,s_hi,
 output wire m_valid,input wire m_ready,
 output wire [1:0] m_kind,output wire [2:0] m_status,output wire m_found,
 output wire [31:0] m_key,m_value,output wire [5:0] m_count
);
 ram_ordered_dictionary #(.CAPACITY(32),.K_W(32),.V_W(32)) u_dictionary(
  .clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_ready(s_ready),
  .s_op(s_op),.s_key(s_key),.s_value(s_value),.s_hi(s_hi),
  .m_valid(m_valid),.m_ready(m_ready),.m_kind(m_kind),.m_status(m_status),
  .m_found(m_found),.m_key(m_key),.m_value(m_value),.m_count(m_count));
endmodule
