// SPDX-License-Identifier: Apache-2.0
module huffman_frame_encoder (
    input wire clk, rst,
    input wire cfg_valid, output wire cfg_ready, input wire [1:0] cfg_op,
    input wire [31:0] cfg_symbol, cfg_length, input wire [7:0] cfg_tag,
    output wire cfg_r_valid, input wire cfg_r_ready,
    output wire [1:0] cfg_r_op, output wire [2:0] cfg_r_status,
    output wire [15:0] cfg_r_code, output wire [31:0] cfg_r_length,
    output wire [7:0] cfg_r_tag,
    input wire c_valid, output wire c_ready,
    input wire [31:0] c_count, input wire [7:0] c_tag,
    input wire s_valid, output wire s_ready, input wire [31:0] s_symbol,
    output wire m_valid, input wire m_ready, output wire [7:0] m_data,
    output wire m_last, output wire [3:0] m_valid_bits, output wire [7:0] m_tag,
    output wire d_valid, input wire d_ready, output wire [2:0] d_status,
    output wire [31:0] d_error_index, d_bits, output wire [7:0] d_tag
);
    canonical_huffman_encoder encoder (.*);
endmodule
