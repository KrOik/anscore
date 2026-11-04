// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module interpolate4(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [7:0] s_x,s_y,s_query,
    input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_count,output wire signed [7:0] m_query,
    output wire [7:0] m_tag,output wire [2:0] m_errors,
    output wire signed [58:0] m_numerator,output wire [47:0] m_denominator
);
    rational_polynomial_interpolate #(.DATA_W(8),.MAX_LEN(4),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
