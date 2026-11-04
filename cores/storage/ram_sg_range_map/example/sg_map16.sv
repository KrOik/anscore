// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module sg_map16(
    input wire clk,rst,c_valid,output wire c_ready,input wire [1:0] c_op,
    input wire [63:0] c_offset,c_bytes,input wire [7:0] c_tag,
    input wire e_valid,output wire e_ready,input wire e_keep,e_first,e_last,
    input wire [31:0] e_base,input wire [15:0] e_bytes,
    output wire m_valid,input wire m_ready,output wire [1:0] m_op,
    output wire [2:0] m_status,m_load_errors,output wire m_keep,m_first,m_last,
    output wire [7:0] m_tag,output wire [31:0] m_addr,output wire [15:0] m_bytes,
    output wire [19:0] m_offset,m_total,output wire [3:0] m_segment,
    output wire [4:0] m_segments
);
    ram_sg_range_map #(.MAX_SEGS(16),.ADDR_W(32),.LEN_W(16),.TAG_W(8)) dut(.*);
endmodule
