// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module gather16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire s_keep,s_first,s_last,input wire [31:0] s_addr,input wire [7:0] s_tag,
    output wire q_valid,input wire q_ready,output wire [31:0] q_addr,
    input wire p_valid,output wire p_ready,input wire [31:0] p_data,input wire p_error,
    output wire m_valid,input wire m_ready,output wire [2:0] m_status,
    output wire m_keep,m_error,m_first,m_last,output wire [31:0] m_addr,m_data,
    output wire [7:0] m_tag,output wire [3:0] m_index,output wire [4:0] m_count,m_unique
);
    ram_read_gather #(.MAX_ITEMS(16),.ADDR_W(32),.DATA_W(32),.TAG_W(8)) dut(.*);
endmodule
