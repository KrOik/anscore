// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module extent_pool64(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [2:0] s_op,input wire [31:0] s_length,s_base,
    input wire [3:0] s_align_order,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_op,m_status,output wire [31:0] m_length,m_base,
    output wire [3:0] m_align_order,output wire [7:0] m_tag,
    output wire [6:0] m_free_units,m_largest_gap
);
    extent_pool_allocator #(.UNITS(64),.TAG_W(8)) pool(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_op(s_op),
        .s_length(s_length),.s_base(s_base),.s_align_order(s_align_order),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_op(m_op),.m_status(m_status),
        .m_length(m_length),.m_base(m_base),.m_align_order(m_align_order),.m_tag(m_tag),
        .m_free_units(m_free_units),.m_largest_gap(m_largest_gap)
    );
endmodule
