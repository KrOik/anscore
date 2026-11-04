// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Ordinary ready/valid raw-bit frame. No CE-qualified stream adaptation.
module recurrence64(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire s_bit,s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [6:0] m_count,m_order,output wire [64:0] m_connection,
    output wire m_next,output wire [7:0] m_tag,output wire [1:0] m_errors
);
    binary_linear_recurrence #(.MAX_BITS(64),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
