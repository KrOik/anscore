// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module transport16 (
    input wire clk,input wire rst,
    input wire s_valid,output wire s_ready,input wire signed [15:0] s_key,
    input wire [15:0] s_source,input wire [15:0] s_target,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire m_summary,output wire m_last,
    output wire [3:0] m_source_index,output wire [3:0] m_target_index,
    output wire signed [15:0] m_source_key,output wire signed [15:0] m_target_key,
    output wire [15:0] m_quantity,output wire [35:0] m_cost,
    output wire [19:0] m_source_total,output wire [19:0] m_target_total,
    output wire [4:0] m_flow_count,output wire [1:0] m_error,output wire [7:0] m_tag
);
    exact_1d_transport #(.NUM_BINS(16),.KEY_W(16),.MASS_W(16),.TAG_W(8)) core (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_key(s_key),
        .s_source(s_source),.s_target(s_target),.s_tag(s_tag),.m_valid(m_valid),
        .m_ready(m_ready),.m_summary(m_summary),.m_last(m_last),
        .m_source_index(m_source_index),.m_target_index(m_target_index),
        .m_source_key(m_source_key),.m_target_key(m_target_key),.m_quantity(m_quantity),
        .m_cost(m_cost),.m_source_total(m_source_total),.m_target_total(m_target_total),
        .m_flow_count(m_flow_count),.m_error(m_error),.m_tag(m_tag)
    );
endmodule
`default_nettype wire
