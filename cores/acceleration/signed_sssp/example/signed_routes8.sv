// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module signed_routes8(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,s_source,
    input wire signed [7:0] s_weight,
    input wire s_present,s_keep,s_first,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_vertex,m_source,output wire signed [11:0] m_distance,
    output wire m_reachable,m_negative_infinite,m_has_negative_cycle,
    output wire m_keep,m_first,m_last,output wire [7:0] m_tag,output wire [2:0] m_errors
);
    signed_sssp dut(.*);
endmodule
