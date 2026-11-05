// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module gf2_sfd16(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire [15:0] s_poly,input wire [7:0] s_tag,
 output wire m_valid,input wire m_ready,
 output wire [16:0] m_factor,
 output wire [4:0] m_multiplicity,m_degree,
 output wire m_last,output wire [7:0] m_tag
);
 gf2_squarefree_decomposition #(.DEGREE(16),.TAG_W(8)) core(.*);
endmodule
