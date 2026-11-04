// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Connect one standard stream to two independent standard stream consumers.
module multicast_2way (
    input wire clk, rst_n,
    input wire [31:0] s_data,
    input wire [3:0] s_keep,
    input wire s_last, s_valid,
    output wire s_ready,
    input wire [1:0] packet_mask,
    output wire [63:0] m_data,
    output wire [7:0] m_keep,
    output wire [1:0] m_last, m_valid,
    input wire [1:0] m_ready
);
    wire [1:0] unused_user;
    stream_multicast #(.PORTS(2), .DATA_WIDTH(32), .USER_WIDTH(1)) dut (
        .clk(clk), .rst_n(rst_n), .s_data(s_data), .s_keep(s_keep),
        .s_user(1'b0), .s_last(s_last), .s_mask(packet_mask),
        .s_valid(s_valid), .s_ready(s_ready), .m_data(m_data),
        .m_keep(m_keep), .m_user(unused_user), .m_last(m_last),
        .m_valid(m_valid), .m_ready(m_ready)
    );
endmodule
