`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module binary_topology_example(
    input wire clk,rst,
    input wire gray_valid,output wire gray_ready,
    input wire [7:0] gray,input wire sof,eol,
    output wire result_valid,input wire result_ready,
    output wire signed [13:0] euler4,euler8,
    output wire [12:0] area,output wire [14:0] perimeter,
    output wire empty,error
);
    wire [7:0] tag;
    streaming_binary_topology #(.WIDTH(64),.HEIGHT(64)) measure(
        .clk(clk),.rst(rst),.s_valid(gray_valid),.s_ready(gray_ready),
        .s_pixel(gray>=8'd128),.s_sof(sof),.s_eol(eol),.s_tag(8'd0),
        .m_valid(result_valid),.m_ready(result_ready),.m_euler4(euler4),
        .m_euler8(euler8),.m_area(area),.m_perimeter(perimeter),
        .m_empty(empty),.m_error(error),.m_tag(tag)
    );
endmodule
