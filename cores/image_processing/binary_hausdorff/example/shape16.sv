// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module shape16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire s_a,s_b,s_sof,s_eol,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [7:0] m_count_a,m_count_b,
    output wire [8:0] m_ab_distance_sq,m_ba_distance_sq,m_distance_sq,output wire m_direction,
    output wire [3:0] m_ab_source_x,m_ab_source_y,m_ab_target_x,m_ab_target_y,
        m_ba_source_x,m_ba_source_y,m_ba_target_x,m_ba_target_y,
    output wire [7:0] m_tag,output wire [3:0] m_errors
);
    binary_hausdorff #(.WIDTH(16),.HEIGHT(12),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
