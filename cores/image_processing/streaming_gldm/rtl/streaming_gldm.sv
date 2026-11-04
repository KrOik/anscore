// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module streaming_gldm #(
    parameter integer WIDTH=32,HEIGHT=24,PIXEL_W=8,GRAY_W=3,TAG_W=8,
    localparam integer COUNT_W=($clog2(WIDTH*HEIGHT+1)<1)?1:$clog2(WIDTH*HEIGHT+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [PIXEL_W-1:0] s_pixel,
    input wire [GRAY_W-1:0] s_alpha,
    input wire s_sof,s_eol,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [GRAY_W-1:0] m_gray,m_alpha,
    output wire [3:0] m_dependence,
    output wire [COUNT_W-1:0] m_count,
    output wire m_first,m_last,
    output wire [TAG_W-1:0] m_tag,output wire [1:0] m_errors
);
    localparam integer XW=($clog2(WIDTH+2)<1)?1:$clog2(WIDTH+2),
        YW=($clog2(HEIGHT+2)<1)?1:$clog2(HEIGHT+2),SW=GRAY_W+1,
        HW=GRAY_W+4,HDEPTH=1<<HW,CW=COUNT_W;
    localparam [2:0] CLEAR=0,STEP=1,LINE_READ=2,WINDOW=3,H_READ=4,H_WRITE=5,OUT_READ=6,OUT_HOLD=7;
    reg [2:0] state;
    reg [XW-1:0] pad_x;
    reg [YW-1:0] pad_y;
    reg [HW-1:0] clear_index;
    reg [SW-1:0] line1[0:WIDTH+1],line2[0:WIDTH+1],line1_q,line2_q,token;
    reg [SW-1:0] top2,top1,middle2,middle1,bottom2,bottom1;
    reg [GRAY_W-1:0] alpha_q,center_gray,out_gray;
    reg [3:0] dependence_q,out_dependence;
    reg [TAG_W-1:0] tag_q;
    reg [1:0] errors;
    reg [CW-1:0] hist_mem[0:HDEPTH-1],hist_q;
    wire real_pixel=pad_x>=1 && pad_x<=WIDTH && pad_y>=1 && pad_y<=HEIGHT;
    wire center_now=pad_x>=2 && pad_y>=2;
    // First two internal rows never consume stale line RAM after reset/frame.
    wire [SW-1:0] top_new=(pad_y>=2)?line2_q:{SW{1'b0}};
    wire [SW-1:0] middle_new=(pad_y>=1)?line1_q:{SW{1'b0}};
    wire [SW-1:0] neighbor_word[0:7];
    assign neighbor_word[0]=top2;assign neighbor_word[1]=top1;assign neighbor_word[2]=top_new;
    assign neighbor_word[3]=middle2;assign neighbor_word[4]=middle_new;
    assign neighbor_word[5]=bottom2;assign neighbor_word[6]=bottom1;assign neighbor_word[7]=token;
    wire [7:0] match_bits,neighbor_valid;
    genvar k;
    generate for(k=0;k<8;k=k+1)begin:compare_neighbor
        wire [GRAY_W-1:0] a=neighbor_word[k][GRAY_W-1:0],b=middle1[GRAY_W-1:0];
        wire [GRAY_W-1:0] delta=(a>=b)?a-b:b-a;
        assign neighbor_valid[k]=neighbor_word[k][GRAY_W];
        assign match_bits[k]=neighbor_word[k][GRAY_W] && delta<=alpha_q;
    end endgenerate
    wire [1:0] pair0={1'b0,match_bits[0]}+{1'b0,match_bits[1]},
        pair1={1'b0,match_bits[2]}+{1'b0,match_bits[3]},
        pair2={1'b0,match_bits[4]}+{1'b0,match_bits[5]},
        pair3={1'b0,match_bits[6]}+{1'b0,match_bits[7]};
    wire [2:0] half0={1'b0,pair0}+{1'b0,pair1},half1={1'b0,pair2}+{1'b0,pair3};
    wire [3:0] dependence_now=4'd1+{1'b0,half0}+{1'b0,half1};
    wire [3:0] hist_offset=dependence_q-1'b1,out_offset=out_dependence-1'b1;
    wire [HW-1:0] hist_address={center_gray,hist_offset},output_address={out_gray,out_offset};
    assign s_ready=!rst && state==STEP && real_pixel;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_gray=out_gray;assign m_alpha=alpha_q;assign m_dependence=out_dependence;
    assign m_count=(errors!=0)?{CW{1'b0}}:hist_q;
    assign m_first=out_gray==0 && out_dependence==1;
    assign m_last=(&out_gray) && out_dependence==9;
    assign m_tag=tag_q;assign m_errors=errors;

    // Synchronous reads are consumed one edge later. Every bank's read and
    // write phases are disjoint; no read-during-write mode is assumed.
    always @(posedge clk)if(!rst)begin
        if(state==LINE_READ)begin line1_q<=line1[pad_x];line2_q<=line2[pad_x];end
        if(state==WINDOW)begin line1[pad_x]<=token;line2[pad_x]<=middle_new;end
        if(state==CLEAR)hist_mem[clear_index]<=0;
        if(state==H_READ)hist_q<=hist_mem[hist_address];
        if(state==H_WRITE)hist_mem[hist_address]<=hist_q+1'b1;
        if(state==OUT_READ)hist_q<=hist_mem[output_address];
    end
    task automatic advance_grid;
        begin
            if(pad_x==WIDTH+1 && pad_y==HEIGHT+1)begin out_gray<=0;out_dependence<=1;state<=OUT_READ;end
            else begin
                if(pad_x==WIDTH+1)begin pad_x<=0;pad_y<=pad_y+1'b1;end
                else pad_x<=pad_x+1'b1;
                state<=STEP;
            end
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;clear_index<=0;pad_x<=0;pad_y<=0;token<=0;
            top2<=0;top1<=0;middle2<=0;middle1<=0;bottom2<=0;bottom1<=0;
            alpha_q<=0;center_gray<=0;dependence_q<=1;out_gray<=0;out_dependence<=1;tag_q<=0;errors<=0;
        end else case(state)
            CLEAR:if(clear_index==HDEPTH-1)begin
                state<=STEP;pad_x<=0;pad_y<=0;errors<=0;
            end else clear_index<=clear_index+1'b1;
            STEP:if(!real_pixel)begin token<=0;state<=LINE_READ;end
                else if(s_valid && s_ready)begin
                    token<={1'b1,s_pixel[PIXEL_W-1 -:GRAY_W]};
                    if(pad_x==1 && pad_y==1)begin alpha_q<=s_alpha;tag_q<=s_tag;end
                    if(s_sof!=(pad_x==1 && pad_y==1))errors[0]<=1;
                    if(s_eol!=(pad_x==WIDTH))errors[1]<=1;
                    state<=LINE_READ;
                end
            LINE_READ:state<=WINDOW;
            WINDOW:begin
                top2<=top1;top1<=top_new;middle2<=middle1;middle1<=middle_new;bottom2<=bottom1;bottom1<=token;
                if(center_now)begin center_gray<=middle1[GRAY_W-1:0];dependence_q<=dependence_now;state<=H_READ;end
                else advance_grid();
            end
            H_READ:state<=H_WRITE;
            H_WRITE:advance_grid();
            OUT_READ:state<=OUT_HOLD;
            OUT_HOLD:if(m_ready)begin
                if(m_last)begin clear_index<=0;state<=CLEAR;end
                else begin
                    if(out_dependence==9)begin out_dependence<=1;out_gray<=out_gray+1'b1;end
                    else out_dependence<=out_dependence+1'b1;
                    state<=OUT_READ;
                end
            end
            default:state<=CLEAR;
        endcase
    end
    generate if(WIDTH<1 || WIDTH>128 || HEIGHT<1 || HEIGHT>128 || PIXEL_W<1 || PIXEL_W>16 ||
        GRAY_W<1 || GRAY_W>4 || GRAY_W>PIXEL_W || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        streaming_gldm_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
`default_nettype wire
