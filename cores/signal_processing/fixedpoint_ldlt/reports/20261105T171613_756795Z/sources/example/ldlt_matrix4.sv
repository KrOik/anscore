// SPDX-License-Identifier: Apache-2.0
module ldlt_matrix4(
 input wire clk,rst,c_valid, output wire c_ready,
 input wire [31:0] c_dimension,input wire [7:0] c_tag,
 input wire s_valid, output wire s_ready,input wire signed[15:0] s_data,
 output wire m_valid,input wire m_ready,output wire [1:0] m_status,
 output wire [31:0] m_row,m_column,output wire signed[15:0] m_data,
 output wire m_diagonal,m_last,output wire [7:0] m_tag
);
 fixedpoint_ldlt dut(.*);
endmodule
