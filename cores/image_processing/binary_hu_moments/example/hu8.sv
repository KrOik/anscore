// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module hu8(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire s_pixel,s_sof,s_eol,s_bad,input wire [7:0] s_tag,
 output wire m_valid,input wire m_ready,
 output wire signed [116:0] m_numerator,output wire [116:0] m_denominator,
 output wire [2:0] m_index,output wire m_keep,m_last,output wire [3:0] m_errors,
 output wire [6:0] m_area,output wire [7:0] m_tag
);
 binary_hu_moments #(.WIDTH(8),.HEIGHT(8),.TAG_W(8)) core(.*);
endmodule
