// Complete default instantiation; ordinary ready/valid, no CE conversion.
`timescale 1ns/1ps
module dag_reduce16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,
    input wire s_present,s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_keep,m_last,output wire [1:0] m_errors,
    output wire [7:0] m_tag,output wire [3:0] m_node,
    output wire [15:0] m_successors,output wire [4:0] m_out_degree,
    output wire [8:0] m_edge_count,m_removed_count
);
    dag_transitive_reduction #(.NUM_NODES(16),.TAG_W(8)) core(.*);
endmodule
