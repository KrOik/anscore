// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module sparse_object64(
    input wire clk,rst,c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [63:0] c_length,c_offset,input wire [7:0] c_data,c_tag,
    output wire m_valid,input wire m_ready,output wire [2:0] m_op,m_status,
    output wire [7:0] m_tag,output wire m_keep,m_first,m_last,
    output wire [5:0] m_index,output wire [7:0] m_data,
    output wire [6:0] m_total,m_filled
);
    ram_sparse_assembler dut(.*);
endmodule
