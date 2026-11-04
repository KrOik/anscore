// SPDX-License-Identifier: Apache-2.0
module trail8(
    input wire clk,input wire rst,
    input wire c_valid,output wire c_ready,input wire [31:0] c_start,input wire [7:0] c_tag,
    input wire s_valid,output wire s_ready,input wire [31:0] s_from,input wire [31:0] s_to,
    input wire s_keep,input wire s_last,output wire m_valid,input wire m_ready,
    output wire [31:0] m_node,output wire [31:0] m_in_edge,output wire [31:0] m_step,
    output wire [31:0] m_edges,output wire m_has_edge,output wire m_keep,output wire m_last,
    output wire [3:0] m_error,output wire [7:0] m_tag
);
    directed_euler_trail #(.NUM_NODES(8),.MAX_EDGES(32),.TAG_W(8)) core(.*);
endmodule
