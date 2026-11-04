// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module conflict_slots8(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_u,s_v,
    input wire s_present,s_keep,s_first,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [31:0] m_colors,
    output wire [3:0] m_count,
    output wire [1:0] m_error,
    output wire [7:0] m_tag
);
    exact_graph_coloring core(.*);
endmodule
