// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module polygon_triangulation #(
    parameter integer COORD_W=8,MAX_VERTICES=16,TAG_W=8,
    localparam integer IW=(MAX_VERTICES>1)?$clog2(MAX_VERTICES):1,
    localparam integer CW=(MAX_VERTICES>0)?$clog2(MAX_VERTICES+1):1
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,input wire s_keep,s_last,s_error,
    input wire [TAG_W-1:0] s_tag,output wire m_valid,input wire m_ready,
    output wire [IW-1:0] m_id0,m_id1,m_id2,
    output wire signed [COORD_W-1:0] m_x0,m_y0,m_x1,m_y1,m_x2,m_y2,
    output wire [CW-1:0] m_vertices,m_count,output wire [IW-1:0] m_index,
    output wire [3:0] m_error,output wire m_first,m_last,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer DW=COORD_W+1,PW=2*DW,XW=PW+1,AW=XW+IW;
    localparam [5:0] CAPTURE=0,CHECK=1,DUP_START=2,DUP_EVAL=3,
      ADJ_START=4,ADJ_CROSS=5,ADJ_EVAL=6,EDGE_NEXT=7,EDGE_D1=8,
      EDGE_S1=9,EDGE_S2=10,EDGE_S3=11,EDGE_EVAL=12,
      AREA_START=13,AREA_CROSS=14,AREA_ADD=15,AREA_DONE=16,
      EAR_START=17,EAR_CROSS=18,EAR_TURN=19,POINT_NEXT=20,
      POINT_C1=21,POINT_S1=22,POINT_S2=23,POINT_S3=24,EAR_NEXT=25,
      TRI_STORE=26,COMPACT_NEXT=27,COMPACT_READ=28,COMPACT_WRITE=29,
      FINAL_CROSS=30,FINAL_EVAL=31,FINAL_STORE=32,OUT_READ=33,
      OUT_LOAD=34,OUT_HOLD=35,ERROR_PREP=36,L_RING=37,L_COORD=38,
      L_LATCH=39,D_SETUP=40,D_MUL1=41,D_MUL2=42,D_SUB=43;
    localparam [2:0] LD_DUP=0,LD_ADJ=1,LD_EDGE=2,LD_AREA=3,
      LD_EAR=4,LD_POINT=5,LD_FINAL=6,LD_OUT=7;
    generate if(COORD_W<2 || COORD_W>12 || MAX_VERTICES<3 ||
                MAX_VERTICES>32 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        polygon_triangulation_invalid_parameters__see_README rejected();
    end endgenerate

    reg signed [COORD_W-1:0] vertex_x[0:MAX_VERTICES-1],vertex_y[0:MAX_VERTICES-1];
    reg [IW-1:0] ring[0:MAX_VERTICES-1];
    reg [3*IW-1:0] triangles[0:MAX_VERTICES-3];
    reg [5:0] state,load_return,det_return;
    reg [TAG_W-1:0] tag;
    reg started,winding;
    reg [3:0] errors;
    reg [CW-1:0] count,live_n,vi,vj,tri_count;
    reg [IW-1:0] out_index;
    reg [2:0] load_mode;
    reg [1:0] load_slot,load_last,det_a,det_b,det_c;
    reg signed [COORD_W-1:0] px[0:3],py[0:3];
    reg [IW-1:0] pid[0:2];
    reg signed [COORD_W-1:0] x_q,y_q;
    reg [IW-1:0] ring_q;
    reg [3*IW-1:0] tri_q;
    reg signed [DW-1:0] dx,dy,ux,uy;
    reg signed [PW-1:0] product_first,product_second;
    reg signed [XW-1:0] cross_q;
    reg signed [AW-1:0] area_sum;
    reg [1:0] sign1,sign2,sign3;

    wire [CW-1:0] previous_i=(vi==0)?live_n-1'b1:vi-1'b1;
    wire [CW-1:0] following_i=(vi+1'b1==live_n)?{CW{1'b0}}:vi+1'b1;
    wire [CW-1:0] original_prev=(vi==0)?count-1'b1:vi-1'b1;
    wire [CW-1:0] original_next=(vi+1'b1==count)?{CW{1'b0}}:vi+1'b1;
    wire [CW-1:0] original_jnext=(vj+1'b1==count)?{CW{1'b0}}:vj+1'b1;
    reg [IW-1:0] load_index;
    wire load_ring=load_mode==LD_EAR || load_mode==LD_POINT || load_mode==LD_FINAL;
    always @* begin
        load_index=0;
        case(load_mode)
        LD_DUP:load_index=(load_slot==0)?vi[IW-1:0]:vj[IW-1:0];
        LD_ADJ:case(load_slot)
          0:load_index=original_prev[IW-1:0];1:load_index=vi[IW-1:0];
          default:load_index=original_next[IW-1:0];endcase
        LD_EDGE:case(load_slot)
          0:load_index=vi[IW-1:0];1:load_index=original_next[IW-1:0];
          2:load_index=vj[IW-1:0];default:load_index=original_jnext[IW-1:0];endcase
        LD_AREA:case(load_slot)
          0:load_index=0;1:load_index=vj[IW-1:0];default:load_index=vj[IW-1:0]+1'b1;endcase
        LD_EAR:case(load_slot)
          0:load_index=previous_i[IW-1:0];1:load_index=vi[IW-1:0];
          default:load_index=following_i[IW-1:0];endcase
        LD_POINT:load_index=vj[IW-1:0];
        LD_FINAL:load_index={{(IW-2){1'b0}},load_slot};
        LD_OUT:case(load_slot)
          0:load_index=tri_q[IW-1:0];1:load_index=tri_q[2*IW-1:IW];
          default:load_index=tri_q[3*IW-1:2*IW];endcase
        endcase
    end
    wire [IW-1:0] coordinate_address=load_ring?ring_q:load_index;
    wire signed [DW-1:0] mul_a=(state==D_MUL1)?dx:dy;
    wire signed [DW-1:0] mul_b=(state==D_MUL1)?uy:ux;
    wire signed [PW-1:0] product=mul_a*mul_b;
    wire [1:0] cross_sign=(cross_q==0)?2'b00:(cross_q[XW-1]?2'b10:2'b01);
    wire strict_turn=winding?(cross_q<0):(cross_q>0);
    wire outside=winding?(cross_q>0):(cross_q<0);
    wire signed [AW-1:0] area_next=area_sum+{{IW{cross_q[XW-1]}},cross_q};
    function automatic in_box(
        input signed [COORD_W-1:0] x,y,ax,ay,bx,by
    ); begin
        in_box=((x>=ax && x<=bx)||(x>=bx && x<=ax)) &&
               ((y>=ay && y<=by)||(y>=by && y<=ay));
    end endfunction
    wire intersection=(sign1!=0 && sign2!=0 && sign1!=sign2 &&
                       sign3!=0 && cross_sign!=0 && sign3!=cross_sign) ||
        (sign1==0 && in_box(px[2],py[2],px[0],py[0],px[1],py[1])) ||
        (sign2==0 && in_box(px[3],py[3],px[0],py[0],px[1],py[1])) ||
        (sign3==0 && in_box(px[0],py[0],px[2],py[2],px[3],py[3])) ||
        (cross_sign==0 && in_box(px[1],py[1],px[2],py[2],px[3],py[3]));
    wire [3*IW-1:0] triangle_word=winding?{pid[1],pid[2],pid[0]}:{pid[2],pid[1],pid[0]};
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_id0=(errors!=0)?{IW{1'b0}}:pid[0];
    assign m_id1=(errors!=0)?{IW{1'b0}}:pid[1];
    assign m_id2=(errors!=0)?{IW{1'b0}}:pid[2];
    assign m_x0=(errors!=0)?{COORD_W{1'b0}}:px[0];
    assign m_y0=(errors!=0)?{COORD_W{1'b0}}:py[0];
    assign m_x1=(errors!=0)?{COORD_W{1'b0}}:px[1];
    assign m_y1=(errors!=0)?{COORD_W{1'b0}}:py[1];
    assign m_x2=(errors!=0)?{COORD_W{1'b0}}:px[2];
    assign m_y2=(errors!=0)?{COORD_W{1'b0}}:py[2];
    assign m_vertices=(errors!=0)?{CW{1'b0}}:count;
    assign m_count=(errors!=0)?{CW{1'b0}}:tri_count;
    assign m_index=out_index;assign m_error=errors;assign m_tag=tag;
    assign m_first=m_valid && out_index==0;
    assign m_last=m_valid && (errors!=0 || out_index+1'b1==tri_count);

    // All banks have scheduled synchronous reads and no reset. Ownership writes precede reads.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && s_keep && count<MAX_VERTICES)begin
            vertex_x[count]<=s_x;vertex_y[count]<=s_y;ring[count]<=count[IW-1:0];
        end
        if(state==L_RING && load_ring)ring_q<=ring[load_index];
        if(state==COMPACT_READ)ring_q<=ring[vj+1'b1];
        if(state==COMPACT_WRITE)ring[vj]<=ring_q;
        if(state==L_COORD)begin x_q<=vertex_x[coordinate_address];y_q<=vertex_y[coordinate_address];end
        if(state==TRI_STORE || state==FINAL_STORE)triangles[tri_count]<=triangle_word;
        if(state==OUT_READ)tri_q<=triangles[out_index];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;tag<=0;started<=0;errors<=0;count<=0;tri_count<=0;out_index<=0;
            px[0]<=0;px[1]<=0;px[2]<=0;py[0]<=0;py[1]<=0;py[2]<=0;
            pid[0]<=0;pid[1]<=0;pid[2]<=0;
        end else case(state)
        CAPTURE:if(s_valid)begin
            if(!started)begin tag<=s_tag;started<=1;end
            if(s_error)errors[1]<=1;
            if(s_keep)begin
                if(count<MAX_VERTICES)count<=count+1'b1;else errors[0]<=1;
            end
            if(s_last)state<=CHECK;
        end
        CHECK:begin
            if(errors!=0)state<=ERROR_PREP;
            else if(count<3)begin errors[2]<=1;state<=ERROR_PREP;end
            else begin vi<=0;vj<=1;tri_count<=0;state<=DUP_START;end
        end
        DUP_START:begin load_mode<=LD_DUP;load_slot<=0;load_last<=1;load_return<=DUP_EVAL;state<=L_RING;end
        DUP_EVAL:begin
            if(px[0]==px[1] && py[0]==py[1])begin errors[2]<=1;state<=ERROR_PREP;end
            else if(vi+2==count && vj+1'b1==count)begin vi<=0;state<=ADJ_START;end
            else begin
                if(vj+1'b1<count)vj<=vj+1'b1;else begin vi<=vi+1'b1;vj<=vi+2;end
                state<=DUP_START;
            end
        end
        ADJ_START:begin load_mode<=LD_ADJ;load_slot<=0;load_last<=2;load_return<=ADJ_CROSS;state<=L_RING;end
        ADJ_CROSS:begin det_a<=0;det_b<=1;det_c<=2;det_return<=ADJ_EVAL;state<=D_SETUP;end
        ADJ_EVAL:begin
            if(cross_q==0 && !in_box(px[1],py[1],px[0],py[0],px[2],py[2]))begin errors[2]<=1;state<=ERROR_PREP;end
            else if(vi+1'b1==count)begin vi<=0;vj<=1;state<=EDGE_NEXT;end
            else begin vi<=vi+1'b1;state<=ADJ_START;end
        end
        EDGE_NEXT:begin
            if(vi+1'b1==count)begin vj<=1;area_sum<=0;state<=AREA_START;end
            else if(vj==vi+1'b1 || (vi==0 && vj+1'b1==count))begin
                if(vj+1'b1<count)vj<=vj+1'b1;else begin vi<=vi+1'b1;vj<=vi+2;end
            end else begin load_mode<=LD_EDGE;load_slot<=0;load_last<=3;load_return<=EDGE_D1;state<=L_RING;end
        end
        EDGE_D1:begin det_a<=0;det_b<=1;det_c<=2;det_return<=EDGE_S1;state<=D_SETUP;end
        EDGE_S1:begin sign1<=cross_sign;det_a<=0;det_b<=1;det_c<=3;det_return<=EDGE_S2;state<=D_SETUP;end
        EDGE_S2:begin sign2<=cross_sign;det_a<=2;det_b<=3;det_c<=0;det_return<=EDGE_S3;state<=D_SETUP;end
        EDGE_S3:begin sign3<=cross_sign;det_a<=2;det_b<=3;det_c<=1;det_return<=EDGE_EVAL;state<=D_SETUP;end
        EDGE_EVAL:begin
            if(intersection)begin errors[2]<=1;state<=ERROR_PREP;end
            else begin
                if(vj+1'b1<count)vj<=vj+1'b1;else begin vi<=vi+1'b1;vj<=vi+2;end
                state<=EDGE_NEXT;
            end
        end
        AREA_START:begin load_mode<=LD_AREA;load_slot<=0;load_last<=2;load_return<=AREA_CROSS;state<=L_RING;end
        AREA_CROSS:begin det_a<=0;det_b<=1;det_c<=2;det_return<=AREA_ADD;state<=D_SETUP;end
        AREA_ADD:begin area_sum<=area_next;if(vj+2==count)state<=AREA_DONE;else begin vj<=vj+1'b1;state<=AREA_START;end end
        AREA_DONE:begin
            if(area_sum==0)begin errors[2]<=1;state<=ERROR_PREP;end
            else begin winding<=area_sum[AW-1];live_n<=count;vi<=0;state<=EAR_START;end
        end
        EAR_START:begin
            load_mode<=(live_n==3)?LD_FINAL:LD_EAR;load_slot<=0;load_last<=2;
            load_return<=(live_n==3)?FINAL_CROSS:EAR_CROSS;state<=L_RING;
        end
        EAR_CROSS:begin det_a<=0;det_b<=1;det_c<=2;det_return<=EAR_TURN;state<=D_SETUP;end
        EAR_TURN:if(!strict_turn)state<=EAR_NEXT;else begin vj<=0;state<=POINT_NEXT;end
        POINT_NEXT:begin
            if(vj==live_n)state<=TRI_STORE;
            else if(vj==previous_i || vj==vi || vj==following_i)vj<=vj+1'b1;
            else begin load_mode<=LD_POINT;load_slot<=3;load_last<=3;load_return<=POINT_C1;state<=L_RING;end
        end
        POINT_C1:begin det_a<=0;det_b<=1;det_c<=3;det_return<=POINT_S1;state<=D_SETUP;end
        POINT_S1:if(outside)begin vj<=vj+1'b1;state<=POINT_NEXT;end
            else begin det_a<=1;det_b<=2;det_c<=3;det_return<=POINT_S2;state<=D_SETUP;end
        POINT_S2:if(outside)begin vj<=vj+1'b1;state<=POINT_NEXT;end
            else begin det_a<=2;det_b<=0;det_c<=3;det_return<=POINT_S3;state<=D_SETUP;end
        POINT_S3:if(outside)begin vj<=vj+1'b1;state<=POINT_NEXT;end else state<=EAR_NEXT;
        EAR_NEXT:if(vi+1'b1==live_n)begin errors[3]<=1;state<=ERROR_PREP;end
            else begin vi<=vi+1'b1;state<=EAR_START;end
        TRI_STORE:begin tri_count<=tri_count+1'b1;vj<=vi;state<=COMPACT_NEXT;end
        COMPACT_NEXT:if(vj+1'b1==live_n)begin live_n<=live_n-1'b1;vi<=0;state<=EAR_START;end else state<=COMPACT_READ;
        COMPACT_READ:state<=COMPACT_WRITE;
        COMPACT_WRITE:begin vj<=vj+1'b1;state<=COMPACT_NEXT;end
        FINAL_CROSS:begin det_a<=0;det_b<=1;det_c<=2;det_return<=FINAL_EVAL;state<=D_SETUP;end
        FINAL_EVAL:if(!strict_turn)begin errors[3]<=1;state<=ERROR_PREP;end else state<=FINAL_STORE;
        FINAL_STORE:begin tri_count<=tri_count+1'b1;out_index<=0;state<=OUT_READ;end
        OUT_READ:state<=OUT_LOAD;
        OUT_LOAD:begin load_mode<=LD_OUT;load_slot<=0;load_last<=2;load_return<=OUT_HOLD;state<=L_RING;end
        OUT_HOLD:if(m_ready)begin
            if(errors!=0 || out_index+1'b1==tri_count)begin state<=CAPTURE;count<=0;started<=0;errors<=0;end
            else begin out_index<=out_index+1'b1;state<=OUT_READ;end
        end
        ERROR_PREP:begin out_index<=0;tri_count<=0;state<=OUT_HOLD;end
        L_RING:state<=L_COORD;
        L_COORD:begin if(load_slot<3)pid[load_slot]<=coordinate_address;state<=L_LATCH;end
        L_LATCH:begin
            px[load_slot]<=x_q;py[load_slot]<=y_q;
            if(load_slot==load_last)state<=load_return;else begin load_slot<=load_slot+1'b1;state<=L_RING;end
        end
        D_SETUP:begin
            dx<=$signed({px[det_b][COORD_W-1],px[det_b]})-$signed({px[det_a][COORD_W-1],px[det_a]});
            dy<=$signed({py[det_b][COORD_W-1],py[det_b]})-$signed({py[det_a][COORD_W-1],py[det_a]});
            ux<=$signed({px[det_c][COORD_W-1],px[det_c]})-$signed({px[det_a][COORD_W-1],px[det_a]});
            uy<=$signed({py[det_c][COORD_W-1],py[det_c]})-$signed({py[det_a][COORD_W-1],py[det_a]});state<=D_MUL1;
        end
        D_MUL1:begin product_first<=product;state<=D_MUL2;end
        D_MUL2:begin product_second<=product;state<=D_SUB;end
        D_SUB:begin
            cross_q<=$signed({product_first[PW-1],product_first})-$signed({product_second[PW-1],product_second});state<=det_return;
        end
        default:begin errors[3]<=1;state<=ERROR_PREP;end
        endcase
    end
endmodule
