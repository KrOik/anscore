// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module dma_plan32(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_base,s_row_bytes,input wire [15:0] s_rows,
    input wire signed [32:0] s_stride,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [1:0] m_status,output wire [7:0] m_tag,output wire m_keep,
    output wire [31:0] m_addr,output wire [8:0] m_beats,output wire [14:0] m_bytes,
    output wire [3:0] m_first_mask,m_last_mask,output wire [15:0] m_row,
    output wire [31:0] m_row_offset,output wire [47:0] m_offset,
    output wire m_row_first,m_row_last,m_first,m_last
);
    dma_2d_burst_plan planner(.*);
endmodule
