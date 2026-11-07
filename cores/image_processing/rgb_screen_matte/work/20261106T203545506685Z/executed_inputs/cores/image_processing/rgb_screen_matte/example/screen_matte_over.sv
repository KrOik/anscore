// SPDX-License-Identifier: Apache-2.0
// Original atomic foreground/background rendezvous and production composition.
`timescale 1ns/1ps
module screen_matte_over #(parameter integer TAG_W=8)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [23:0] s_rgb,s_key,
    input wire [18:0] s_inner2,s_outer2,
    input wire [7:0] s_strength,input wire s_blue,
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    input wire s_sof,s_eol,s_last,
    input wire d_valid,output wire d_ready,input wire [31:0] d_rgba,
    output wire m_valid,input wire m_ready,
    output wire [31:0] m_rgba,output wire [2:0] m_error,
    output wire [15:0] m_x,m_y,output wire [TAG_W-1:0] m_tag,
    output wire m_sof,m_eol,m_last,output wire pipeline_busy
);
    wire matte_ready,matte_valid,matte_error,matte_busy,blend_busy;
    wire [31:0] matte_rgba,background;
    wire [15:0] matte_x,matte_y;
    wire [TAG_W-1:0] matte_tag;
    wire matte_sof,matte_eol,matte_last;
    wire blend_ready;
    assign s_ready=!rst && d_valid && matte_ready;
    assign d_ready=!rst && s_valid && matte_ready;
    rgb_screen_matte #(.TAG_W(TAG_W)) matte(
        .clk(clk),.rst(rst),.s_valid(s_valid && d_valid),.s_ready(matte_ready),
        .s_rgb(s_rgb),.s_key(s_key),.s_inner2(s_inner2),.s_outer2(s_outer2),
        .s_strength(s_strength),.s_blue(s_blue),.s_x(s_x),.s_y(s_y),.s_tag(s_tag),
        .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_user(d_rgba),
        .m_valid(matte_valid),.m_ready(blend_ready),.m_rgba(matte_rgba),
        .m_error(matte_error),.m_x(matte_x),.m_y(matte_y),.m_tag(matte_tag),
        .m_sof(matte_sof),.m_eol(matte_eol),.m_last(matte_last),.m_user(background),
        .pipeline_busy(matte_busy)
    );
    wire [31:0] blend_rgba;
    wire [1:0] blend_error;
    wire [TAG_W+3:0] blend_tag;
    wire config_error;
    wire [3:0] unused_mode;
    rgba_porter_duff #(.TAG_W(TAG_W+4)) blend(
        .clk(clk),.rst(rst),.s_valid(matte_valid),.s_ready(blend_ready),
        .s_src(matte_rgba),.s_dst(background),.s_mode(4'd3),
        .s_x(matte_x),.s_y(matte_y),
        .s_tag({matte_error,matte_sof,matte_eol,matte_last,matte_tag}),
        .m_valid(m_valid),.m_ready(m_ready),.m_rgba(blend_rgba),.m_error(blend_error),
        .m_mode(unused_mode),.m_x(m_x),.m_y(m_y),.m_tag(blend_tag),
        .pipeline_busy(blend_busy)
    );
    assign {config_error,m_sof,m_eol,m_last,m_tag}=blend_tag;
    assign m_error={config_error,blend_error};
    assign m_rgba=config_error ? 32'd0 : blend_rgba;
    assign pipeline_busy=!rst && (matte_busy || blend_busy);
    initial if(TAG_W<1 || TAG_W>28) $fatal(1,"screen_matte_over TAG_W must be 1..28");
endmodule
