// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module region_tree8(
    input wire clk,rst,s_valid,input wire [7:0] s_pixel,s_tag,
    input wire s_sof,s_eol,output wire s_ready,m_valid,input wire m_ready,
    output wire [5:0] m_index,m_parent,output wire [7:0] m_level,m_tag,
    output wire m_canonical,output wire [6:0] m_area,
    output wire m_sof,m_eol,m_last,output wire [1:0] m_errors
);
    grayscale_max_tree core(.*);
endmodule
