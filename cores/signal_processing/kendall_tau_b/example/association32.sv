// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module association32(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [15:0] s_x,s_y,input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [5:0] m_count,
    output wire [8:0] m_pairs,m_concordant,m_discordant,m_tie_x,m_tie_y,m_tie_both,
    output wire signed [9:0] m_score,output wire [17:0] m_radicand,
    output wire [7:0] m_tag,output wire [2:0] m_errors
);
    kendall_tau_b #(.DATA_W(16),.MAX_LEN(32),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
