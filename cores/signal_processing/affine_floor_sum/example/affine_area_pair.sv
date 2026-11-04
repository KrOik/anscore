// SPDX-License-Identifier: Apache-2.0
// Independent default and maximum-width analytic staircase-area services.
module affine_area_pair (
    input wire clk, rst,
    input wire s8_valid, output wire s8_ready,
    input wire [7:0] s8_n, s8_a, s8_b, s8_m, s8_tag,
    output wire m8_valid, input wire m8_ready,
    output wire [23:0] m8_sum, output wire m8_error,
    output wire [7:0] m8_tag,
    input wire s16_valid, output wire s16_ready,
    input wire [15:0] s16_n, s16_a, s16_b, s16_m,
    input wire [31:0] s16_tag,
    output wire m16_valid, input wire m16_ready,
    output wire [47:0] m16_sum, output wire m16_error,
    output wire [31:0] m16_tag
);
    affine_floor_sum default_area (
        .clk(clk), .rst(rst), .s_valid(s8_valid), .s_ready(s8_ready),
        .s_n(s8_n), .s_a(s8_a), .s_b(s8_b), .s_m(s8_m), .s_tag(s8_tag),
        .m_valid(m8_valid), .m_ready(m8_ready), .m_sum(m8_sum),
        .m_error(m8_error), .m_tag(m8_tag)
    );
    affine_floor_sum #(.W(16), .TAG_W(32)) full_area (
        .clk(clk), .rst(rst), .s_valid(s16_valid), .s_ready(s16_ready),
        .s_n(s16_n), .s_a(s16_a), .s_b(s16_b), .s_m(s16_m), .s_tag(s16_tag),
        .m_valid(m16_valid), .m_ready(m16_ready), .m_sum(m16_sum),
        .m_error(m16_error), .m_tag(m16_tag)
    );
endmodule
