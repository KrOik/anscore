// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module dma_hazards8(
 input wire clk,rst,s_valid,output wire s_ready,input wire [1:0] s_op,
 input wire [31:0] s_base,input wire [32:0] s_length,input wire s_exclusive,
 input wire [7:0] s_owner,input wire [31:0] s_slot,input wire [7:0] s_generation,s_tag,
 output wire m_valid,input wire m_ready,output wire [1:0] m_op,output wire [2:0] m_status,
 output wire [7:0] m_tag,output wire [31:0] m_slot,output wire [7:0] m_generation,m_owner,
 output wire [31:0] m_base,output wire [32:0] m_length,output wire m_exclusive,
 output wire [7:0] m_conflicts,output wire [3:0] m_live,m_free,m_retired
);
 range_lock_manager manager(.*);
endmodule
