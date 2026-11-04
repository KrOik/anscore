// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module byte_scatter16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [63:0] s_addr,input wire [7:0] s_data,
    input wire s_keep,s_first,s_last,input wire [7:0] s_tag,
    output wire q_valid,input wire q_ready,output wire [31:0] q_addr,q_data,
    output wire [3:0] q_strb,input wire p_valid,output wire p_ready,input wire p_error,
    output wire m_valid,input wire m_ready,output wire [4:0] m_status,
    output wire [7:0] m_tag,output wire [4:0] m_beats,output wire [15:0] m_error_mask
);
    ram_byte_write_coalescer dut(.*);
endmodule
