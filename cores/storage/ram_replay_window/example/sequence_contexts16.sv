// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module sequence_contexts16(
    input wire clk,rst,c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_context,input wire [63:0] c_sequence,input wire [7:0] c_tag,
    output wire m_valid,input wire m_ready,output wire [2:0] m_op,m_status,
    output wire [31:0] m_context,output wire [63:0] m_sequence,
    output wire [7:0] m_tag,output wire m_accepted,m_marked,m_active,
    output wire [63:0] m_head,output wire [63:0] m_seen
);
    ram_replay_window dut(.*);
endmodule
