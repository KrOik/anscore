// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module cover8(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [15:0] c_target,input wire [7:0] c_tag,
    input wire s_valid,output wire s_ready,
    input wire [15:0] s_members,input wire [7:0] s_weight,input wire s_last,
    output wire m_valid,input wire m_ready,output wire m_feasible,
    output wire [7:0] m_selection,output wire [10:0] m_weight,
    output wire [1:0] m_error,output wire [7:0] m_tag
);
    exact_weighted_set_cover unit(.*);
endmodule
