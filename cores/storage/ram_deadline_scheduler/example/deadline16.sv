// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module deadline16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [2:0] s_op,input wire [15:0] s_id,
    input wire [31:0] s_deadline,s_cutoff,s_data,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_op,m_status,output wire m_found,m_replaced,m_due,
    output wire [15:0] m_id,output wire [31:0] m_deadline,m_data,
    output wire [7:0] m_tag,output wire [4:0] m_live,m_free
);
    ram_deadline_scheduler scheduler(.*);
endmodule
