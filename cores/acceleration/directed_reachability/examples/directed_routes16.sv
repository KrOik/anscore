`timescale 1ns/1ps
// Fixed 16-vertex service, ordinary ready/valid on both boundaries.
module directed_routes16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,input wire s_present,s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire m_keep,m_last,m_error,
    output wire [7:0] m_tag,output wire [3:0] m_node,m_scc_root,
    output wire [4:0] m_scc_size,m_components,m_forward_count,m_backward_count,
    output wire [15:0] m_reachable,m_scc_members,output wire m_cyclic,m_acyclic
);
    directed_reachability #(.NUM_NODES(16),.TAG_W(8)) service(.*);
endmodule
