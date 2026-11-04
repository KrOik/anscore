// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Feed r[0],r[1],r[2],r[3],r[4], then consume four a/k coefficient tokens.
module lpc4_example (
    input wire clk,rst,
    input wire correlation_valid,output wire correlation_ready,
    input wire signed [15:0] correlation,
    output wire coefficient_valid,input wire coefficient_ready,
    output wire signed [21:0] coefficient_q16,
    output wire signed [16:0] reflection_q16,
    output wire [2:0] coefficient_index,
    output wire last,output wire [1:0] error
);
    wire [32:0] energy;wire [7:0] tag;
    levinson_durbin #(.DATA_W(16),.FRAC(16),.ORDER(4)) predictor (
        .clk(clk),.rst(rst),.s_valid(correlation_valid),.s_ready(correlation_ready),
        .s_r(correlation),.s_tag(8'd0),.m_valid(coefficient_valid),.m_ready(coefficient_ready),
        .m_a(coefficient_q16),.m_reflection(reflection_q16),.m_index(coefficient_index),
        .m_last(last),.m_energy(energy),.m_error(error),.m_tag(tag)
    );
endmodule
