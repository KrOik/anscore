// SPDX-License-Identifier: Apache-2.0
module deblock_edge_example(
    input wire clk,rst,s_valid, output wire s_ready,
    input wire [63:0] s_pixels,input wire [2:0] s_bs,
    input wire [7:0] s_alpha,s_beta,input wire [4:0] s_tc0,
    input wire [7:0] s_tag,input wire s_last,
    output wire m_valid,input wire m_ready,output wire [63:0] m_pixels,
    output wire m_error,m_changed,output wire [7:0] m_tag,output wire m_last
);
    h264_luma_deblock_edge #(.TAG_W(8)) core(.*);
endmodule
