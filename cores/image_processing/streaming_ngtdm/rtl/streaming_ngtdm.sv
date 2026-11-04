// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module streaming_ngtdm #(
    parameter integer WIDTH=32,HEIGHT=24,PIXEL_W=8,GRAY_W=3,TAG_W=8,
    localparam integer COUNT_W=($clog2(WIDTH*HEIGHT+1)<1)?1:$clog2(WIDTH*HEIGHT+1),
    localparam integer SUM_W=($clog2(WIDTH*HEIGHT*120*((1<<GRAY_W)-1)+1)<1)?1:
        $clog2(WIDTH*HEIGHT*120*((1<<GRAY_W)-1)+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [PIXEL_W-1:0] s_pixel,input wire s_sof,s_eol,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [GRAY_W-1:0] m_gray,
    output wire [COUNT_W-1:0] m_count,
    output wire [SUM_W-1:0] m_difference_120,
    output wire m_first,m_last,output wire [TAG_W-1:0] m_tag,
    output wire [1:0] m_errors
);
    localparam integer XW=($clog2(WIDTH+2)<1)?1:$clog2(WIDTH+2),
        YW=($clog2(HEIGHT+2)<1)?1:$clog2(HEIGHT+2),SW=GRAY_W+1,
        NW=GRAY_W+3,DW=($clog2(120*((1<<GRAY_W)-1)+1)<1)?1:
        $clog2(120*((1<<GRAY_W)-1)+1),HW=COUNT_W+SUM_W,LEVELS=1<<GRAY_W;
    localparam [3:0] CLEAR=0,STEP=1,LINE_READ=2,WINDOW=3,ABS_DIFF=4,
        SCALE=5,H_READ=6,H_WRITE=7,OUT_READ=8,OUT_HOLD=9;
    reg [3:0] state;
    reg [XW-1:0] pad_x;
    reg [YW-1:0] pad_y;
    reg [GRAY_W-1:0] clear_index,out_gray,center_gray;
    reg [SW-1:0] line1[0:WIDTH+1],line2[0:WIDTH+1],line1_q,line2_q,token;
    reg [SW-1:0] top2,top1,middle2,middle1,bottom2,bottom1;
    reg [3:0] neighbor_count_q;
    reg [NW-1:0] neighbor_sum_q,center_product_q,delta_q;
    reg [DW-1:0] scaled_q;
    reg [HW-1:0] hist_mem[0:LEVELS-1],hist_q;
    reg [TAG_W-1:0] tag_q;
    reg [1:0] errors;
    wire real_pixel=pad_x>=1 && pad_x<=WIDTH && pad_y>=1 && pad_y<=HEIGHT;
    wire center_now=pad_x>=2 && pad_y>=2;
    // Initial rows mask stale RAM; two left padding columns flush row windows.
    wire [SW-1:0] top_new=(pad_y>=2)?line2_q:{SW{1'b0}};
    wire [SW-1:0] middle_new=(pad_y>=1)?line1_q:{SW{1'b0}};
    wire [SW-1:0] neighbors[0:7];
    assign neighbors[0]=top2;assign neighbors[1]=top1;assign neighbors[2]=top_new;
    assign neighbors[3]=middle2;assign neighbors[4]=middle_new;
    assign neighbors[5]=bottom2;assign neighbors[6]=bottom1;assign neighbors[7]=token;
    wire [GRAY_W-1:0] gray[0:7];
    wire [7:0] neighbor_valid;
    genvar k;
    generate for(k=0;k<8;k=k+1)begin:valid_gray
        assign neighbor_valid[k]=neighbors[k][GRAY_W];
        assign gray[k]=neighbors[k][GRAY_W]?neighbors[k][GRAY_W-1:0]:{GRAY_W{1'b0}};
    end endgenerate
    wire [GRAY_W:0] gs0={1'b0,gray[0]}+{1'b0,gray[1]},
        gs1={1'b0,gray[2]}+{1'b0,gray[3]},gs2={1'b0,gray[4]}+{1'b0,gray[5]},
        gs3={1'b0,gray[6]}+{1'b0,gray[7]};
    wire [GRAY_W+1:0] gh0={1'b0,gs0}+{1'b0,gs1},gh1={1'b0,gs2}+{1'b0,gs3};
    wire [NW-1:0] neighbor_sum_now={1'b0,gh0}+{1'b0,gh1};
    wire [1:0] kc0={1'b0,neighbor_valid[0]}+{1'b0,neighbor_valid[1]},
        kc1={1'b0,neighbor_valid[2]}+{1'b0,neighbor_valid[3]},
        kc2={1'b0,neighbor_valid[4]}+{1'b0,neighbor_valid[5]},
        kc3={1'b0,neighbor_valid[6]}+{1'b0,neighbor_valid[7]};
    wire [2:0] kh0={1'b0,kc0}+{1'b0,kc1},kh1={1'b0,kc2}+{1'b0,kc3};
    wire [3:0] neighbor_count_now={1'b0,kh0}+{1'b0,kh1};
    wire [NW-1:0] center_extended={{3{1'b0}},middle1[GRAY_W-1:0]};
    reg [NW-1:0] center_product_now;
    always @* begin
        case(neighbor_count_now)
            1:center_product_now=center_extended;
            2:center_product_now=center_extended<<1;
            3:center_product_now=(center_extended<<1)+center_extended;
            5:center_product_now=(center_extended<<2)+center_extended;
            8:center_product_now=center_extended<<3;
            default:center_product_now=0;
        endcase
    end
    wire [DW-1:0] delta_extended={{(DW-NW){1'b0}},delta_q};
    reg [DW-1:0] scaled_now;
    //120 is the LCM of all nonzero rectangular radius-one neighbor counts.
    always @* begin
        case(neighbor_count_q)
            1:scaled_now=(delta_extended<<6)+(delta_extended<<5)+(delta_extended<<4)+(delta_extended<<3);
            2:scaled_now=(delta_extended<<5)+(delta_extended<<4)+(delta_extended<<3)+(delta_extended<<2);
            3:scaled_now=(delta_extended<<5)+(delta_extended<<3);
            5:scaled_now=(delta_extended<<4)+(delta_extended<<3);
            8:scaled_now=(delta_extended<<3)+(delta_extended<<2)+(delta_extended<<1)+delta_extended;
            default:scaled_now=0;
        endcase
    end
    wire [COUNT_W-1:0] next_count=hist_q[COUNT_W-1:0]+1'b1;
    wire [SUM_W-1:0] next_sum=hist_q[HW-1:COUNT_W]+{{(SUM_W-DW){1'b0}},scaled_q};
    assign s_ready=!rst && state==STEP && real_pixel;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_gray=out_gray;assign m_count=(errors!=0)?{COUNT_W{1'b0}}:hist_q[COUNT_W-1:0];
    assign m_difference_120=(errors!=0)?{SUM_W{1'b0}}:hist_q[HW-1:COUNT_W];
    assign m_first=out_gray==0;assign m_last=&out_gray;
    assign m_tag=tag_q;assign m_errors=errors;

    // Each bank has one synchronous read and a separate write phase.
    always @(posedge clk)if(!rst)begin
        if(state==LINE_READ)begin line1_q<=line1[pad_x];line2_q<=line2[pad_x];end
        if(state==WINDOW)begin line1[pad_x]<=token;line2[pad_x]<=middle_new;end
        if(state==CLEAR)hist_mem[clear_index]<=0;
        if(state==H_READ)hist_q<=hist_mem[center_gray];
        if(state==H_WRITE)hist_mem[center_gray]<={next_sum,next_count};
        if(state==OUT_READ)hist_q<=hist_mem[out_gray];
    end
    task automatic advance_grid;
        begin
            if(pad_x==WIDTH+1 && pad_y==HEIGHT+1)begin out_gray<=0;state<=OUT_READ;end
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
            center_gray<=0;neighbor_count_q<=0;neighbor_sum_q<=0;center_product_q<=0;
            delta_q<=0;scaled_q<=0;out_gray<=0;tag_q<=0;errors<=0;
        end else case(state)
            CLEAR:if(clear_index==LEVELS-1)begin
                state<=STEP;pad_x<=0;pad_y<=0;errors<=0;
            end else clear_index<=clear_index+1'b1;
            STEP:if(!real_pixel)begin token<=0;state<=LINE_READ;end
                else if(s_valid && s_ready)begin
                    token<={1'b1,s_pixel[PIXEL_W-1 -:GRAY_W]};
                    if(pad_x==1 && pad_y==1)tag_q<=s_tag;
                    if(s_sof!=(pad_x==1 && pad_y==1))errors[0]<=1;
                    if(s_eol!=(pad_x==WIDTH))errors[1]<=1;
                    state<=LINE_READ;
                end
            LINE_READ:state<=WINDOW;
            WINDOW:begin
                top2<=top1;top1<=top_new;middle2<=middle1;middle1<=middle_new;
                bottom2<=bottom1;bottom1<=token;
                if(center_now)begin
                    center_gray<=middle1[GRAY_W-1:0];neighbor_count_q<=neighbor_count_now;
                    neighbor_sum_q<=neighbor_sum_now;center_product_q<=center_product_now;state<=ABS_DIFF;
                end else advance_grid();
            end
            ABS_DIFF:begin
                delta_q<=(center_product_q>=neighbor_sum_q)?center_product_q-neighbor_sum_q:
                    neighbor_sum_q-center_product_q;
                state<=SCALE;
            end
            SCALE:begin scaled_q<=scaled_now;if(neighbor_count_q==0)advance_grid();else state<=H_READ;end
            H_READ:state<=H_WRITE;
            H_WRITE:advance_grid();
            OUT_READ:state<=OUT_HOLD;
            OUT_HOLD:if(m_ready)begin
                if(&out_gray)begin clear_index<=0;state<=CLEAR;end
                else begin out_gray<=out_gray+1'b1;state<=OUT_READ;end
            end
            default:begin state<=CLEAR;clear_index<=0;end
        endcase
    end
    generate if(WIDTH<1 || WIDTH>128 || HEIGHT<1 || HEIGHT>128 || PIXEL_W<1 || PIXEL_W>16 ||
        GRAY_W<1 || GRAY_W>4 || GRAY_W>PIXEL_W || TAG_W<1 || TAG_W>32)begin:bad_parameters
        streaming_ngtdm_invalid_parameters invalid();
    end endgenerate
endmodule
`default_nettype wire
