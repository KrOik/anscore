`timescale 1ns/1ps
// Fixed 16-vertex all-path dependency service; ordinary ready/valid ports.
module dependency_gate16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,s_root,input wire s_present,s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire m_keep,m_last,output wire [1:0] m_errors,
    output wire [7:0] m_tag,output wire [3:0] m_node,m_root,m_idom,
    output wire m_reachable,m_idom_valid,output wire [4:0] m_depth,m_dom_count,m_subtree_count,m_reached_count,
    output wire [15:0] m_dominators,m_dominated
);
    directed_dominators #(.NUM_NODES(16),.TAG_W(8)) service(.*);
endmodule
