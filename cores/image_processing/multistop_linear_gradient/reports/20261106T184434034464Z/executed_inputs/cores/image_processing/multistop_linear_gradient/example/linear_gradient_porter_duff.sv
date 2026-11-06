// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module linear_gradient_porter_duff #(parameter integer MAX_STOPS=16,TAG_W=8)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [1:0] c_op,
    input wire [31:0] c_count,input wire [1:0] c_spread,
    input wire signed [17:0] c_x0,c_y0,c_x1,c_y1,input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output wire [2:0] r_status,
    output wire [31:0] r_count,output wire [TAG_W-1:0] r_tag,
    input wire t_valid,output wire t_ready,input wire [16:0] t_offset,input wire [31:0] t_rgba,
    input wire s_valid,output wire s_ready,input wire signed [17:0] s_px,s_py,
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    input wire [31:0] s_dst,input wire [3:0] s_mode,
    output wire m_valid,input wire m_ready,output wire [31:0] m_rgba,
    output wire [1:0] m_error,output wire [3:0] m_mode,output wire [15:0] m_x,m_y,
    output wire [TAG_W-1:0] m_tag,output reg m_degenerate,
    output wire configured,loading,busy
);
    localparam [1:0] IDLE=0,PAINT=1,COMPOSE=2;
    reg [1:0] state;
    reg [31:0] destination;
    reg [3:0] blend_mode;
    wire gc_ready,gt_ready,gs_ready,gm_valid,gm_ready,gbusy,pbusy,pready,pvalid;
    wire [31:0] paint;
    wire [15:0] gx,gy;
    wire [TAG_W-1:0] gtag;
    wire degenerate;
    wire management_open=state==IDLE && !pbusy;
    assign c_ready=!rst && management_open && gc_ready;
    assign t_ready=!rst && management_open && gt_ready;
    assign s_ready=!rst && state==IDLE && !c_valid && gs_ready;
    assign busy=!rst && (state!=IDLE || gbusy || pbusy);
    assign gm_ready=!rst && state==PAINT && pready;
    assign m_valid=!rst && state==COMPOSE && pvalid;
    multistop_linear_gradient #(.MAX_STOPS(MAX_STOPS),.TAG_W(TAG_W)) gradient(
        .clk(clk),.rst(rst),.c_valid(c_valid && management_open),.c_ready(gc_ready),
        .c_op(c_op),.c_count(c_count),.c_spread(c_spread),.c_x0(c_x0),.c_y0(c_y0),
        .c_x1(c_x1),.c_y1(c_y1),.c_tag(c_tag),.r_valid(r_valid),.r_ready(r_ready),
        .r_status(r_status),.r_count(r_count),.r_tag(r_tag),
        .t_valid(t_valid && management_open),.t_ready(gt_ready),.t_offset(t_offset),.t_rgba(t_rgba),
        .s_valid(s_valid && state==IDLE && !c_valid),.s_ready(gs_ready),.s_px(s_px),.s_py(s_py),
        .s_x(s_x),.s_y(s_y),.s_tag(s_tag),.m_valid(gm_valid),.m_ready(gm_ready),
        .m_rgba(paint),.m_x(gx),.m_y(gy),.m_tag(gtag),.m_degenerate(degenerate),
        .configured(configured),.loading(loading),.busy(gbusy));
    rgba_porter_duff #(.TAG_W(TAG_W)) blend(
        .clk(clk),.rst(rst),.s_valid(state==PAINT && gm_valid),.s_ready(pready),
        .s_src(paint),.s_dst(destination),.s_mode(blend_mode),.s_x(gx),.s_y(gy),.s_tag(gtag),
        .m_valid(pvalid),.m_ready(state==COMPOSE && m_ready),.m_rgba(m_rgba),
        .m_error(m_error),.m_mode(m_mode),.m_x(m_x),.m_y(m_y),.m_tag(m_tag),.pipeline_busy(pbusy));
    always @(posedge clk)begin
        if(rst)begin state<=IDLE;destination<=0;blend_mode<=0;m_degenerate<=0;end
        else case(state)
            IDLE:if(s_valid && s_ready)begin destination<=s_dst;blend_mode<=s_mode;state<=PAINT;end
            PAINT:if(gm_valid && gm_ready)begin m_degenerate<=degenerate;state<=COMPOSE;end
            COMPOSE:if(m_valid && m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
