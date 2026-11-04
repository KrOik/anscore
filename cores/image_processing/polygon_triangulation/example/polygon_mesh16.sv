// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module polygon_mesh16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [7:0] s_x,s_y,input wire s_keep,s_last,s_error,
    input wire [7:0] s_tag,output wire m_valid,input wire m_ready,
    output wire [3:0] m_id0,m_id1,m_id2,
    output wire signed [7:0] m_x0,m_y0,m_x1,m_y1,m_x2,m_y2,
    output wire [4:0] m_vertices,m_count,output wire [3:0] m_index,m_error,
    output wire m_first,m_last,output wire [7:0] m_tag
);
    polygon_triangulation core(.*);
endmodule
