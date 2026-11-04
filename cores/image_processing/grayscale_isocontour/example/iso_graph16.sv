// SPDX-License-Identifier: Apache-2.0
// Complete ordinary ready/valid grayscale8 -> exact isocontour graph example.
`timescale 1ns/1ps
module iso_graph16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [7:0] s_pixel,s_level,input wire s_sof,s_eol,s_error,
    input wire [7:0] s_tag,output wire m_valid,input wire m_ready,
    output wire m_axis0,output wire [3:0] m_x0,m_y0,
    output wire [8:0] m_num0,m_den0,
    output wire m_axis1,output wire [3:0] m_x1,m_y1,
    output wire [8:0] m_num1,m_den1,
    output wire [8:0] m_index,output wire m_is_summary,m_first,m_last,
    output wire [2:0] m_errors,output wire [7:0] m_tag
);
    grayscale_isocontour #(.WIDTH(16),.HEIGHT(16),.PIXEL_W(8),.TAG_W(8)) core(.*);
endmodule
