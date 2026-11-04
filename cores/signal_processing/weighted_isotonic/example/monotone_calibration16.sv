// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Ordered calibration observations, returned as exact rational constant blocks.
module monotone_calibration16(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [15:0] s_value,
    input wire [7:0] s_weight,
    input wire s_keep,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire m_keep,m_last,
    output wire signed [28:0] m_numerator,
    output wire [11:0] m_denominator,
    output wire [4:0] m_start,m_length,m_count,m_block_count,m_block_index,
    output wire [7:0] m_tag,
    output wire [2:0] m_errors
);
    weighted_isotonic fit(.*);
endmodule
