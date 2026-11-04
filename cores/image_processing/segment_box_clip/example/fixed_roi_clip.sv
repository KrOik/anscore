`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Minimal vector-overlay ROI example: closed integer rectangle 0..63 x 0..47.
module fixed_roi_clip(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [11:0] s_x0,s_y0,s_x1,s_y1,
    input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire signed [28:0] m_x0_num,m_y0_num,m_x1_num,m_y1_num,
    output wire [12:0] m_den0,m_den1,
    output wire m_visible,m_point,m_error,
    output wire [1:0] m_clipped,
    output wire [7:0] m_tag
);
    segment_box_clip core(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_x0(s_x0),.s_y0(s_y0),.s_x1(s_x1),.s_y1(s_y1),
        .s_xmin(12'sd0),.s_ymin(12'sd0),.s_xmax(12'sd63),.s_ymax(12'sd47),
        .s_tag(s_tag),.m_valid(m_valid),.m_ready(m_ready),
        .m_x0_num(m_x0_num),.m_y0_num(m_y0_num),.m_x1_num(m_x1_num),.m_y1_num(m_y1_num),
        .m_den0(m_den0),.m_den1(m_den1),.m_visible(m_visible),.m_point(m_point),
        .m_error(m_error),.m_clipped(m_clipped),.m_tag(m_tag)
    );
endmodule
