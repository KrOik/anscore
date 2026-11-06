// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Actual existing isp_rgb2gray, with one owned CE/RV result slot and DONE fence.
module graded_luma_preview #(parameter integer WIDTH=128,HEIGHT=64,GRID_LOG2=3,TAG_W=8)(
    input wire clk,rst,
    input wire cfg_begin_valid,output wire cfg_begin_ready,
    input wire lut_valid,output wire lut_ready,input wire [23:0] lut_rgb,input wire lut_last,
    output wire cfg_rsp_valid,input wire cfg_rsp_ready,output wire [1:0] cfg_rsp_error,
    output wire configured,table_pending,
    input wire c_valid,output wire c_ready,input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,input wire [23:0] s_rgb,input wire s_sof,s_eol,s_last,
    output wire m_valid,input wire m_ready,output wire [7:0] m_luma,
    output reg m_sof,m_eol,m_last,output reg [15:0] m_x,m_y,output reg [TAG_W-1:0] m_tag,
    output wire d_valid,input wire d_ready,output wire [1:0] d_error,output wire [TAG_W-1:0] d_tag
);
    wire gv,gr,gray_valid,core_ready,core_done;
    wire [23:0] rgb; wire sof,eol,last; wire [15:0] x,y; wire [TAG_W-1:0] tag;
    wire take=!rst&&gv&&!gray_valid, consume=!rst&&gray_valid&&m_ready;
    assign gr=!rst&&!gray_valid;
    assign m_valid=!rst&&gray_valid;
    assign c_ready=!rst&&core_ready&&!gray_valid;
    assign d_valid=!rst&&core_done&&!gray_valid;
    tetrahedral_rgb_grade #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(8),.GRID_LOG2(GRID_LOG2),.TAG_W(TAG_W)) grade(
        .clk(clk),.rst(rst),.cfg_begin_valid(cfg_begin_valid),.cfg_begin_ready(cfg_begin_ready),
        .lut_valid(lut_valid),.lut_ready(lut_ready),.lut_rgb(lut_rgb),.lut_last(lut_last),
        .cfg_rsp_valid(cfg_rsp_valid),.cfg_rsp_ready(cfg_rsp_ready),.cfg_rsp_error(cfg_rsp_error),
        .configured(configured),.table_pending(table_pending),
        .c_valid(c_valid&&!gray_valid),.c_ready(core_ready),.c_tag(c_tag),
        .s_valid(s_valid),.s_ready(s_ready),.s_rgb(s_rgb),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
        .m_valid(gv),.m_ready(gr),.m_rgb(rgb),.m_sof(sof),.m_eol(eol),.m_last(last),
        .m_x(x),.m_y(y),.m_tag(tag),.d_valid(core_done),.d_ready(d_ready&&!gray_valid),.d_error(d_error),.d_tag(d_tag));
    isp_rgb2gray gray(.clk(clk),.clk_en(take||consume),.rst_n(!rst),.pix24(rgb),
        .pix_valid(take),.new_line(eol),.pix_out(m_luma),.out_valid(gray_valid),.nl_out());
    always @(posedge clk) begin
        if(rst) begin m_sof<=0; m_eol<=0; m_last<=0; m_x<=0; m_y<=0; m_tag<=0; end
        else if(take) begin m_sof<=sof; m_eol<=eol; m_last<=last; m_x<=x; m_y<=y; m_tag<=tag; end
    end
endmodule
