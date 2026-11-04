`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
module flow8(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,s_source,s_sink,
    input wire [15:0] s_capacity,input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire m_keep,m_first,m_last,
    output wire [2:0] m_from,m_to,output wire [15:0] m_capacity,m_flow,
    output wire [18:0] m_total_flow,output wire [7:0] m_cut,
    output wire [2:0] m_error,output wire [31:0] m_source,m_sink,output wire [7:0] m_tag
);
    maxflow_mincut dut(.*);
endmodule
