`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// An ordered contour/trajectory frontend: one kept input vertex per handshake.
// Close a contour explicitly by repeating its first vertex at s_last if desired.
module contour_simplify_example #(
    parameter integer COORD_W=12,MAX_POINTS=32,TAG_W=8,
    localparam integer IW=(MAX_POINTS>1)?$clog2(MAX_POINTS):1,
    localparam integer CW=$clog2(MAX_POINTS+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_last,
    input wire [COORD_W-1:0] epsilon,
    input wire [TAG_W-1:0] tag,
    output wire m_valid,input wire m_ready,
    output wire signed [COORD_W-1:0] m_x,m_y,
    output wire [IW-1:0] m_index,
    output wire [CW-1:0] m_count,
    output wire m_first,m_last,m_empty,m_error,
    output wire [TAG_W-1:0] m_tag
);
    polyline_rdp #(.COORD_W(COORD_W),.MAX_POINTS(MAX_POINTS),.TAG_W(TAG_W)) core(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_x(s_x),.s_y(s_y),.s_keep(1'b1),.s_last(s_last),
        .s_epsilon(epsilon),.s_tag(tag),.m_valid(m_valid),.m_ready(m_ready),
        .m_x(m_x),.m_y(m_y),.m_index(m_index),.m_count(m_count),
        .m_first(m_first),.m_last(m_last),.m_empty(m_empty),.m_error(m_error),.m_tag(m_tag)
    );
endmodule
