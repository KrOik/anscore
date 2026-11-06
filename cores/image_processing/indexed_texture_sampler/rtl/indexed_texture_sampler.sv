// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module indexed_texture_sampler #(
    parameter integer TEX_WIDTH=64,TEX_HEIGHT=64,TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [1:0] c_op,input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output reg [1:0] r_status,
    output reg [TAG_W-1:0] r_tag,output reg [16:0] r_tex_count,output reg [8:0] r_pal_count,
    input wire t_valid,output wire t_ready,input wire [7:0] t_index,
    input wire p_valid,output wire p_ready,input wire [31:0] p_rgba,
    input wire s_valid,output wire s_ready,input wire [7:0] s_u,s_v,
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output reg [23:0] m_rgb,
    output reg [7:0] m_alpha,output reg m_visible,output reg [1:0] m_reason,
    output reg [15:0] m_x,m_y,output reg [TAG_W-1:0] m_tag,
    output wire resident,pipeline_busy
);
    localparam integer N=TEX_WIDTH*TEX_HEIGHT;
    localparam integer AW=N>1?$clog2(N):1;
    localparam [1:0] EMPTY=0,LOADING=1,RESIDENT=2;
    reg [1:0] mode;
    reg [16:0] tex_count;
    reg [8:0] pal_count;
    reg v1,v2,v3,oob1,oob2,response_valid;
    reg [15:0] x1,y1,x2,y2;
    reg [TAG_W-1:0] tag1,tag2;
    reg [7:0] indices[0:N-1],index_q;
    reg [31:0] palette[0:255],rgba_q;
    wire step=!v3 || m_ready;
    wire in_range=(s_u<TEX_WIDTH && s_v<TEX_HEIGHT);
    wire [AW-1:0] address=AW'(s_v*TEX_WIDTH+s_u);
    assign resident=!rst && mode==RESIDENT;
    assign pipeline_busy=!rst && (v1 || v2 || v3);
    assign c_ready=!rst && !r_valid && !v1 && !v2 && !v3;
    assign t_ready=!rst && !r_valid && !c_valid && mode==LOADING && tex_count<N;
    assign p_ready=!rst && !r_valid && !c_valid && mode==LOADING && pal_count<256;
    assign s_ready=!rst && !r_valid && !c_valid && mode==RESIDENT && step;
    assign m_valid=!rst && v3;
    assign r_valid=!rst && response_valid;
    wire lookup_fire=s_valid && s_ready;
    wire texture_fire=t_valid && t_ready;
    wire palette_fire=p_valid && p_ready;
    // Each bank's write/read modes are mutually exclusive. Payload RAM is not reset.
    always @(posedge clk) if(!rst) begin
        if(texture_fire) indices[AW'(tex_count)]<=t_index;
        else if(lookup_fire && in_range) index_q<=indices[address];
        if(palette_fire) palette[pal_count[7:0]]<=p_rgba;
        else if(step && v1 && !oob1) rgba_q<=palette[index_q];
    end
    initial begin
        if(TEX_WIDTH<1 || TEX_WIDTH>256 || TEX_HEIGHT<1 || TEX_HEIGHT>256 || TAG_W<1 || TAG_W>32)
            $fatal(1,"indexed_texture_sampler invalid parameters");
    end
    always @(posedge clk) begin
        if(rst) begin
            mode<=EMPTY;tex_count<=0;pal_count<=0;
            response_valid<=0;r_status<=0;r_tag<=0;r_tex_count<=0;r_pal_count<=0;
            v1<=0;v2<=0;v3<=0;oob1<=0;oob2<=0;
            x1<=0;y1<=0;x2<=0;y2<=0;tag1<=0;tag2<=0;
            m_rgb<=0;m_alpha<=0;m_visible<=0;m_reason<=0;m_x<=0;m_y<=0;m_tag<=0;
        end else begin
            if(r_valid && r_ready) response_valid<=0;
            if(texture_fire)tex_count<=tex_count+1'b1;
            if(palette_fire)pal_count<=pal_count+1'b1;
            if(step) begin
                v1<=lookup_fire;v2<=v1;v3<=v2;
                if(lookup_fire)begin x1<=s_x;y1<=s_y;tag1<=s_tag;oob1<=!in_range;end
                if(v1)begin x2<=x1;y2<=y1;tag2<=tag1;oob2<=oob1;end
                if(v2)begin
                    m_x<=x2;m_y<=y2;m_tag<=tag2;
                    if(oob2)begin m_rgb<=0;m_alpha<=0;m_visible<=0;m_reason<=1;end
                    else begin
                        m_rgb<=rgba_q[23:0];m_alpha<=rgba_q[31:24];
                        m_visible<=rgba_q[31:24]!=0;m_reason<=rgba_q[31:24]==0?2'd2:2'd0;
                    end
                end
            end
            if(c_valid && c_ready)begin
                response_valid<=1;r_tag<=c_tag;r_tex_count<=tex_count;r_pal_count<=pal_count;
                case(c_op)
                    0:begin mode<=LOADING;tex_count<=0;pal_count<=0;r_status<=0;r_tex_count<=0;r_pal_count<=0;end
                    1:begin
                        if(mode!=LOADING)r_status<=2;
                        else if(tex_count!=N || pal_count!=256)r_status<=1;
                        else begin mode<=RESIDENT;r_status<=0;end
                    end
                    default:r_status<=3;
                endcase
            end
        end
    end
endmodule
