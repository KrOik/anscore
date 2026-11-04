// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module packet_pool4(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [1:0] s_op,input wire [7:0] s_queue,input wire [31:0] s_data,
    input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [1:0] m_op,m_status,output wire [7:0] m_queue,m_tag,
    output wire m_keep,m_first,m_last,output wire [5:0] m_index,
    output wire [31:0] m_data,output wire [7:0] m_packet_tag,
    output wire [6:0] m_free_cells,m_queue_cells,m_queue_packets
);
    shared_packet_queues pool(.*);
endmodule
