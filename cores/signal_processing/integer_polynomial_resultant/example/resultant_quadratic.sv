// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module resultant_quadratic(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [7:0] s_a,s_b,input wire [2:0] s_degree_a,s_degree_b,
    input wire s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [2:0] m_count,
    output wire [2:0] m_degree_a,m_degree_b,output wire [7:0] m_tag,
    output wire [1:0] m_status,output wire signed [37:0] m_resultant,output wire m_common_root
);
    integer_polynomial_resultant #(.DATA_W(8),.MAX_DEG(2),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
