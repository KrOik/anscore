// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Complete independent default and maximum-width subset-count services.
module subset_count_pair(
    input wire clk,rst,
    input wire s32_valid,output wire s32_ready,
    input wire [63:0] s32_n,s32_k,input wire [7:0] s32_tag,
    output wire m32_valid,input wire m32_ready,
    output wire [31:0] m32_value,output wire m32_error,output wire [7:0] m32_tag,
    input wire s64_valid,output wire s64_ready,
    input wire [63:0] s64_n,s64_k,input wire [31:0] s64_tag,
    output wire m64_valid,input wire m64_ready,
    output wire [63:0] m64_value,output wire m64_error,output wire [31:0] m64_tag
);
    exact_binomial default_count(
        .clk(clk),.rst(rst),.s_valid(s32_valid),.s_ready(s32_ready),
        .s_n(s32_n),.s_k(s32_k),.s_tag(s32_tag),.m_valid(m32_valid),
        .m_ready(m32_ready),.m_value(m32_value),.m_error(m32_error),.m_tag(m32_tag)
    );
    exact_binomial #(.MAX_N(64),.TAG_W(32)) maximum_count(
        .clk(clk),.rst(rst),.s_valid(s64_valid),.s_ready(s64_ready),
        .s_n(s64_n),.s_k(s64_k),.s_tag(s64_tag),.m_valid(m64_valid),
        .m_ready(m64_ready),.m_value(m64_value),.m_error(m64_error),.m_tag(m64_tag)
    );
endmodule
