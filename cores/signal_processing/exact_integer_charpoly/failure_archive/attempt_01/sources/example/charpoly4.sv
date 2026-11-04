// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module charpoly4(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [7:0] s_data,
    input wire s_keep,s_last,s_bad,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire signed [33:0] m_coeff,
    output wire [2:0] m_index,
    output wire m_keep,m_last,
    output wire [2:0] m_errors,
    output wire [7:0] m_tag
);
    exact_integer_charpoly #(.N(4),.DATA_W(8),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
