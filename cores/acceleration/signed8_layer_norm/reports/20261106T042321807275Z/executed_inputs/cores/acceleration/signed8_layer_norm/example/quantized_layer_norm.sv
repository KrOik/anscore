// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Actual signed32 -> elastic RNE signed8 quantizer -> centered normalization.
module quantized_layer_norm #(
    parameter integer MAX_LEN=8,FRAC=12,TAG_W=16
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire [1:0] c_op,input wire [15:0] c_index,
    input wire signed [15:0] c_gamma,c_beta,input wire [4:0] c_shift,
    output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
    input wire cmd_valid,output wire cmd_ready,
    input wire [15:0] cmd_len,cmd_epsilon,input wire [4:0] cmd_input_shift,
    input wire [TAG_W-1:0] cmd_tag,
    input wire s_valid,output wire s_ready,
    input wire signed [31:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
    output wire [15:0] m_index,output wire m_last,output wire [2:0] m_error,
    output wire m_clip,m_inexact,m_degenerate,
    output wire [TAG_W-1:0] m_tag,
    output reg m_input_clip,m_input_inexact
);
    reg owned,pending;
    reg [4:0] input_shift;
    wire norm_cmd_ready,norm_s_ready,norm_c_ready,quant_ready,quant_valid;
    wire quant_clip,quant_inexact,quant_last;
    wire [7:0] quant_data;
    assign c_ready=!rst && !owned && norm_c_ready;
    assign cmd_ready=!rst && !owned && norm_cmd_ready;
    assign s_ready=!rst && owned && !pending && norm_s_ready && quant_ready;
    stream_requantize #(.IN_W(32),.OUT_W(8),.TAG_W(1)) input_quantizer(
        .clk(clk),.rst(rst),.s_valid(s_valid && s_ready),.s_ready(quant_ready),
        .s_data(s_data),.s_shift({1'b0,input_shift}),.s_tag(s_last),
        .m_valid(quant_valid),.m_ready(norm_s_ready && owned),.m_data(quant_data),
        .m_clip(quant_clip),.m_inexact(quant_inexact),.m_tag(quant_last));
    signed8_layer_norm #(.MAX_LEN(MAX_LEN),.FRAC(FRAC),.TAG_W(TAG_W)) normalize(
        .clk(clk),.rst(rst),.c_valid(c_valid && !owned),.c_ready(norm_c_ready),
        .c_op(c_op),.c_index(c_index),.c_gamma(c_gamma),.c_beta(c_beta),.c_shift(c_shift),
        .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
        .cmd_valid(cmd_valid && !owned),.cmd_ready(norm_cmd_ready),
        .cmd_len(cmd_len),.cmd_epsilon(cmd_epsilon),.cmd_tag(cmd_tag),
        .s_valid(quant_valid && owned),.s_ready(norm_s_ready),.s_data(quant_data),.s_last(quant_last),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_index(m_index),
        .m_last(m_last),.m_error(m_error),.m_clip(m_clip),.m_inexact(m_inexact),
        .m_degenerate(m_degenerate),.m_tag(m_tag));
    always @(posedge clk)begin
        if(rst)begin owned<=0;pending<=0;input_shift<=0;m_input_clip<=0;m_input_inexact<=0;end
        else begin
            if(cmd_valid && cmd_ready)begin
                owned<=1;input_shift<=cmd_input_shift;m_input_clip<=0;m_input_inexact<=0;
            end
            if(s_valid && s_ready)pending<=1;
            if(quant_valid && norm_s_ready && owned)begin
                pending<=0;m_input_clip<=m_input_clip || quant_clip;
                m_input_inexact<=m_input_inexact || quant_inexact;
            end
            if(m_valid && m_ready && m_last)owned<=0;
        end
    end
endmodule
