// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module interval_set16(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [2:0] c_op,input wire [63:0] c_base,
    input wire [64:0] c_bytes,input wire [7:0] c_tag,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_op,m_status,
    output wire m_keep,m_first,m_last,
    output wire [3:0] m_index,output wire [31:0] m_base,
    output wire [32:0] m_bytes,output wire [4:0] m_count,
    output wire [32:0] m_total,m_covered,
    output wire m_whole,output wire [7:0] m_tag
);
    ram_interval_set dut(.*);
endmodule
