// Fixed16-node resilience example, Apache-2.0.
`timescale 1ns/1ps
module graph_resilience16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_u,s_v,
    input wire s_present,s_keep,s_last,
    input wire [8-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_keep,m_last,m_error,
    output wire [8-1:0] m_tag,
    output wire [4-1:0] m_node,m_component,
    output wire [5-1:0] m_components,m_after_removal,m_degree,m_bridge_count,
    output wire m_cut_vertex,
    output wire [16-1:0] m_bridge_neighbors
);
    graph_cut_structure #(.NUM_NODES(16),.TAG_W(8)) core(.*);
endmodule
