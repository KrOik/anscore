// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module steiner8(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire s_present,input wire [15:0] s_weight,input wire s_last,
    input wire [7:0] s_terminals,s_tag,
    output wire m_valid,input wire m_ready,output wire m_summary,
    output wire [2:0] m_u,m_v,output wire [15:0] m_weight,
    output wire [18:0] m_total_cost,output wire [3:0] m_selected_count,
    output wire [7:0] m_vertices,m_terminals,
    output wire m_feasible,output wire [3:0] m_error,output wire [7:0] m_tag
);
    exact_undirected_steiner_tree #(.NUM_NODES(8),.MAX_TERMINALS(4),.WEIGHT_W(16),.TAG_W(8)) core(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_present(s_present),.s_weight(s_weight),.s_last(s_last),
        .s_terminals(s_terminals),.s_tag(s_tag),.m_valid(m_valid),.m_ready(m_ready),
        .m_summary(m_summary),.m_u(m_u),.m_v(m_v),.m_weight(m_weight),
        .m_total_cost(m_total_cost),.m_selected_count(m_selected_count),
        .m_vertices(m_vertices),.m_terminals(m_terminals),
        .m_feasible(m_feasible),.m_error(m_error),.m_tag(m_tag)
    );
endmodule
