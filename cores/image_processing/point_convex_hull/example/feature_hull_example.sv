`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module feature_hull_example(
    input wire clk,rst,
    input wire point_valid,output wire point_ready,
    input wire signed [15:0] point_x,point_y,
    input wire point_last,
    output wire hull_valid,input wire hull_ready,
    output wire signed [15:0] hull_x,hull_y,
    output wire [5:0] vertex_index,vertex_count,
    output wire first,last,empty,error
);
    wire [7:0] tag;
    point_convex_hull hull(
        .clk(clk),.rst(rst),.s_valid(point_valid),.s_ready(point_ready),
        .s_x(point_x),.s_y(point_y),.s_mask(1'b1),.s_last(point_last),.s_tag(8'd0),
        .m_valid(hull_valid),.m_ready(hull_ready),.m_x(hull_x),.m_y(hull_y),
        .m_index(vertex_index),.m_count(vertex_count),.m_first(first),.m_last(last),
        .m_empty(empty),.m_error(error),.m_tag(tag)
    );
endmodule
