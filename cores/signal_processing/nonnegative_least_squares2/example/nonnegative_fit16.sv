// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module nonnegative_fit16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [7:0] s_a0,s_a1,s_b,input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [43:0] m_num_x,m_num_y,m_denominator,
    output wire signed [43:0] m_determinant,
    output wire [4:0] m_count,output wire [1:0] m_positive,m_status,output wire [7:0] m_tag
);
    nonnegative_least_squares2 fit(.*);
endmodule
`default_nettype wire
