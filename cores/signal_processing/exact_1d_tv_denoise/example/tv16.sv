// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Complete external interface at N=16, DATA_W=16, TAG_W=8.
module tv16 (
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire signed [15:0] s_data,
    input wire [15:0] s_lambda, input wire [7:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire signed [20:0] m_numerator,
    output wire [4:0] m_denominator,
    output wire [3:0] m_index, output wire m_last,
    output wire [7:0] m_tag
);
    exact_1d_tv_denoise #(.N(16), .DATA_W(16), .TAG_W(8)) core (
        .clk(clk), .rst(rst), .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_lambda(s_lambda), .s_tag(s_tag),
        .m_valid(m_valid), .m_ready(m_ready),
        .m_numerator(m_numerator), .m_denominator(m_denominator),
        .m_index(m_index), .m_last(m_last), .m_tag(m_tag)
    );
endmodule
`default_nettype wire
