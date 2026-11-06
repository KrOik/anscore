// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Actual unchanged affine raster -> indexed sampler -> RGB/Z framebuffer chain.
module indexed_triangle_frame #(
    parameter integer WIDTH=32,HEIGHT=32,TEX_WIDTH=16,TEX_HEIGHT=16,TAG_W=8
)(
    input wire clk,rst,
    input wire tex_c_valid,output wire tex_c_ready,input wire [1:0] tex_c_op,input wire [TAG_W-1:0] tex_c_tag,
    output wire tex_r_valid,input wire tex_r_ready,output wire [1:0] tex_r_status,
    output wire [TAG_W-1:0] tex_r_tag,output wire [16:0] tex_r_tex_count,output wire [8:0] tex_r_pal_count,
    input wire t_valid,output wire t_ready,input wire [7:0] t_index,
    input wire p_valid,output wire p_ready,input wire [31:0] p_rgba,
    output wire texture_resident,
    input wire begin_valid,output wire begin_ready,input wire [23:0] begin_rgb,
    input wire [15:0] begin_depth,input wire [TAG_W-1:0] begin_tag,
    input wire c_valid,output wire c_ready,
    input wire signed [9:0] c_x0,c_y0,c_x1,c_y1,c_x2,c_y2,
    input wire [7:0] c_u0,c_v0,c_u1,c_v1,c_u2,c_v2,input wire [TAG_W-1:0] c_tag,
    input wire [15:0] c_depth,input wire [1:0] c_depth_func,
    input wire c_depth_write,input wire [2:0] c_color_write,
    output wire tri_done_valid,input wire tri_done_ready,output wire [1:0] tri_done_status,
    output wire [16:0] tri_done_covered,output wire [16:0] tri_done_visible,
    output wire [TAG_W-1:0] tri_done_tag,
    input wire end_valid,output wire end_ready,
    output wire m_valid,input wire m_ready,output wire [23:0] m_rgb,output wire [15:0] m_depth,
    output wire [7:0] m_x,m_y,output wire m_sof,m_eol,m_last,output wire [TAG_W-1:0] m_tag,
    output wire done_valid,input wire done_ready,output wire [TAG_W-1:0] done_tag,
    output wire [31:0] done_seen,done_passed,done_oob,output wire done_count_overflow
);
    reg frame_live,tri_owned;
    reg [15:0] depth;
    reg [1:0] depth_func;
    reg depth_write;
    reg [2:0] color_write;
    reg [1:0] in_flight;
    reg [16:0] visible_count;
    wire raster_ready,rv,rr,rdv,rdr,unused_first;
    wire [7:0] rx,ry;wire [23:0] uv;wire [TAG_W-1:0] rt;
    wire sample_valid,sample_ready,sample_visible,sample_busy;
    wire [23:0] sample_rgb;wire [7:0] sample_alpha;
    wire [15:0] sample_x,sample_y;wire [TAG_W-1:0] sample_tag;wire [1:0] sample_reason;
    wire store_fragment_ready,store_end_ready,sampler_c_ready;
    wire admit=frame_live && texture_resident && !tri_owned && !end_valid && !tex_c_valid &&
               !tex_r_valid && store_fragment_ready && !sample_busy;
    assign c_ready=!rst && admit && raster_ready;
    assign tex_c_ready=sampler_c_ready && !tri_owned;
    assign sample_ready=!sample_visible || store_fragment_ready;
    assign tri_done_valid=!rst && tri_owned && rdv && in_flight==0;
    assign rdr=tri_done_ready && tri_owned && in_flight==0;
    assign tri_done_visible=visible_count;
    assign end_ready=store_end_ready && !tri_owned && !sample_busy;
    wire accepted_lookup=rv && rr;
    wire retired_sample=sample_valid && sample_ready;
    always @(posedge clk)begin
        if(rst)begin
            frame_live<=0;tri_owned<=0;depth<=0;depth_func<=0;depth_write<=0;color_write<=0;
            in_flight<=0;visible_count<=0;
        end else begin
            if(begin_valid && begin_ready)frame_live<=1;
            if(done_valid && done_ready)frame_live<=0;
            if(c_valid && c_ready)begin
                tri_owned<=1;depth<=c_depth;depth_func<=c_depth_func;
                depth_write<=c_depth_write;color_write<=c_color_write;visible_count<=0;
            end
            if(tri_done_valid && tri_done_ready)tri_owned<=0;
            case({accepted_lookup,retired_sample})
                2'b10:in_flight<=in_flight+1'b1;
                2'b01:in_flight<=in_flight-1'b1;
                default:begin end
            endcase
            if(retired_sample && sample_visible)visible_count<=visible_count+1'b1;
        end
    end
    triangle_rgb_raster #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) raster(
        .clk(clk),.rst(rst),.c_valid(c_valid && admit),.c_ready(raster_ready),
        .c_x0(c_x0),.c_y0(c_y0),.c_x1(c_x1),.c_y1(c_y1),.c_x2(c_x2),.c_y2(c_y2),
        .c_rgb0({c_u0,c_v0,8'd0}),.c_rgb1({c_u1,c_v1,8'd0}),.c_rgb2({c_u2,c_v2,8'd0}),.c_tag(c_tag),
        .m_valid(rv),.m_ready(rr),.m_x(rx),.m_y(ry),.m_rgb(uv),.m_tag(rt),.m_first(unused_first),
        .d_valid(rdv),.d_ready(rdr),.d_status(tri_done_status),.d_count(tri_done_covered),.d_tag(tri_done_tag));
    indexed_texture_sampler #(.TEX_WIDTH(TEX_WIDTH),.TEX_HEIGHT(TEX_HEIGHT),.TAG_W(TAG_W)) sampler(
        .clk(clk),.rst(rst),.c_valid(tex_c_valid && !tri_owned),.c_ready(sampler_c_ready),.c_op(tex_c_op),.c_tag(tex_c_tag),
        .r_valid(tex_r_valid),.r_ready(tex_r_ready),.r_status(tex_r_status),.r_tag(tex_r_tag),
        .r_tex_count(tex_r_tex_count),.r_pal_count(tex_r_pal_count),
        .t_valid(t_valid),.t_ready(t_ready),.t_index(t_index),.p_valid(p_valid),.p_ready(p_ready),.p_rgba(p_rgba),
        .s_valid(rv),.s_ready(rr),.s_u(uv[23:16]),.s_v(uv[15:8]),
        .s_x({8'd0,rx}),.s_y({8'd0,ry}),.s_tag(rt),
        .m_valid(sample_valid),.m_ready(sample_ready),.m_rgb(sample_rgb),.m_alpha(sample_alpha),
        .m_visible(sample_visible),.m_reason(sample_reason),.m_x(sample_x),.m_y(sample_y),.m_tag(sample_tag),
        .resident(texture_resident),.pipeline_busy(sample_busy));
    fragment_rgb_depth_store #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) store(
        .clk(clk),.rst(rst),.begin_valid(begin_valid),.begin_ready(begin_ready),
        .begin_rgb(begin_rgb),.begin_depth(begin_depth),.begin_tag(begin_tag),
        .s_valid(sample_valid && sample_visible),.s_ready(store_fragment_ready),.s_x(sample_x),.s_y(sample_y),
        .s_depth(depth),.s_rgb(sample_rgb),.s_alpha(sample_alpha),.s_depth_func(depth_func),
        .s_depth_write(depth_write),.s_color_write(color_write),
        .end_valid(end_valid && !tri_owned && !sample_busy),.end_ready(store_end_ready),
        .m_valid(m_valid),.m_ready(m_ready),.m_rgb(m_rgb),.m_depth(m_depth),.m_x(m_x),.m_y(m_y),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_tag(m_tag),
        .done_valid(done_valid),.done_ready(done_ready),.done_tag(done_tag),
        .done_seen(done_seen),.done_passed(done_passed),.done_oob(done_oob),.done_count_overflow(done_count_overflow));
endmodule
