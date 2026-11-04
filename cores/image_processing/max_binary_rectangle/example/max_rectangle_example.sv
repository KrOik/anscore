`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module max_rectangle_example(
    input wire clk,rst,
    input wire pixel_valid,output wire pixel_ready,
    input wire [7:0] gray,input wire sof,eol,
    output wire result_valid,input wire result_ready,
    output wire [12:0] area,
    output wire [5:0] xmin,xmax,ymin,ymax,
    output wire empty,frame_error
);
    wire [7:0] tag;
    max_binary_rectangle #(.WIDTH(64),.HEIGHT(64)) rectangle(
        .clk(clk),.rst(rst),.s_valid(pixel_valid),.s_ready(pixel_ready),
        .s_pixel(gray>=8'd128),.s_sof(sof),.s_eol(eol),.s_tag(8'd0),
        .m_valid(result_valid),.m_ready(result_ready),.m_area(area),
        .m_xmin(xmin),.m_xmax(xmax),.m_ymin(ymin),.m_ymax(ymax),
        .m_empty(empty),.m_error(frame_error),.m_tag(tag)
    );
endmodule
