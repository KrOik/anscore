// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module normalize16_example (
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [15:0] s_data,
    input wire s_keep,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire signed [17:0] m_data,
    output wire m_keep,m_last,
    output wire [1:0] m_status,
    output wire [4:0] m_count,
    output wire [3:0] m_index,
    output wire [7:0] m_tag
);
    wire [35:0] energy_unused;
    block_vector_normalize normalize (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_keep(m_keep),
        .m_last(m_last),.m_status(m_status),.m_count(m_count),.m_index(m_index),
        .m_energy(energy_unused),.m_tag(m_tag)
    );
endmodule
