// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module priced_flow8(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [31:0] c_source,c_sink,c_limit,input wire [7:0] c_tag,
    input wire s_valid,output wire s_ready,input wire [31:0] s_from,s_to,
    input wire [7:0] s_capacity,s_cost,input wire s_keep,s_last,s_error,
    output wire m_valid,input wire m_ready,output wire m_keep,m_last,
    output wire [3:0] m_index,output wire [7:0] m_edge_flow,
    output wire [11:0] m_total_flow,output wire [19:0] m_total_cost,
    output wire m_target_met,output wire [5:0] m_error,output wire [7:0] m_tag
);
    min_cost_flow dut(.*);
endmodule
