// SPDX-License-Identifier: Apache-2.0
// Full-port standalone 32x24 HDR adapter, with explicit CE-qualified endpoints.
module hdr32_example(
    input wire clk,rst_n,ce,start_valid,abort,
    output wire start_ready,input wire [11:0] start_key_q8,input wire [7:0] start_tag,
    input wire s_valid,output wire s_ready,input wire [47:0] s_rgb,
    input wire s_sof,s_eol,s_last,output wire m_valid,input wire m_ready,
    output wire [23:0] m_rgb,output wire [7:0] m_x,m_y,
    output wire m_sof,m_eol,m_last,output wire [7:0] m_tag,output wire [23:0] m_exposure,
    output wire done_valid,input wire done_ready,output wire [1:0] done_error,
    output wire [7:0] done_tag,output wire [14:0] done_count,
    output wire [31:0] done_sum_max,output wire [23:0] done_exposure
);
    frame_adaptive_rgb_tonemap #(.WIDTH(32),.HEIGHT(24),.TAG_W(8)) u_core(.*);
endmodule
