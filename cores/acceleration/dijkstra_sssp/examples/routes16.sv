`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module routes16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,s_source,
    input wire [15:0] s_weight,
    input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [3:0] m_vertex,m_parent,output wire [19:0] m_distance,
    output wire m_reachable,m_parent_valid,m_first,m_last,
    output wire [31:0] m_source,output wire [1:0] m_error,output wire [7:0] m_tag
);
    dijkstra_sssp dut(.*);
endmodule
