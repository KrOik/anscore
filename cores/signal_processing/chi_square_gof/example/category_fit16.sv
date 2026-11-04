// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Up to 16 unsigned16 observed/expected frequency categories, Q16 statistic.
module category_fit16(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire [15:0] s_observed,s_expected,
    input wire s_keep,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [51:0] m_statistic,
    output wire [4:0] m_count,m_active,m_df,
    output wire [19:0] m_sum_observed,m_sum_expected,
    output wire [7:0] m_tag,
    output wire [4:0] m_errors
);
    chi_square_gof fit(.*);
endmodule
