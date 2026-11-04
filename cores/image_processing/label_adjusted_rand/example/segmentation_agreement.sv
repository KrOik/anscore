// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// The caller aligns both label rasters and the shared mask at the same transfer.
module segmentation_agreement(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [3:0] s_a,s_b,input wire s_keep,s_sof,s_eol,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire signed [47:0] m_ari_numerator,output wire [46:0] m_ari_denominator,
    output wire [12:0] m_count,output wire [22:0] m_pairs,m_same_a,m_same_b,m_same_both,
    output wire m_equivalent,m_degenerate,output wire [1:0] m_errors,
    output wire [7:0] m_tag
);
    label_adjusted_rand comparison(.*);
endmodule
