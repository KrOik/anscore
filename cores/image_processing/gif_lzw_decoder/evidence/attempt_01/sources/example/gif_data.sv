// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module gif_data(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [7:0] s_data,input wire s_last,s_bad,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [7:0] m_index,m_tag,
    output wire done_valid,input wire done_ready,output wire [4:0] done_errors,
    output wire [31:0] done_count,output wire [7:0] done_min_code_size,done_tag
);
    gif_lzw_decoder #(.COUNT_W(32),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
