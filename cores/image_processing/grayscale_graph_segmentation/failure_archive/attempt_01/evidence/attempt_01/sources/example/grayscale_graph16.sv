// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module grayscale_graph16 (
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire [7:0] s_pixel,
    input wire s_sof,s_eol,s_last,
    input wire [15:0] s_k,
    input wire [8:0] s_min_size,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire m_keep,
    output wire [7:0] m_index,m_label,
    output wire [8:0] m_area,m_regions,
    output wire m_sof,m_eol,m_last,
    output wire [3:0] m_errors,
    output wire [7:0] m_tag
);
    grayscale_graph_segmentation #(.WIDTH(16),.HEIGHT(16),.TAG_W(8)) u_core (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),
        .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_k(s_k),.s_min_size(s_min_size),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_keep(m_keep),.m_index(m_index),.m_label(m_label),
        .m_area(m_area),.m_regions(m_regions),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
        .m_errors(m_errors),.m_tag(m_tag));
endmodule
