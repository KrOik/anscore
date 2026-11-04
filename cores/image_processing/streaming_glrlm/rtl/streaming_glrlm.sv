// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module streaming_glrlm #(
    parameter integer WIDTH=64,HEIGHT=64,PIXEL_W=8,GRAY_W=3,TAG_W=8,
    localparam integer N=WIDTH*HEIGHT,
    localparam integer MAX_RUN=(WIDTH>HEIGHT)?WIDTH:HEIGHT,
    localparam integer COUNT_W=(N<2)?1:$clog2(N+1),
    localparam integer LENGTH_W=(MAX_RUN<2)?1:$clog2(MAX_RUN+1)
)(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire [PIXEL_W-1:0] s_pixel,
    input wire s_sof,s_eol,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [1:0] m_direction,
    output wire [GRAY_W-1:0] m_gray,
    output wire [LENGTH_W-1:0] m_length,
    output wire [COUNT_W-1:0] m_count,m_runs,
    output wire m_direction_last,m_last,
    output wire [TAG_W-1:0] m_tag,
    output wire [1:0] m_errors
);
    localparam integer XW=(WIDTH<2)?1:$clog2(WIDTH);
    localparam integer YW=(HEIGHT<2)?1:$clog2(HEIGHT);
    localparam integer OW=(MAX_RUN<2)?1:$clog2(MAX_RUN);
    localparam integer HW=GRAY_W+OW,HDEPTH=1<<HW;
    localparam integer LW=LENGTH_W,SW=GRAY_W+LW;
    localparam [2:0] CLEAR=0,COLLECT=1,CALCULATE=2,INCREMENT=3,
        DEC_READ=4,DECREMENT=5,OUT_READ=6,OUT_HOLD=7;
    reg [2:0] state;
    reg [HW-1:0] clear_index;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg [GRAY_W-1:0] gray_q,horizontal_gray;
    reg [LW-1:0] horizontal_length;
    reg [SW-1:0] vertical_mem[0:WIDTH-1],diagonal_mem[0:WIDTH-1],antidiagonal_mem[0:WIDTH-1];
    reg [SW-1:0] vertical_q,diagonal_q,antidiagonal_q,left_old_diagonal;
    wire [3:0] extension_now;
    wire [LW-1:0] new_length[0:3];
    reg [LW-1:0] length_q[0:3];
    reg [3:0] extends_q;
    reg [COUNT_W-1:0] runs[0:3];
    reg [TAG_W-1:0] tag_q;
    reg [1:0] errors,out_direction;
    reg [GRAY_W-1:0] out_gray;
    reg [LW-1:0] out_length;
    wire [COUNT_W-1:0] output_count[0:3];
    wire [HW-1:0] output_address={out_gray,OW'(out_length-1'b1)};
    wire first_pixel=(x==0 && y==0);
    wire final_pixel=(x==WIDTH-1 && y==HEIGHT-1);
    wire [1:0] current_marker_errors={s_eol!=(x==WIDTH-1),s_sof!=first_pixel};
    assign extension_now[0]=(x!=0 && horizontal_gray==gray_q);
    assign extension_now[1]=(y!=0 && vertical_q[SW-1:LW]==gray_q);
    assign extension_now[2]=(y!=0 && x!=0 && left_old_diagonal[SW-1:LW]==gray_q);
    assign extension_now[3]=(y!=0 && x!=WIDTH-1 && antidiagonal_q[SW-1:LW]==gray_q);
    assign new_length[0]=extension_now[0]?horizontal_length+1'b1:LW'(1);
    assign new_length[1]=extension_now[1]?vertical_q[LW-1:0]+1'b1:LW'(1);
    assign new_length[2]=extension_now[2]?left_old_diagonal[LW-1:0]+1'b1:LW'(1);
    assign new_length[3]=extension_now[3]?antidiagonal_q[LW-1:0]+1'b1:LW'(1);
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_direction=out_direction;
    assign m_gray=out_gray;
    assign m_length=out_length;
    assign m_count=(errors==0)?output_count[out_direction]:{COUNT_W{1'b0}};
    assign m_runs=(errors==0)?runs[out_direction]:{COUNT_W{1'b0}};
    assign m_direction_last=(&out_gray) && out_length==MAX_RUN;
    assign m_last=(&out_direction) && m_direction_last;
    assign m_tag=tag_q;
    assign m_errors=errors;

    // Synchronous histories: D[x] is read before overwriting it, then its OLD
    // word is cached for the next column. A[x+1] is ahead of the write frontier.
    always @(posedge clk)if(!rst)begin
        if(state==COLLECT && s_valid)begin
            vertical_q<=vertical_mem[x];diagonal_q<=diagonal_mem[x];
            if(x!=WIDTH-1)antidiagonal_q<=antidiagonal_mem[x+1'b1];
        end
        if(state==CALCULATE)begin
            vertical_mem[x]<={gray_q,new_length[1]};
            diagonal_mem[x]<={gray_q,new_length[2]};
            antidiagonal_mem[x]<={gray_q,new_length[3]};
        end
    end
    genvar bank;
    generate for(bank=0;bank<4;bank=bank+1)begin:histogram
        reg [COUNT_W-1:0] hist_mem[0:HDEPTH-1];
        reg [COUNT_W-1:0] read_q,result_q;
        wire [HW-1:0] new_address={gray_q,OW'(new_length[bank]-1'b1)};
        wire [HW-1:0] increment_address={gray_q,OW'(length_q[bank]-1'b1)};
        wire [HW-1:0] decrement_address={gray_q,OW'(length_q[bank]-2)};
        assign output_count[bank]=result_q;
        // New and old prefix lengths differ by one. All reads and writes are
        // separate phases; no read-during-write RAM mode or forwarding needed.
        always @(posedge clk)if(!rst)begin
            if(state==CLEAR)hist_mem[clear_index]<=0;
            if(state==CALCULATE)read_q<=hist_mem[new_address];
            if(state==INCREMENT)hist_mem[increment_address]<=read_q+1'b1;
            if(state==DEC_READ && extends_q[bank])read_q<=hist_mem[decrement_address];
            if(state==DECREMENT && extends_q[bank])hist_mem[decrement_address]<=read_q-1'b1;
            if(state==OUT_READ && out_direction==bank)result_q<=hist_mem[output_address];
        end
    end endgenerate
    integer k;
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;clear_index<=0;x<=0;y<=0;gray_q<=0;
            horizontal_gray<=0;horizontal_length<=0;left_old_diagonal<=0;
            extends_q<=0;tag_q<=0;errors<=0;out_direction<=0;out_gray<=0;out_length<=1;
            for(k=0;k<4;k=k+1)begin runs[k]<=0;length_q[k]<=0;end
        end else case(state)
            CLEAR:if(clear_index==HDEPTH-1)state<=COLLECT;
                else clear_index<=clear_index+1'b1;
            COLLECT:if(s_valid && s_ready)begin
                gray_q<=s_pixel[PIXEL_W-1 -:GRAY_W];
                if(first_pixel)begin tag_q<=s_tag;errors<=current_marker_errors;end
                else errors<=errors|current_marker_errors;
                state<=CALCULATE;
            end
            CALCULATE:begin
                horizontal_gray<=gray_q;horizontal_length<=new_length[0];
                left_old_diagonal<=diagonal_q;extends_q<=extension_now;
                for(k=0;k<4;k=k+1)begin
                    length_q[k]<=new_length[k];
                    if(!extension_now[k])runs[k]<=runs[k]+1'b1;
                end
                state<=INCREMENT;
            end
            INCREMENT:state<=DEC_READ;
            DEC_READ:state<=DECREMENT;
            DECREMENT:if(final_pixel)begin out_direction<=0;out_gray<=0;out_length<=1;state<=OUT_READ;end
                else begin
                    if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
                    state<=COLLECT;
                end
            OUT_READ:state<=OUT_HOLD;
            OUT_HOLD:if(m_ready)begin
                if(m_last)begin
                    state<=CLEAR;clear_index<=0;x<=0;y<=0;
                    for(k=0;k<4;k=k+1)runs[k]<=0;
                end else begin
                    if(out_length==MAX_RUN)begin
                        out_length<=1;
                        if(&out_gray)begin out_gray<=0;out_direction<=out_direction+1'b1;end
                        else out_gray<=out_gray+1'b1;
                    end else out_length<=out_length+1'b1;
                    state<=OUT_READ;
                end
            end
            default:state<=CLEAR;
        endcase
    end
    generate if(WIDTH<1 || WIDTH>128 || HEIGHT<1 || HEIGHT>128 || PIXEL_W<1 || PIXEL_W>16 ||
                GRAY_W<1 || GRAY_W>4 || GRAY_W>PIXEL_W || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        streaming_glrlm_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
`default_nettype wire
