// SPDX-License-Identifier: Apache-2.0
// Every public port of the default 4-lane, 256-word service is exposed.
module vector_ram4(
    input wire clk, rst_n,
    input wire s_valid, output wire s_ready,
    input wire [3:0] s_mask, s_write,
    input wire [127:0] s_address, s_data,
    input wire [7:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire [1:0] m_status,
    output wire [3:0] m_mask, m_error_mask,
    output wire [127:0] m_data,
    output wire [7:0] m_tag,
    output wire [2:0] m_accesses, m_rounds
);
    vector_banked_scratchpad #(.LANES(4),.BANKS(4),.WORDS(64),.DATA_W(32),.TAG_W(8)) core(
        .clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_ready(s_ready),
        .s_mask(s_mask),.s_write(s_write),.s_address(s_address),.s_data(s_data),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_mask(m_mask),
        .m_error_mask(m_error_mask),.m_data(m_data),.m_tag(m_tag),
        .m_accesses(m_accesses),.m_rounds(m_rounds));
endmodule
