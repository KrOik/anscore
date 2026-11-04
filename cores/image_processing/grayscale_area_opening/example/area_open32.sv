// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module area_open32(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire [7:0] s_pixel,
    input wire s_sof,s_eol,
    input wire [10:0] s_area,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [7:0] m_pixel,
    output wire m_sof,m_eol,m_last,
    output wire [7:0] m_tag,
    output wire [2:0] m_errors
);
    grayscale_area_opening filter(.*);
endmodule
