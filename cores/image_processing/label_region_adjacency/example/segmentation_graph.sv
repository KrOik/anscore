// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// A label-image source supplies 64x64 segmentation labels 0..15.
module segmentation_graph(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [3:0] s_label,input wire s_sof,s_eol,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [3:0] m_a,m_b,output wire [13:0] m_contact_sides,
    output wire done_valid,input wire done_ready,
    output wire [1:0] done_errors,output wire [3:0] done_nodes,
    output wire [12:0] done_foreground,output wire [6:0] done_edges,
    output wire [13:0] done_contact_sides,output wire [7:0] done_tag
);
    label_region_adjacency graph(.*);
endmodule
