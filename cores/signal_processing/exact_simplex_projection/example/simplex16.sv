// SPDX-License-Identifier: Apache-2.0
module simplex16 (
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire signed [15:0] s_data,
    input wire [15:0] s_mass,
    input wire [7:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire [19:0] m_numerator,
    output wire [4:0] m_denominator,
    output wire [3:0] m_index,
    output wire m_last,
    output wire [7:0] m_tag
);
    exact_simplex_projection #(.N(16),.DATA_W(16),.TAG_W(8)) core (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_mass(s_mass),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_numerator(m_numerator),
        .m_denominator(m_denominator),.m_index(m_index),.m_last(m_last),.m_tag(m_tag)
    );
endmodule
