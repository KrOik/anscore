`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Unordered signed point set -> exact convex hull -> filled binary ROI mask.
module point_hull_mask #(
    parameter integer COORD_W=12,MAX_POINTS=32,WIDTH=64,HEIGHT=64,TAG_W=8,
    localparam integer CW=$clog2(MAX_POINTS+1),
    localparam integer XW=(WIDTH>1)?$clog2(WIDTH):1,
    localparam integer YW=(HEIGHT>1)?$clog2(HEIGHT):1
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_pixel,
    output wire [XW-1:0] m_x,
    output wire [YW-1:0] m_y,
    output wire m_sof,m_eol,m_last,
    output wire [CW-1:0] m_vertices,
    output wire [1:0] m_error,
    output wire [TAG_W-1:0] m_tag
);
    wire h_valid,h_ready,h_first,h_last,h_empty,h_error;
    wire signed [COORD_W-1:0] h_x,h_y;
    wire [CW-1:0] h_index,h_count;
    wire [TAG_W-1:0] h_tag;
    point_convex_hull #(.COORD_W(COORD_W),.MAX_POINTS(MAX_POINTS),.TAG_W(TAG_W)) hull(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_x(s_x),.s_y(s_y),
        .s_mask(s_keep),.s_last(s_last),.s_tag(s_tag),.m_valid(h_valid),.m_ready(h_ready),
        .m_x(h_x),.m_y(h_y),.m_index(h_index),.m_count(h_count),.m_first(h_first),
        .m_last(h_last),.m_empty(h_empty),.m_error(h_error),.m_tag(h_tag)
    );
    polygon_raster_mask #(.COORD_W(COORD_W),.MAX_VERTICES(MAX_POINTS),.WIDTH(WIDTH),
                          .HEIGHT(HEIGHT),.TAG_W(TAG_W)) raster(
        .clk(clk),.rst(rst),.s_valid(h_valid),.s_ready(h_ready),.s_x(h_x),.s_y(h_y),
        .s_keep(!h_empty),.s_last(h_last),.s_error(h_error),.s_tag(h_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_pixel(m_pixel),.m_x(m_x),.m_y(m_y),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_vertices(m_vertices),
        .m_error(m_error),.m_tag(m_tag)
    );
endmodule
