// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module paired16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [15:0] s_x,s_y,
    input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [4:0] m_count,m_nonzero,m_zeros,m_positive,m_negative,m_tied,
    output wire [8:0] m_plus2,m_minus2,m_stat2,
    output wire [7:0] m_tag,output wire [1:0] m_errors
);
    wilcoxon_signed_rank core(.*);
endmodule
