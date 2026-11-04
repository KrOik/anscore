// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module texture64(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [7:0] s_pixel,input wire s_sof,s_eol,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [1:0] m_direction,output wire [2:0] m_gray,
    output wire [6:0] m_length,output wire [12:0] m_count,m_runs,
    output wire m_direction_last,m_last,output wire [7:0] m_tag,
    output wire [1:0] m_errors
);
    streaming_glrlm texture(.*);
endmodule
