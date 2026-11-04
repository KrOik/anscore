// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module eigen16_example (
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [15:0] s_a,s_b,s_d,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire signed [31:0] m_min,m_max,
    output wire [1:0] m_saturated,
    output wire m_psd,m_repeated,
    output wire [7:0] m_tag
);
    wire signed [16:0] trace_unused;
    wire [32:0] discriminant_unused;
    symmetric_eigen2x2 eigen (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_a(s_a),.s_b(s_b),.s_d(s_d),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_min(m_min),.m_max(m_max),
        .m_saturated(m_saturated),.m_psd(m_psd),.m_repeated(m_repeated),
        .m_trace(trace_unused),.m_discriminant(discriminant_unused),.m_tag(m_tag)
    );
endmodule
