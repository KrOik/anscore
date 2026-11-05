// SPDX-License-Identifier: Apache-2.0
module general_match8(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,
    input wire signed [15:0] s_weight,
    input wire s_present,s_keep,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_keep,m_last,
    output wire [1:0] m_error,
    output wire [7:0] m_tag,
    output wire [2:0] m_node,m_partner,
    output wire m_matched,
    output wire [3:0] m_cardinality,
    output wire [16:0] m_total_weight
);
    general_weighted_matching #(.NUM_NODES(8),.WEIGHT_W(16),.TAG_W(8)) dut(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_from(s_from),.s_to(s_to),.s_weight(s_weight),.s_present(s_present),
        .s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_keep(m_keep),.m_last(m_last),
        .m_error(m_error),.m_tag(m_tag),.m_node(m_node),.m_partner(m_partner),
        .m_matched(m_matched),.m_cardinality(m_cardinality),
        .m_total_weight(m_total_weight)
    );
endmodule
