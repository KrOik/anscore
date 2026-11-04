// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Fixed 16-sample signed16 source; intermediate coefficients stay signed18.
module cdf53_roundtrip (
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire signed [15:0] s_data,
    output wire m_valid,
    input wire m_ready,
    output wire signed [17:0] m_data,
    output wire m_last, m_error
);
    wire c_valid, c_ready, c_last, c_error;
    wire signed [17:0] c_data;
    cdf53_block #(.SAMPLE_W(16),.BLOCK_LEN(16),.INVERSE(0)) forward (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_data({{2{s_data[15]}},s_data}),.m_valid(c_valid),.m_ready(c_ready),
        .m_data(c_data),.m_last(c_last),.m_error(c_error)
    );
    // Exactly 16 coefficients per block; no CE-qualified handshake adapters.
    cdf53_block #(.SAMPLE_W(16),.BLOCK_LEN(16),.INVERSE(1)) inverse (
        .clk(clk),.rst(rst),.s_valid(c_valid),.s_ready(c_ready),
        .s_data(c_data),.m_valid(m_valid),.m_ready(m_ready),
        .m_data(m_data),.m_last(m_last),.m_error(m_error)
    );
endmodule
