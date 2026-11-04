// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module two_sample32(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [15:0] s_value,
    input wire s_group,s_keep,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [5:0] m_count,m_count_a,m_count_b,
    output wire [9:0] m_pairs,m_wins,m_losses,m_ties,m_u2,
    output wire signed [17:0] m_rank_biserial,
    output wire [7:0] m_tag,
    output wire [2:0] m_errors
);
    mann_whitney_u statistic(.*);
endmodule
