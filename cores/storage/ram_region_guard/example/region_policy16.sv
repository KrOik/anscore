// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module region_policy16(
    input wire clk,rst,c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_slot,input wire [63:0] c_base,input wire [64:0] c_bytes,
    input wire [2:0] c_perm,c_access,input wire [7:0] c_tag,
    output wire m_valid,input wire m_ready,output wire [2:0] m_op,
    output wire [3:0] m_status,output wire [7:0] m_tag,
    output wire m_allow,m_found,output wire [31:0] m_slot,m_base,
    output wire [32:0] m_bytes,output wire [2:0] m_perm,output wire [4:0] m_count
);
    ram_region_guard dut(.*);
endmodule
