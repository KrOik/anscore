// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module indexed_bilinear_porter_duff #(
    parameter integer TEX_WIDTH=8,TEX_HEIGHT=8,TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [1:0] c_op,input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output wire [1:0] r_status,
    output wire [TAG_W-1:0] r_tag,output wire [16:0] r_tex_count,output wire [8:0] r_pal_count,
    input wire t_valid,output wire t_ready,input wire [7:0] t_index,
    input wire p_valid,output wire p_ready,input wire [31:0] p_argb,
    input wire s_valid,output wire s_ready,input wire [15:0] s_u,s_v, // unsigned Q8.8
    input wire [31:0] s_dst,input wire [3:0] s_mode, // premultiplied {R,G,B,A}
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [31:0] m_rgba,
    output wire [1:0] m_error,output wire [3:0] m_mode,output wire m_oob,
    output wire [15:0] m_x,m_y,output wire [TAG_W-1:0] m_tag,
    output wire resident,busy
);
    localparam [2:0] IDLE=0,SEND=1,WAIT_SAMPLE=2,SEND_FILTER=3,WAIT_FILTER=4,WAIT_COMPOSE=5;
    reg [2:0] state;
    reg [1:0] tap;
    reg [7:0] u0,u1,v0,v1,fx,fy;
    reg [31:0] quad[0:3],destination;
    reg [15:0] x,y;
    reg [TAG_W-1:0] tag;
    reg [3:0] mode;
    reg oob;
    wire tex_busy,tex_c_ready,tex_r_valid,tex_s_ready,tex_m_valid,tex_t_ready,tex_p_ready;
    wire [23:0] tex_rgb;wire [7:0] tex_alpha;
    wire filter_ready,filter_valid,filter_busy,pd_ready,pd_valid,pd_busy;
    wire [31:0] filtered;
    wire management_open=state==IDLE && !tex_busy && !filter_busy && !pd_busy;
    assign c_ready=!rst && management_open && tex_c_ready;
    assign r_valid=tex_r_valid;
    assign t_ready=!rst && management_open && tex_t_ready;
    assign p_ready=!rst && management_open && tex_p_ready;
    assign s_ready=!rst && state==IDLE && resident && !c_valid && !tex_r_valid
                   && !tex_busy && !filter_busy && !pd_busy;
    assign m_valid=!rst && state==WAIT_COMPOSE && pd_valid;
    assign m_oob=oob;
    assign busy=!rst && state!=IDLE;
    indexed_texture_sampler #(.TEX_WIDTH(TEX_WIDTH),.TEX_HEIGHT(TEX_HEIGHT),.TAG_W(TAG_W)) sampler(
        .clk(clk),.rst(rst),.c_valid(c_valid && management_open),.c_ready(tex_c_ready),.c_op(c_op),.c_tag(c_tag),
        .r_valid(tex_r_valid),.r_ready(r_ready),.r_status(r_status),.r_tag(r_tag),
        .r_tex_count(r_tex_count),.r_pal_count(r_pal_count),
        .t_valid(t_valid && management_open),.t_ready(tex_t_ready),.t_index(t_index),
        .p_valid(p_valid && management_open),.p_ready(tex_p_ready),.p_rgba(p_argb),
        .s_valid(state==SEND),.s_ready(tex_s_ready),.s_u(tap[0]?u1:u0),.s_v(tap[1]?v1:v0),
        .s_x(x),.s_y(y),.s_tag(tag),.m_valid(tex_m_valid),.m_ready(state==WAIT_SAMPLE),
        .m_rgb(tex_rgb),.m_alpha(tex_alpha),.m_visible(),.m_reason(),.m_x(),.m_y(),.m_tag(),
        .resident(resident),.pipeline_busy(tex_busy));
    rgba_bilinear_coverage #(.TAG_W(TAG_W)) filter(
        .clk(clk),.rst(rst),.s_valid(state==SEND_FILTER),.s_ready(filter_ready),
        .s_00(quad[0]),.s_10(quad[1]),.s_01(quad[2]),.s_11(quad[3]),.s_fx(fx),.s_fy(fy),
        .s_x(x),.s_y(y),.s_tag(tag),.m_valid(filter_valid),.m_ready(state==WAIT_FILTER && pd_ready),
        .m_rgba(filtered),.m_x(),.m_y(),.m_tag(),.busy(filter_busy));
    rgba_porter_duff #(.TAG_W(TAG_W)) composition(
        .clk(clk),.rst(rst),.s_valid(state==WAIT_FILTER && filter_valid),.s_ready(pd_ready),
        .s_src(filtered),.s_dst(destination),.s_mode(mode),.s_x(x),.s_y(y),.s_tag(tag),
        .m_valid(pd_valid),.m_ready(state==WAIT_COMPOSE && m_ready),.m_rgba(m_rgba),
        .m_error(m_error),.m_mode(m_mode),.m_x(m_x),.m_y(m_y),.m_tag(m_tag),.pipeline_busy(pd_busy));
    integer k;
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;tap<=0;u0<=0;u1<=0;v0<=0;v1<=0;fx<=0;fy<=0;
            x<=0;y<=0;tag<=0;mode<=0;destination<=0;oob<=0;
            for(k=0;k<4;k=k+1)quad[k]<=0;
        end else case(state)
            IDLE:if(s_valid && s_ready)begin
                u0<=s_u[15:8];v0<=s_v[15:8];
                u1<=s_u[15:8]<TEX_WIDTH-1 ? s_u[15:8]+8'd1 : s_u[15:8];
                v1<=s_v[15:8]<TEX_HEIGHT-1 ? s_v[15:8]+8'd1 : s_v[15:8];
                fx<=s_u[7:0];fy<=s_v[7:0];x<=s_x;y<=s_y;tag<=s_tag;
                destination<=s_dst;mode<=s_mode;tap<=0;
                oob<=s_u[15:8]>=TEX_WIDTH || s_v[15:8]>=TEX_HEIGHT;
                for(k=0;k<4;k=k+1)quad[k]<=0;
                state<=s_u[15:8]>=TEX_WIDTH || s_v[15:8]>=TEX_HEIGHT ? SEND_FILTER : SEND;
            end
            SEND:if(tex_s_ready)state<=WAIT_SAMPLE;
            WAIT_SAMPLE:if(tex_m_valid)begin
                quad[tap]<={tex_alpha,tex_rgb};
                if(tap==3)state<=SEND_FILTER;
                else begin tap<=tap+1'b1;state<=SEND;end
            end
            SEND_FILTER:if(filter_ready)state<=WAIT_FILTER;
            WAIT_FILTER:if(filter_valid && pd_ready)state<=WAIT_COMPOSE;
            WAIT_COMPOSE:if(pd_valid && m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
