// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Actual unchanged CE-only gray core with a single owned-token adapter.
module rgb_palette_diffusion #(parameter integer WIDTH=128,HEIGHT=64,TAG_W=8)(
    input wire clk,rst,input wire c_valid,output wire c_ready,
    input wire [7:0] c_low,c_high,input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,input wire [23:0] s_rgb,
    input wire s_sof,s_eol,s_last,
    output wire m_valid,input wire m_ready,output wire [7:0] m_data,
    output wire m_code,m_sof,m_eol,m_last,output wire [15:0] m_x,m_y,
    output wire [TAG_W-1:0] m_tag,
    output wire d_valid,input wire d_ready,output wire [1:0] d_error,
    output wire [TAG_W-1:0] d_tag
);
    wire g_valid,g_ready,core_command_ready;wire [7:0] gray;
    reg sof,eol,last;
    assign s_ready=!rst&&g_ready&&!g_valid;
    assign c_ready=!rst&&!g_valid&&core_command_ready;
    wire take=s_valid&&s_ready;
    wire consume=g_valid&&g_ready&&!rst;
    // No lookahead: a source token is accepted only into an empty gray slot
    // while the diffuser is requesting its next pixel. Fault/DONE cannot own
    // a later gray token; configuration cannot cross the held output fence.
    isp_rgb2gray grayscale(.clk(clk),.clk_en(take||consume),.rst_n(!rst),
        .pix24(s_rgb),.pix_valid(take),.new_line(s_eol),
        .pix_out(gray),.out_valid(g_valid),.nl_out());
    always @(posedge clk)begin
        if(rst)begin sof<=0;eol<=0;last<=0;end
        else if(take)begin sof<=s_sof;eol<=s_eol;last<=s_last;end
    end
    causal_palette_diffusion #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(8),.TAG_W(TAG_W)) diffuser(
        .clk(clk),.rst(rst),.c_valid(c_valid&&!g_valid),.c_ready(core_command_ready),
        .c_low(c_low),.c_high(c_high),.c_tag(c_tag),
        .s_valid(g_valid),.s_ready(g_ready),.s_data(gray),.s_sof(sof),.s_eol(eol),.s_last(last),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_code(m_code),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_x(m_x),.m_y(m_y),.m_tag(m_tag),
        .d_valid(d_valid),.d_ready(d_ready),.d_error(d_error),.d_tag(d_tag));
endmodule
