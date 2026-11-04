`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module select16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [7:0] s_cost,input wire [15:0] s_value,
    input wire s_keep,s_last,input wire [31:0] s_capacity,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_keep,m_selected,m_first,m_last,output wire [3:0] m_index,
    output wire [7:0] m_cost,output wire [15:0] m_value,output wire [4:0] m_count,
    output wire [19:0] m_total_value,output wire [5:0] m_total_cost,
    output wire [1:0] m_error,output wire [31:0] m_capacity,output wire [7:0] m_tag
);
    budget_knapsack dut(.*);
endmodule
