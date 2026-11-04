// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// 64 basic units. Translate unit offsets to payload addresses in the caller.
module pool64_example (
    input wire clk,rst,s_valid, output wire s_ready,
    input wire [1:0] s_op, input wire [3:0] s_order,
    input wire [31:0] s_base, input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [1:0] m_op,m_status,output wire [3:0] m_order,
    output wire [31:0] m_base,output wire [7:0] m_tag,
    output wire [6:0] m_free_units,output wire m_has_free,
    output wire [3:0] m_largest_order
);
    buddy_pool_allocator #(.MAX_ORDER(6),.TAG_W(8)) pool (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_op(s_op),.s_order(s_order),.s_base(s_base),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_op(m_op),.m_status(m_status),
        .m_order(m_order),.m_base(m_base),.m_tag(m_tag),.m_free_units(m_free_units),
        .m_has_free(m_has_free),.m_largest_order(m_largest_order)
    );
endmodule
