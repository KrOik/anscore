// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module distribution32(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [15:0] s_key,input wire [11:0] s_a,s_b,
    input wire s_keep,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [5:0] m_bins,output wire [16:0] m_total_a,m_total_b,
    output wire [33:0] m_num,m_den,m_plus,m_minus,
    output wire signed [15:0] m_witness_key,output wire [5:0] m_witness_bin,
    output wire signed [1:0] m_direction,output wire [7:0] m_tag,
    output wire [3:0] m_errors
);
    ks_histogram_distance core(.*);
endmodule
