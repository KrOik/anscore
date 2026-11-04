// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module phase_merge16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [15:0] s_a,s_b,input wire [15:0] s_m,s_n,
    input wire [7:0] s_tag,output wire m_valid,input wire m_ready,
    output wire [31:0] m_solution,m_period,output wire [2:0] m_status,
    output wire [7:0] m_tag
);
    congruence_merge #(.W(16),.TAG_W(8)) core(.*);
endmodule
