// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module feature_circle(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [7:0] s_x,s_y,input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire signed [28:0] m_center_x_num,m_center_y_num,
    output wire [28:0] m_den,output wire [57:0] m_radius_sq_num,
    output wire [1:0] m_support,m_status,output wire [2:0] m_i,m_j,m_k,
    output wire [3:0] m_count,output wire [7:0] m_tag
);
    minimum_enclosing_circle core(.*);
endmodule
`default_nettype wire
