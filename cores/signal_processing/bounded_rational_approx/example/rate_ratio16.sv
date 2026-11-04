// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Runtime ratio planning only; this wrapper does not resample a signal.
module rate_ratio16 (
    input wire clk, rst, s_valid, output wire s_ready,
    input wire signed [15:0] s_num, input wire [15:0] s_den,
    input wire [7:0] s_limit, s_tag,
    output wire m_valid, input wire m_ready,
    output wire signed [24:0] m_num, output wire [7:0] m_den,
    output wire signed [16:0] m_error, output wire [1:0] m_status,
    output wire [7:0] m_tag
);
    bounded_rational_approx #(.W(16),.QW(8),.TAG_W(8)) core (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_num(s_num),.s_den(s_den),.s_limit(s_limit),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_num(m_num),.m_den(m_den),
        .m_error(m_error),.m_status(m_status),.m_tag(m_tag)
    );
endmodule
