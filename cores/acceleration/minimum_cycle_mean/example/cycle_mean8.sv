// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module cycle_mean8(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,input wire signed [7:0] s_weight,
    input wire s_present,s_keep,s_first,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire m_has_cycle,
    output wire signed [12:0] m_numerator,output wire [3:0] m_denominator,
    output wire [1:0] m_error,output wire [7:0] m_tag
);
    minimum_cycle_mean #(.NUM_NODES(8),.WEIGHT_W(8),.TAG_W(8)) core(.*);
endmodule
