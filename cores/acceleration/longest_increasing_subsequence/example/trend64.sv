// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Ordinary ready/valid on every port; signed integer samples, no CE.
module trend64(
    input wire clk,rst,s_valid, output wire s_ready,
    input wire signed [15:0] s_value,
    input wire s_keep,s_first,s_last, input wire [7:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire signed [15:0] m_value,
    output wire [5:0] m_index,m_rank,
    output wire [6:0] m_length,m_count,
    output wire m_keep,m_first,m_last,
    output wire [7:0] m_tag, output wire [1:0] m_errors
);
    longest_increasing_subsequence dut(.*);
endmodule
