`timescale 1ns/1ps
module arborescence8 (
    input wire clk,rst,s_valid,s_keep,s_last,s_error,
    output wire s_ready,
    input wire [31:0] s_from,s_to,s_root,
    input wire [7:0] s_cost,s_tag,
    input wire m_ready,
    output wire m_valid,m_summary,m_last,m_feasible,
    output wire [31:0] m_vertex,m_parent,m_edge_index,
    output wire [7:0] m_cost,m_tag,
    output wire [10:0] m_total_cost,
    output wire [3:0] m_errors
);
    directed_minimum_arborescence #(.NUM_NODES(8),.MAX_EDGES(16),.COST_W(8),.TAG_W(8)) core(.*);
endmodule
