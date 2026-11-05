// SPDX-License-Identifier: Apache-2.0
// Actual unchanged B33 raster -> coordinate RGB/Z store composition.
module triangle_depth64(
    input wire clk,rst,
    input wire begin_valid,output wire begin_ready,
    input wire [23:0] begin_rgb,input wire [15:0] begin_depth,input wire [7:0] begin_tag,
    input wire c_valid,output wire c_ready,
    input wire signed [9:0] c_x0,c_y0,c_x1,c_y1,c_x2,c_y2,
    input wire [23:0] c_rgb0,c_rgb1,c_rgb2,input wire [7:0] c_tag,
    input wire [15:0] c_depth,input wire [7:0] c_alpha,
    input wire [1:0] c_depth_func,input wire c_depth_write,input wire [2:0] c_color_write,
    output wire tri_done_valid,input wire tri_done_ready,
    output wire [1:0] tri_done_status,output wire [16:0] tri_done_count,output wire [7:0] tri_done_tag,
    input wire end_valid,output wire end_ready,
    output wire m_valid,input wire m_ready,output wire [23:0] m_rgb,output wire [15:0] m_depth,
    output wire [7:0] m_x,m_y,output wire m_sof,m_eol,m_last,output wire [7:0] m_tag,
    output wire done_valid,input wire done_ready,output wire [7:0] done_tag,
    output wire [31:0] done_seen,done_passed,done_oob,output wire done_count_overflow
);
    reg frame_live,tri_owned;
    reg [15:0] depth;
    reg [7:0] alpha;
    reg [1:0] depth_func;
    reg depth_write;
    reg [2:0] color_write;
    wire raster_ready,fragment_valid,fragment_ready,fragment_first;
    wire [7:0] fragment_x,fragment_y,fragment_tag;
    wire [23:0] fragment_rgb;
    wire store_end_ready;
    wire admit=frame_live&&!tri_owned&&!end_valid&&fragment_ready;
    assign c_ready=!rst&&admit&&raster_ready;
    assign end_ready=store_end_ready&&!tri_owned;
    always @(posedge clk) begin
        if(rst) begin frame_live<=0;tri_owned<=0;depth<=0;alpha<=0;depth_func<=0;depth_write<=0;color_write<=0;end
        else begin
            if(begin_valid&&begin_ready) frame_live<=1;
            if(done_valid&&done_ready) frame_live<=0;
            if(c_valid&&c_ready) begin
                tri_owned<=1;depth<=c_depth;alpha<=c_alpha;depth_func<=c_depth_func;
                depth_write<=c_depth_write;color_write<=c_color_write;
            end
            if(tri_done_valid&&tri_done_ready) tri_owned<=0;
        end
    end
    triangle_rgb_raster #(.WIDTH(64),.HEIGHT(64),.TAG_W(8)) raster(
        .clk(clk),.rst(rst),.c_valid(c_valid&&admit),.c_ready(raster_ready),
        .c_x0(c_x0),.c_y0(c_y0),.c_x1(c_x1),.c_y1(c_y1),.c_x2(c_x2),.c_y2(c_y2),
        .c_rgb0(c_rgb0),.c_rgb1(c_rgb1),.c_rgb2(c_rgb2),.c_tag(c_tag),
        .m_valid(fragment_valid),.m_ready(fragment_ready),.m_x(fragment_x),.m_y(fragment_y),
        .m_rgb(fragment_rgb),.m_tag(fragment_tag),.m_first(fragment_first),
        .d_valid(tri_done_valid),.d_ready(tri_done_ready),.d_status(tri_done_status),
        .d_count(tri_done_count),.d_tag(tri_done_tag));
    fragment_rgb_depth_store store(
        .clk(clk),.rst(rst),.begin_valid(begin_valid),.begin_ready(begin_ready),
        .begin_rgb(begin_rgb),.begin_depth(begin_depth),.begin_tag(begin_tag),
        .s_valid(fragment_valid),.s_ready(fragment_ready),.s_x({8'b0,fragment_x}),.s_y({8'b0,fragment_y}),
        .s_depth(depth),.s_rgb(fragment_rgb),.s_alpha(alpha),.s_depth_func(depth_func),
        .s_depth_write(depth_write),.s_color_write(color_write),
        .end_valid(end_valid&&!tri_owned),.end_ready(store_end_ready),
        .m_valid(m_valid),.m_ready(m_ready),.m_rgb(m_rgb),.m_depth(m_depth),.m_x(m_x),.m_y(m_y),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_tag(m_tag),
        .done_valid(done_valid),.done_ready(done_ready),.done_tag(done_tag),
        .done_seen(done_seen),.done_passed(done_passed),.done_oob(done_oob),.done_count_overflow(done_count_overflow));
endmodule
