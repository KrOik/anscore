// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Solve two simultaneous scalar equations with signed16 integer coefficients.
module solve_calibration2x2 (
    input wire clk,rst,command_valid,
    output wire command_ready,
    input wire signed [15:0] a00,a01,a10,a11,b0,b1,
    output wire result_valid,
    input wire result_ready,
    output wire signed [31:0] x_q16,y_q16,
    output wire singular,
    output wire [1:0] saturated
);
    wire signed [32:0] determinant;
    wire [7:0] tag;
    linear_solve2x2 #(.W(16),.FRAC(16),.RESULT_W(32)) solver (
        .clk(clk),.rst(rst),.s_valid(command_valid),.s_ready(command_ready),
        .s_a00(a00),.s_a01(a01),.s_a10(a10),.s_a11(a11),.s_b0(b0),.s_b1(b1),.s_tag(8'd0),
        .m_valid(result_valid),.m_ready(result_ready),.m_x(x_q16),.m_y(y_q16),
        .m_determinant(determinant),.m_singular(singular),.m_saturated(saturated),.m_tag(tag)
    );
endmodule
