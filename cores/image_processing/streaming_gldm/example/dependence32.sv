// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module dependence32(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [7:0] s_pixel,input wire [2:0] s_alpha,
    input wire s_sof,s_eol,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [2:0] m_gray,m_alpha,
    output wire [3:0] m_dependence,output wire [9:0] m_count,
    output wire m_first,m_last,output wire [7:0] m_tag,output wire [1:0] m_errors
);
    streaming_gldm #(.WIDTH(32),.HEIGHT(24),.PIXEL_W(8),.GRAY_W(3),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
