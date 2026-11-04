// SPDX-License-Identifier: Apache-2.0
// Each included edge declares that request s_left can use resource s_right.
module resource_match8(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [2:0] s_left,s_right,
    input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_left,m_right,output wire m_matched,m_last,
    output wire [3:0] m_cardinality,output wire m_bad_index,
    output wire [7:0] m_tag
);
    bipartite_match dut(.*);
endmodule
