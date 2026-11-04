// SPDX-License-Identifier: Apache-2.0
// Default 16-node graph service. Standard ready/valid on both sides; no CE.
module graph16_forest (
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [3:0] s_u,s_v,input wire signed [15:0] s_weight,
    input wire [7:0] s_edge_tag,s_graph_tag,input wire s_keep,s_last,
    output wire m_valid,input wire m_ready,output wire m_summary,
    output wire [3:0] m_u,m_v,output wire signed [15:0] m_weight,
    output wire [7:0] m_edge_tag,m_graph_tag,
    output wire m_bad_index,m_overflow,
    output wire signed [19:0] m_total_weight,
    output wire [4:0] m_selected,m_components
);
    kruskal_msf dut(.*);
endmodule
