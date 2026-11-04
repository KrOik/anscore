`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Exact Liang-Barsky interval clipping with positive rational denominators.
module segment_box_clip #(
    parameter integer W=12,TAG_W=8,
    localparam integer NUM_W=2*W+5
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [W-1:0] s_x0,s_y0,s_x1,s_y1,
    input wire signed [W-1:0] s_xmin,s_ymin,s_xmax,s_ymax,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [NUM_W-1:0] m_x0_num,m_y0_num,m_x1_num,m_y1_num,
    output reg [W:0] m_den0,m_den1,
    output reg m_visible,m_point,m_error,
    output reg [1:0] m_clipped,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer MW=W+2,PW=2*MW,SCW=$clog2(MW);
    localparam [4:0] IDLE=0,CHECK_BOX=1,EDGE_SETUP=2,CANDIDATE=3,
        LO_PRODUCT=4,LO_COMPARE=5,HI_PRODUCT=6,HI_COMPARE=7,
        FINAL_SETUP=8,FINAL_FIRST=9,FINAL_DONE=10,
        COORD_FIRST=11,COORD_SECOND=12,COORD_DONE=13,
        MULTIPLY=14,EMIT=15;
    reg [4:0] state,resume;
    reg signed [W-1:0] x0,y0,xmin,ymin,xmax,ymax;
    reg signed [W:0] dx,dy;
    reg [1:0] edge_index,coordinate;
    reg lower,less_than_lo,greater_than_lo;
    reg signed [MW-1:0] candidate_num;
    reg [W:0] candidate_den,lo_num,lo_den,hi_num,hi_den;
    reg signed [W:0] p,q;
    reg [PW-1:0] mul_shift,mul_acc;
    reg [MW-1:0] mul_factor;
    reg [SCW-1:0] mul_step;
    reg mul_negative;
    reg signed [NUM_W-1:0] product,first_product;
    wire [PW-1:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:{PW{1'b0}});
    wire signed [NUM_W-1:0] signed_product=mul_negative ?
        -$signed({1'b0,mul_next}):$signed({1'b0,mul_next});
    wire signed [W-1:0] origin_coordinate=coordinate[0]?y0:x0;
    wire signed [W:0] delta_coordinate=coordinate[0]?dy:dx;
    wire [W:0] coordinate_den=coordinate[1]?hi_den:lo_den;
    wire [W:0] coordinate_num=coordinate[1]?hi_num:lo_num;
    function automatic signed [MW-1:0] positive_fraction;
        input [W:0] value;
        begin positive_fraction=$signed({1'b0,value});end
    endfunction
    function automatic [MW-1:0] magnitude;
        input signed [MW-1:0] value;
        begin magnitude=value[MW-1]?-$unsigned(value):$unsigned(value);end
    endfunction
    task launch;
        input signed [MW-1:0] a,b;
        input [4:0] destination;
        begin
            mul_shift<=magnitude(a);mul_factor<=magnitude(b);
            mul_acc<=0;mul_step<=0;mul_negative<=a[MW-1]^b[MW-1];
            resume<=destination;state<=MULTIPLY;
        end
    endtask
    task advance_edge;
        begin
            if(edge_index==3) state<=FINAL_SETUP;
            else begin edge_index<=edge_index+1'b1;state<=EDGE_SETUP;end
        end
    endtask
    always @* begin
        p=-dx;q=$signed({x0[W-1],x0})-$signed({xmin[W-1],xmin});
        case(edge_index)
            1: begin p=dx;q=$signed({xmax[W-1],xmax})-$signed({x0[W-1],x0});end
            2: begin p=-dy;q=$signed({y0[W-1],y0})-$signed({ymin[W-1],ymin});end
            3: begin p=dy;q=$signed({ymax[W-1],ymax})-$signed({y0[W-1],y0});end
            default: begin end
        endcase
    end
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==EMIT;
`ifndef SYNTHESIS
    initial if(W<2 || W>24 || TAG_W<1 || TAG_W>32)
        $fatal(1,"invalid segment_box_clip parameters");
`endif
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;resume<=IDLE;x0<=0;y0<=0;xmin<=0;ymin<=0;xmax<=0;ymax<=0;
            dx<=0;dy<=0;edge_index<=0;coordinate<=0;lower<=0;
            less_than_lo<=0;greater_than_lo<=0;candidate_num<=0;candidate_den<=1;
            lo_num<=0;lo_den<=1;hi_num<=1;hi_den<=1;
            mul_shift<=0;mul_acc<=0;mul_factor<=0;mul_step<=0;mul_negative<=0;
            product<=0;first_product<=0;m_x0_num<=0;m_y0_num<=0;m_x1_num<=0;m_y1_num<=0;
            m_den0<=1;m_den1<=1;m_visible<=0;m_point<=0;m_error<=0;m_clipped<=0;m_tag<=0;
        end else case(state)
            IDLE: if(s_valid) begin
                x0<=s_x0;y0<=s_y0;xmin<=s_xmin;ymin<=s_ymin;xmax<=s_xmax;ymax<=s_ymax;
                dx<=$signed({s_x1[W-1],s_x1})-$signed({s_x0[W-1],s_x0});
                dy<=$signed({s_y1[W-1],s_y1})-$signed({s_y0[W-1],s_y0});
                m_error<=s_xmin>s_xmax || s_ymin>s_ymax;
                m_tag<=s_tag;m_visible<=0;m_point<=0;m_clipped<=0;
                m_x0_num<=0;m_y0_num<=0;m_x1_num<=0;m_y1_num<=0;m_den0<=1;m_den1<=1;
                lo_num<=0;lo_den<=1;hi_num<=1;hi_den<=1;edge_index<=0;state<=CHECK_BOX;
            end
            CHECK_BOX: if(m_error) state<=EMIT;else state<=EDGE_SETUP;
            EDGE_SETUP: if(p==0) begin
                if(q<0) state<=EMIT;else advance_edge();
            end else begin
                lower<=p<0;
                candidate_num<=p<0 ? -$signed({q[W],q}):$signed({q[W],q});
                candidate_den<=p<0 ? -$unsigned(p):$unsigned(p);
                state<=CANDIDATE;
            end
            CANDIDATE: if(lower && candidate_num<=0) advance_edge();
                else if(!lower && candidate_num<0) state<=EMIT;
                else if(lower && candidate_num>positive_fraction(candidate_den)) state<=EMIT;
                else if(!lower && candidate_num>=positive_fraction(candidate_den)) advance_edge();
                else launch(candidate_num,positive_fraction(lo_den),LO_PRODUCT);
            MULTIPLY: begin
                mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
                if(mul_step==MW-1) begin product<=signed_product;state<=resume;end
                else mul_step<=mul_step+1'b1;
            end
            LO_PRODUCT: begin
                first_product<=product;
                launch(positive_fraction(lo_num),positive_fraction(candidate_den),LO_COMPARE);
            end
            LO_COMPARE: begin
                less_than_lo<=first_product<product;greater_than_lo<=first_product>product;
                launch(candidate_num,positive_fraction(hi_den),HI_PRODUCT);
            end
            HI_PRODUCT: begin
                first_product<=product;
                launch(positive_fraction(hi_num),positive_fraction(candidate_den),HI_COMPARE);
            end
            HI_COMPARE: if((lower && first_product>product)||(!lower && less_than_lo)) state<=EMIT;
                else begin
                    if(lower && greater_than_lo) begin lo_num<=candidate_num[W:0];lo_den<=candidate_den;end
                    if(!lower && first_product<product) begin hi_num<=candidate_num[W:0];hi_den<=candidate_den;end
                    advance_edge();
                end
            FINAL_SETUP: launch(positive_fraction(lo_num),positive_fraction(hi_den),FINAL_FIRST);
            FINAL_FIRST: begin
                first_product<=product;launch(positive_fraction(hi_num),positive_fraction(lo_den),FINAL_DONE);
            end
            FINAL_DONE: begin
                m_visible<=1;m_point<=(dx==0 && dy==0)||(first_product==product);
                m_clipped<={hi_num<hi_den,lo_num!=0};m_den0<=lo_den;m_den1<=hi_den;
                coordinate<=0;state<=COORD_FIRST;
            end
            COORD_FIRST: launch($signed({{2{origin_coordinate[W-1]}},origin_coordinate}),
                                positive_fraction(coordinate_den),COORD_SECOND);
            COORD_SECOND: begin
                first_product<=product;
                launch($signed({delta_coordinate[W],delta_coordinate}),positive_fraction(coordinate_num),COORD_DONE);
            end
            COORD_DONE: begin
                case(coordinate)
                    0:m_x0_num<=first_product+product;
                    1:m_y0_num<=first_product+product;
                    2:m_x1_num<=first_product+product;
                    3:m_y1_num<=first_product+product;
                endcase
                if(coordinate==3) state<=EMIT;
                else begin coordinate<=coordinate+1'b1;state<=COORD_FIRST;end
            end
            EMIT: if(m_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
