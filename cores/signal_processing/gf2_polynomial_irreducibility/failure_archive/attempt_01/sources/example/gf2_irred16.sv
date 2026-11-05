// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module gf2_irred16(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire [15:0] s_poly,input wire [7:0] s_tag,
 output wire m_valid,input wire m_ready,output wire m_irreducible,
 output wire [1:0] m_kind,output wire [4:0] m_check_index,
 output wire [15:0] m_delta,output wire [16:0] m_witness_gcd,
 output wire [7:0] m_tag
);
 gf2_polynomial_irreducibility #(.DEGREE(16),.TAG_W(8)) core(.*);
endmodule
