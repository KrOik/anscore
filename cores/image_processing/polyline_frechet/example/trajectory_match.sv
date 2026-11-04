// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Two equally sampled trajectories. For unequal lengths use the core's keeps.
module trajectory_match(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [11:0] a_x,a_y,b_x,b_y,
    input wire s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire signed [11:0] m_a_x,m_a_y,m_b_x,m_b_y,
    output wire [3:0] m_index_a,m_index_b,
    output wire [4:0] m_count_a,m_count_b,
    output wire [24:0] m_distance_sq,
    output wire m_first,m_last,m_empty,
    output wire [3:0] m_errors,output wire [7:0] m_tag
);
    polyline_frechet core(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_a_x(a_x),.s_a_y(a_y),.s_b_x(b_x),.s_b_y(b_y),
        .s_a_keep(1'b1),.s_b_keep(1'b1),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_a_x(m_a_x),.m_a_y(m_a_y),.m_b_x(m_b_x),.m_b_y(m_b_y),
        .m_index_a(m_index_a),.m_index_b(m_index_b),.m_count_a(m_count_a),.m_count_b(m_count_b),
        .m_distance_sq(m_distance_sq),.m_first(m_first),.m_last(m_last),.m_empty(m_empty),.m_errors(m_errors),.m_tag(m_tag));
endmodule
`default_nettype wire
