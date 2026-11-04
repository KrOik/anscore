// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module compatibility_count8(
    input wire clk,rst,s_valid,output wire s_ready,input wire [7:0] s_row,
    input wire s_keep,s_last,s_error,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [15:0] m_value,
    output wire [2:0] m_error,output wire [3:0] m_rows,output wire [7:0] m_tag
);
    exact_binary_permanent core(.*);
endmodule
