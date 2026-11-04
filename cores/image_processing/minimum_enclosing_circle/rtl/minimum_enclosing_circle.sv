// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module minimum_enclosing_circle #(
    parameter integer COORD_W=8,MAX_POINTS=8,TAG_W=8,
    localparam integer IW=($clog2(MAX_POINTS)<1)?1:$clog2(MAX_POINTS),
    localparam integer CW=($clog2(MAX_POINTS+1)<1)?1:$clog2(MAX_POINTS+1),
    localparam integer MW=3*COORD_W+5,RW=2*MW
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [MW-1:0] m_center_x_num,m_center_y_num,
    output reg [MW-1:0] m_den,output reg [RW-1:0] m_radius_sq_num,
    output reg [1:0] m_support,m_status,
    output reg [IW-1:0] m_i,m_j,m_k,
    output reg [CW-1:0] m_count,output reg [TAG_W-1:0] m_tag
);
    localparam integer GOOD=COORD_W>=2 && COORD_W<=12 && MAX_POINTS>=1 && MAX_POINTS<=8,
        N=GOOD?MAX_POINTS:1,BW=($clog2(MW)<1)?1:$clog2(MW);
    localparam [4:0] CAPTURE=0,CHECK=1,CAND_START=2,READ_A=3,READ_B=4,READ_C=5,
        LOAD_GEOM=6,OP_SETUP=7,MUL_RUN=8,OP_STORE=9,CAND_CHECK=10,
        POINT_READ=11,POINT_SETUP=12,POINT_CHECK=13,NEXT_CAND=14,EMIT=15;
    reg [4:0] state;
    reg started,overflow,checking,mul_negative;
    reg [1:0] kind;
    reg [IW-1:0] ia,ib,ic,scan;
    reg [3:0] op;
    reg [BW-1:0] bit_index;
    reg [2*COORD_W-1:0] points[0:N-1],point_q;
    reg signed [COORD_W-1:0] ax,ay,bx,by;
    reg signed [MW-1:0] ux,uy,vx,vy,norm_u,norm_v,dot_uv,den,rx,ry,center_x,center_y;
    reg signed [MW-1:0] point_dx,point_dy,check_x,check_y;
    reg signed [RW-1:0] product,temporary;
    reg [RW-1:0] radius_num,test_distance,accumulator,multiplicand;
    reg [MW-1:0] multiplier;
    reg signed [MW-1:0] operand_a,operand_b;
    wire [RW-1:0] multiply_total=accumulator+(multiplier[0]?multiplicand:{RW{1'b0}});
    wire signed [RW-1:0] difference=temporary-product;
    wire signed [RW-1:0] addition=temporary+product;
    function automatic signed [MW-1:0] delta;
        input signed [COORD_W-1:0] p,q;
        reg signed [COORD_W:0] value;
        begin value=$signed({p[COORD_W-1],p})-$signed({q[COORD_W-1],q});delta={{(MW-COORD_W-1){value[COORD_W]}},value};end
    endfunction
    function automatic signed [MW-1:0] extend_coord;
        input signed [COORD_W-1:0] p;
        begin extend_coord={{(MW-COORD_W){p[COORD_W-1]}},p};end
    endfunction
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==EMIT;
    always @*begin
        operand_a=0;operand_b=0;
        if(checking)case(op)
            0:begin operand_a=den;operand_b=point_dx;end
            1:begin operand_a=check_x;operand_b=check_x;end
            2:begin operand_a=den;operand_b=point_dy;end
            3:begin operand_a=check_y;operand_b=check_y;end
            default:begin end
        endcase
        else case(op)
            0:begin operand_a=ux;operand_b=ux;end
            1:begin operand_a=uy;operand_b=uy;end
            2:begin operand_a=vx;operand_b=vx;end
            3:begin operand_a=vy;operand_b=vy;end
            4:begin operand_a=ux;operand_b=vx;end
            5:begin operand_a=uy;operand_b=vy;end
            6:begin operand_a=ux;operand_b=vy;end
            7:begin operand_a=uy;operand_b=vx;end
            8:begin operand_a=norm_u;operand_b=vy;end
            9:begin operand_a=norm_v;operand_b=uy;end
            10:begin operand_a=ux;operand_b=norm_v;end
            11:begin operand_a=vx;operand_b=norm_u;end
            12:begin operand_a=extend_coord(ax);operand_b=den;end
            13:begin operand_a=extend_coord(ay);operand_b=den;end
            14:begin operand_a=rx;operand_b=rx;end
            15:begin operand_a=ry;operand_b=ry;end
        endcase
    end
    // One packed point-bank read per scheduled edge; no read/write overlap.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && s_ready && s_keep && m_count<N)points[m_count]<={s_x,s_y};
        if(state==READ_A)point_q<=points[ia];
        if(state==READ_B)point_q<=points[ib];
        if(state==READ_C)point_q<=points[ic];
        if(state==POINT_READ)point_q<=points[scan];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;started<=0;overflow<=0;checking<=0;mul_negative<=0;kind<=1;
            ia<=0;ib<=0;ic<=0;scan<=0;op<=0;bit_index<=0;ax<=0;ay<=0;bx<=0;by<=0;
            ux<=0;uy<=0;vx<=0;vy<=0;norm_u<=0;norm_v<=0;dot_uv<=0;den<=0;rx<=0;ry<=0;
            center_x<=0;center_y<=0;point_dx<=0;point_dy<=0;check_x<=0;check_y<=0;
            product<=0;temporary<=0;radius_num<=0;test_distance<=0;accumulator<=0;multiplicand<=0;multiplier<=0;
            m_center_x_num<=0;m_center_y_num<=0;m_den<=0;m_radius_sq_num<=0;m_support<=0;m_status<=0;
            m_i<=0;m_j<=0;m_k<=0;m_count<=0;m_tag<=0;
        end else case(state)
            CAPTURE:if(s_valid && s_ready)begin
                if(!started)begin m_tag<=s_tag;started<=1;end
                if(s_keep)begin if(m_count<N)m_count<=m_count+1'b1;else overflow<=1;end
                if(s_last)state<=CHECK;
            end
            CHECK:begin
                m_center_x_num<=0;m_center_y_num<=0;m_den<=0;m_radius_sq_num<=0;m_support<=0;m_i<=0;m_j<=0;m_k<=0;
                if(overflow || m_count==0)begin m_status<=overflow?2:1;state<=EMIT;end
                else begin m_status<=0;kind<=1;ia<=0;ib<=0;ic<=0;state<=CAND_START;end
            end
            CAND_START:begin checking<=0;op<=0;scan<=0;state<=READ_A;end
            READ_A:state<=READ_B;
            READ_B:begin ax<=point_q[2*COORD_W-1:COORD_W];ay<=point_q[COORD_W-1:0];state<=READ_C;end
            READ_C:begin bx<=point_q[2*COORD_W-1:COORD_W];by<=point_q[COORD_W-1:0];state<=LOAD_GEOM;end
            LOAD_GEOM:begin
                ux<=delta(bx,ax);uy<=delta(by,ay);
                vx<=delta($signed(point_q[2*COORD_W-1:COORD_W]),ax);vy<=delta($signed(point_q[COORD_W-1:0]),ay);
                if(kind==1)begin
                    den<=1;rx<=0;ry<=0;center_x<=extend_coord(ax);center_y<=extend_coord(ay);radius_num<=0;
                    checking<=1;state<=POINT_READ;
                end else begin
                    if(kind==2)begin
                        den<=2;rx<=delta(bx,ax);ry<=delta(by,ay);
                        center_x<=extend_coord(ax)+extend_coord(bx);center_y<=extend_coord(ay)+extend_coord(by);
                    end
                    state<=OP_SETUP;
                end
            end
            OP_SETUP:begin
                multiplier<=operand_b[MW-1] ? -$unsigned(operand_b):$unsigned(operand_b);
                multiplicand<={{MW{1'b0}},operand_a[MW-1] ? -$unsigned(operand_a):$unsigned(operand_a)};
                accumulator<=0;mul_negative<=operand_a[MW-1]^operand_b[MW-1];bit_index<=0;state<=MUL_RUN;
            end
            MUL_RUN:begin
                if(bit_index==MW-1)begin product<=mul_negative ? -multiply_total:multiply_total;state<=OP_STORE;end
                else begin accumulator<=multiply_total;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;bit_index<=bit_index+1'b1;end
            end
            OP_STORE:begin
                op<=op+1'b1;state<=OP_SETUP;
                if(checking)case(op)
                    0:check_x<=product[MW-1:0]-rx;
                    1:temporary<=product;
                    2:check_y<=product[MW-1:0]-ry;
                    3:begin test_distance<=addition;state<=POINT_CHECK;end
                    default:state<=POINT_CHECK;
                endcase
                else case(op)
                    0,2,4,6,8,10,12,14:temporary<=product;
                    1:begin
                        norm_u<=addition[MW-1:0];
                        if(kind==2)begin radius_num<=addition;checking<=1;state<=POINT_READ;end
                    end
                    3:norm_v<=addition[MW-1:0];
                    5:begin dot_uv<=addition[MW-1:0];state<=CAND_CHECK;end
                    7:begin den<=difference[MW-1:0]<<<1;if(difference==0)state<=NEXT_CAND;end
                    9:rx<=difference[MW-1:0];
                    11:ry<=difference[MW-1:0];
                    13:begin
                        if(den[MW-1])begin
                            center_x<=-(temporary[MW-1:0]+rx);center_y<=-(product[MW-1:0]+ry);
                            den<=-den;rx<=-rx;ry<=-ry;
                        end else begin center_x<=temporary[MW-1:0]+rx;center_y<=product[MW-1:0]+ry;end
                    end
                    15:begin radius_num<=addition;checking<=1;state<=POINT_READ;end
                endcase
            end
            CAND_CHECK:begin
                if(dot_uv<0 || norm_u<dot_uv || norm_v<dot_uv)state<=NEXT_CAND;
                else state<=OP_SETUP;
            end
            POINT_READ:state<=POINT_SETUP;
            POINT_SETUP:begin
                point_dx<=delta($signed(point_q[2*COORD_W-1:COORD_W]),ax);
                point_dy<=delta($signed(point_q[COORD_W-1:0]),ay);op<=0;state<=OP_SETUP;
            end
            POINT_CHECK:begin
                if(test_distance>radius_num)state<=NEXT_CAND;
                else if(scan==m_count-1'b1)begin
                    m_center_x_num<=center_x;m_center_y_num<=center_y;m_den<=den;m_radius_sq_num<=radius_num;
                    m_support<=kind;m_i<=ia;m_j<=(kind>=2)?ib:{IW{1'b0}};m_k<=(kind==3)?ic:{IW{1'b0}};state<=EMIT;
                end else begin scan<=scan+1'b1;state<=POINT_READ;end
            end
            NEXT_CAND:begin
                state<=CAND_START;
                if(kind==1)begin kind<=2;ia<=0;ib<=1;ic<=0;end
                else if(kind==2)begin
                    if({1'b0,ib}+1<m_count)ib<=ib+1'b1;
                    else if({1'b0,ia}+2<m_count)begin ia<=ia+1'b1;ib<=ia+2;end
                    else if(m_count>=3)begin kind<=3;ia<=0;ib<=1;ic<=2;end
                    else begin m_status<=3;state<=EMIT;end
                end else begin
                    if({1'b0,ic}+1<m_count)ic<=ic+1'b1;
                    else if({1'b0,ib}+2<m_count)begin ib<=ib+1'b1;ic<=ib+2;end
                    else if({1'b0,ia}+3<m_count)begin ia<=ia+1'b1;ib<=ia+2;ic<=ia+3;end
                    else begin m_status<=3;state<=EMIT;end
                end
            end
            EMIT:if(m_ready)begin state<=CAPTURE;started<=0;overflow<=0;m_count<=0;m_tag<=0;end
            default:state<=CAPTURE;
        endcase
    end
    generate if(!GOOD || TAG_W<1 || TAG_W>32)begin:bad_parameters
        minimum_enclosing_circle_invalid_parameters invalid();
    end endgenerate
endmodule
`default_nettype wire
