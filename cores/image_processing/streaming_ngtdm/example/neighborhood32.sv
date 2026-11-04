// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module neighborhood32(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [7:0] s_pixel,input wire s_sof,s_eol,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [2:0] m_gray,
    output wire [9:0] m_count,output wire [19:0] m_difference_120,
    output wire m_first,m_last,output wire [7:0] m_tag,output wire [1:0] m_errors
);
    streaming_ngtdm #(.WIDTH(32),.HEIGHT(24),.PIXEL_W(8),.GRAY_W(3),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
