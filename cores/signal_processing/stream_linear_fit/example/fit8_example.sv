// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Default 8-bit paired-sample fit; no physical ADC interface is implied.
module fit8_example (
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [7:0] s_x,s_y,
    input wire s_keep,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire signed [31:0] m_slope,m_intercept,
    output wire [5:0] m_count,
    output wire m_degenerate,m_overflow,
    output wire [1:0] m_saturated,
    output wire [7:0] m_tag
);
    wire [46:0] spread_unused;
    stream_linear_fit fit (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_x(s_x),.s_y(s_y),.s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_slope(m_slope),.m_intercept(m_intercept),
        .m_count(m_count),.m_degenerate(m_degenerate),.m_overflow(m_overflow),
        .m_saturated(m_saturated),.m_spread(spread_unused),.m_tag(m_tag)
    );
endmodule
