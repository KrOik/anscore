// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module robust_slope8(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [11:0] s_x,s_y,
    input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [3:0] m_count,output wire [4:0] m_pairs,m_skipped,
    output wire m_even,output wire signed [25:0] m_num,
    output wire [24:0] m_den,
    output wire signed [12:0] m_low_num,m_high_num,
    output wire [11:0] m_low_den,m_high_den,
    output wire [7:0] m_tag,output wire [1:0] m_errors
);
    theil_sen_slope core(.*);
endmodule
