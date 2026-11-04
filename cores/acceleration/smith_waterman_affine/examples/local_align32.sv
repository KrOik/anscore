// SPDX-License-Identifier: Apache-2.0
// Default byte-symbol local alignment score service; both inputs pair by order.
module local_align32(
    input wire clk,rst,
    input wire a_valid,output wire a_ready,input wire [7:0] a_char,
    input wire a_keep,a_last,input wire [7:0] a_tag,
    input wire b_valid,output wire b_ready,input wire [7:0] b_char,
    input wire b_keep,b_last,
    output wire m_valid,input wire m_ready,output wire [6:0] m_score,
    output wire [5:0] m_a_end,m_b_end,m_a_length,m_b_length,
    output wire [1:0] m_error,output wire [7:0] m_tag
);
    smith_waterman_affine dut(.*);
endmodule
