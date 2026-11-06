// SPDX-License-Identifier: Apache-2.0
// Original coverage raster -> exact perspective UV -> original resident sampler.
`default_nettype none
module perspective_indexed_triangle #(
    parameter integer WIDTH=64,HEIGHT=64,TEX_WIDTH=64,TEX_HEIGHT=64,Q_W=16,TAG_W=8
)(
    input wire clk,rst,
    input wire tex_c_valid,output wire tex_c_ready,input wire [1:0] tex_c_op,
    input wire [TAG_W-1:0] tex_c_tag,
    output wire tex_r_valid,input wire tex_r_ready,output wire [1:0] tex_r_status,
    output wire [TAG_W-1:0] tex_r_tag,
    output wire [16:0] tex_r_tex_count,output wire [8:0] tex_r_pal_count,
    input wire i_valid,output wire i_ready,input wire [7:0] i_index,
    input wire p_valid,output wire p_ready,input wire [31:0] p_rgba,
    output wire texture_resident,
    input wire c_valid,output wire c_ready,
    input wire signed [9:0] c_x0,c_y0,c_x1,c_y1,c_x2,c_y2,
    input wire [7:0] c_u0,c_v0,c_u1,c_v1,c_u2,c_v2,
    input wire [Q_W-1:0] c_q0,c_q1,c_q2,input wire [TAG_W-1:0] c_tag,
    output wire m_valid,input wire m_ready,output wire [7:0] m_x,m_y,
    output wire [23:0] m_rgb,output wire [7:0] m_alpha,
    output wire m_visible,output wire [2:0] m_reason,output wire m_first,
    output wire [TAG_W-1:0] m_tag,
    output wire d_valid,input wire d_ready,output reg [1:0] d_status,
    output reg [16:0] d_count,output reg [TAG_W-1:0] d_tag
);
    localparam [2:0] IDLE=0,CONFIG_SEND=1,CONFIG_WAIT=2,RASTER_SEND=3,RUN=4,DONE=5;
    reg [2:0] state;
    reg signed [9:0] x0,y0,x1,y1,x2,y2;
    reg [7:0] u0,v0,u1,v1,u2,v2;
    reg [Q_W-1:0] q0,q1,q2;
    reg [TAG_W-1:0] primitive_tag;
    wire project_c_ready,project_r_valid,project_s_ready,project_m_valid,project_m_ready;
    wire [1:0] project_status;
    wire [7:0] project_u,project_v,project_x,project_y;
    wire [TAG_W-1:0] project_tag;
    wire project_first,project_covered,project_configured,project_busy;
    wire raster_c_ready,raster_m_valid,raster_m_ready,raster_first,raster_d_valid,raster_d_ready;
    wire [7:0] raster_x,raster_y;
    wire [23:0] unused_rgb;
    wire [TAG_W-1:0] raster_tag,raster_d_tag;
    wire [1:0] raster_status;
    wire [16:0] raster_count;
    wire sample_c_ready,sample_t_ready,sample_p_ready,sample_s_ready,sample_m_valid,sample_busy;
    wire [23:0] sample_rgb;
    wire [7:0] sample_alpha;
    wire sample_visible;
    wire [1:0] sample_reason;
    wire [15:0] sample_x,sample_y;
    wire [TAG_W-1:0] sample_tag;
    reg fragment_owned,error_valid,fragment_first;
    reg [7:0] fragment_x,fragment_y;
    reg [TAG_W-1:0] fragment_tag;
    assign tex_c_ready=!rst&&state==IDLE&&sample_c_ready;
    assign i_ready=state==IDLE&&sample_t_ready;
    assign p_ready=state==IDLE&&sample_p_ready;
    // Offered management has priority. An unaccepted triangle never blocks loading.
    assign c_ready=!rst&&state==IDLE&&texture_resident&&!tex_c_valid&&!tex_r_valid&&
        project_c_ready&&raster_c_ready;
    assign raster_m_ready=state==RUN&&!fragment_owned&&project_s_ready;
    assign project_m_ready=state==RUN&&fragment_owned&&
        (project_covered?sample_s_ready:!error_valid);
    assign raster_d_ready=state==RUN&&!fragment_owned&&!project_busy&&!sample_busy&&!error_valid;
    assign m_valid=!rst&&(error_valid||sample_m_valid);
    assign m_x=error_valid?fragment_x:sample_x[7:0];
    assign m_y=error_valid?fragment_y:sample_y[7:0];
    assign m_rgb=error_valid?24'd0:sample_rgb;
    assign m_alpha=error_valid?8'd0:sample_alpha;
    assign m_visible=!error_valid&&sample_visible;
    assign m_reason=error_valid?3'b100:{1'b0,sample_reason};
    assign m_first=fragment_first;
    assign m_tag=error_valid?fragment_tag:sample_tag;
    assign d_valid=!rst&&state==DONE;
    perspective_uv_projector #(.Q_W(Q_W),.TAG_W(TAG_W)) projector(
        .clk(clk),.rst(rst),.c_valid(state==CONFIG_SEND),.c_ready(project_c_ready),
        .c_x0(x0),.c_y0(y0),.c_x1(x1),.c_y1(y1),.c_x2(x2),.c_y2(y2),
        .c_u0(u0),.c_v0(v0),.c_u1(u1),.c_v1(v1),.c_u2(u2),.c_v2(v2),
        .c_q0(q0),.c_q1(q1),.c_q2(q2),.c_tag(primitive_tag),
        .r_valid(project_r_valid),.r_ready(state==CONFIG_WAIT),.r_status(project_status),.r_tag(),
        .s_valid(state==RUN&&raster_m_valid&&!fragment_owned),.s_ready(project_s_ready),
        .s_x(raster_x),.s_y(raster_y),.s_first(raster_first),.s_tag(raster_tag),
        .m_valid(project_m_valid),.m_ready(project_m_ready),.m_u(project_u),.m_v(project_v),
        .m_x(project_x),.m_y(project_y),.m_first(project_first),.m_tag(project_tag),
        .m_covered(project_covered),.configured(project_configured),.busy(project_busy));
    triangle_rgb_raster #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) coverage(
        .clk(clk),.rst(rst),.c_valid(state==RASTER_SEND),.c_ready(raster_c_ready),
        .c_x0(x0),.c_y0(y0),.c_x1(x1),.c_y1(y1),.c_x2(x2),.c_y2(y2),
        .c_rgb0(24'd0),.c_rgb1(24'd0),.c_rgb2(24'd0),.c_tag(primitive_tag),
        .m_valid(raster_m_valid),.m_ready(raster_m_ready),.m_x(raster_x),.m_y(raster_y),
        .m_rgb(unused_rgb),.m_first(raster_first),.m_tag(raster_tag),
        .d_valid(raster_d_valid),.d_ready(raster_d_ready),.d_status(raster_status),
        .d_count(raster_count),.d_tag(raster_d_tag));
    indexed_texture_sampler #(.TEX_WIDTH(TEX_WIDTH),.TEX_HEIGHT(TEX_HEIGHT),.TAG_W(TAG_W)) sampler(
        .clk(clk),.rst(rst),.c_valid(tex_c_valid&&state==IDLE),.c_ready(sample_c_ready),
        .c_op(tex_c_op),.c_tag(tex_c_tag),.r_valid(tex_r_valid),.r_ready(tex_r_ready),
        .r_status(tex_r_status),.r_tag(tex_r_tag),.r_tex_count(tex_r_tex_count),.r_pal_count(tex_r_pal_count),
        .t_valid(i_valid&&state==IDLE),.t_ready(sample_t_ready),.t_index(i_index),
        .p_valid(p_valid&&state==IDLE),.p_ready(sample_p_ready),.p_rgba(p_rgba),
        .s_valid(state==RUN&&fragment_owned&&project_m_valid&&project_covered),.s_ready(sample_s_ready),
        .s_u(project_u),.s_v(project_v),.s_x({8'b0,project_x}),.s_y({8'b0,project_y}),.s_tag(project_tag),
        .m_valid(sample_m_valid),.m_ready(m_ready&&!error_valid),.m_rgb(sample_rgb),
        .m_alpha(sample_alpha),.m_visible(sample_visible),.m_reason(sample_reason),
        .m_x(sample_x),.m_y(sample_y),.m_tag(sample_tag),.resident(texture_resident),.pipeline_busy(sample_busy));
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;fragment_owned<=0;error_valid<=0;fragment_first<=0;
            fragment_x<=0;fragment_y<=0;fragment_tag<=0;primitive_tag<=0;
            d_status<=0;d_count<=0;d_tag<=0;
            x0<=0;y0<=0;x1<=0;y1<=0;x2<=0;y2<=0;
            u0<=0;v0<=0;u1<=0;v1<=0;u2<=0;v2<=0;q0<=0;q1<=0;q2<=0;
        end else begin
            if(raster_m_valid&&raster_m_ready)begin
                fragment_owned<=1;fragment_x<=raster_x;fragment_y<=raster_y;
                fragment_tag<=raster_tag;fragment_first<=raster_first;
            end
            if(project_m_valid&&project_m_ready&&!project_covered)error_valid<=1;
            if(m_valid&&m_ready)begin fragment_owned<=0;if(error_valid)error_valid<=0;end
            case(state)
                IDLE:if(c_valid&&c_ready)begin
                    x0<=c_x0;y0<=c_y0;x1<=c_x1;y1<=c_y1;x2<=c_x2;y2<=c_y2;
                    u0<=c_u0;v0<=c_v0;u1<=c_u1;v1<=c_v1;u2<=c_u2;v2<=c_v2;
                    q0<=c_q0;q1<=c_q1;q2<=c_q2;primitive_tag<=c_tag;
                    state<=CONFIG_SEND;
                end
                CONFIG_SEND:if(project_c_ready)state<=CONFIG_WAIT;
                CONFIG_WAIT:if(project_r_valid)begin
                    if(project_status==0)state<=RASTER_SEND;
                    else begin d_status<=project_status==1?2'd1:2'd3;
                        d_count<=0;d_tag<=primitive_tag;state<=DONE;end
                end
                RASTER_SEND:if(raster_c_ready)state<=RUN;
                RUN:if(raster_d_valid&&raster_d_ready)begin
                    d_status<=raster_status;d_count<=raster_count;d_tag<=raster_d_tag;state<=DONE;
                end
                DONE:if(d_ready)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
