// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module suffix32(
    input wire clk,input wire rst,input wire s_valid,output wire s_ready,
    input wire [7:0] s_symbol,input wire s_keep,input wire s_last,input wire s_error,
    input wire [7:0] s_tag,output wire m_valid,input wire m_ready,
    output wire [31:0] m_suffix,output wire [31:0] m_lcp,output wire [31:0] m_rank,
    output wire [31:0] m_count,output wire m_keep,output wire m_first,output wire m_last,
    output wire [1:0] m_error,output wire [7:0] m_tag
);
    suffix_array_lcp #(.MAX_SYMBOLS(32),.SYMBOL_W(8),.TAG_W(8)) core(.*);
endmodule
