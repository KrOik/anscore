`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Exact squared point-to-segment RDP; one physically shared RTL multiplier.
module polyline_rdp #(
    parameter integer COORD_W=12,
    parameter integer MAX_POINTS=32,
    parameter integer TAG_W=8,
    localparam integer IW=(MAX_POINTS>1)?$clog2(MAX_POINTS):1,
    localparam integer CW=$clog2(MAX_POINTS+1)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_keep,s_last,
    input wire [COORD_W-1:0] s_epsilon,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [COORD_W-1:0] m_x,m_y,
    output reg [IW-1:0] m_index,
    output reg [CW-1:0] m_count,
    output reg m_first,m_last,m_empty,m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer DW=COORD_W+1,MW=2*COORD_W+3,RW=2*MW;
    localparam [5:0] CAPTURE=0,PREPARE=1,EPS_DONE=2,POP=3,
        SEG_CHECK=4,A_READ=5,B_READ=6,ENDPOINTS=7,NORM_X=8,
        NORM_Y=9,NORM_DONE=10,P_READ=11,P_LOAD=12,DOT_X=13,
        DOT_Y=14,DOT_DONE=15,CROSS_X=16,CROSS_Y=17,CROSS_DONE=18,
        DIST_X=19,DIST_Y=20,DIST_DONE=21,EVALUATE=22,
        THRESHOLD=23,SPLIT=24,COUNT_KEEP=25,OUT_SCAN=26,
        OUT_LOAD=27,OUT_HOLD=28,MULTIPLY=29;
    reg [5:0] state,resume;
    reg signed [COORD_W-1:0] x_mem[0:MAX_POINTS-1],y_mem[0:MAX_POINTS-1];
    reg signed [COORD_W-1:0] x_q,y_q,ax,ay,bx,by;
    reg [CW-1:0] stack_lo[0:MAX_POINTS-1],stack_hi[0:MAX_POINTS-1];
    reg [MAX_POINTS-1:0] kept;
    reg [CW-1:0] count,frame_count,sp,seg_lo,seg_hi,scan,best_index;
    reg [CW-1:0] out_index,out_ordinal;
    reg overflow,started;
    reg [COORD_W-1:0] epsilon;
    reg signed [DW-1:0] dx,dy,ux,uy,vx,vy,du,dv;
    reg signed [MW-1:0] mul_a,mul_b;
    reg signed [RW-1:0] product,p1;
    reg [MW-1:0] norm,epsilon2;
    reg [RW-1:0] best_score;
    wire signed [RW-1:0] pair_sum=p1+product;
    wire signed [RW-1:0] pair_difference=p1-product;
    wire [MW-1:0] cross_magnitude=pair_difference[RW-1] ?
        -pair_difference : pair_difference;
    wire [MW-1:0] denominator=(norm==0)?{{(MW-1){1'b0}},1'b1}:norm;
    wire accepted_keep=s_keep && count<MAX_POINTS;
    wire [CW-1:0] next_count=count+accepted_keep;
    function automatic signed [MW-1:0] extend_difference;
        input signed [DW-1:0] value;
        begin extend_difference={{(MW-DW){value[DW-1]}},value};end
    endfunction
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUT_HOLD;
`ifndef SYNTHESIS
    initial if(COORD_W<2 || COORD_W>16 || MAX_POINTS<1 ||
               MAX_POINTS>64 || TAG_W<1 || TAG_W>32)
        $fatal(1,"invalid polyline_rdp parameters");
`endif
    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;resume<=CAPTURE;count<=0;frame_count<=0;
            started<=0;overflow<=0;epsilon<=0;sp<=0;seg_lo<=0;seg_hi<=0;
            scan<=0;best_index<=0;out_index<=0;out_ordinal<=0;kept<=0;
            x_q<=0;y_q<=0;ax<=0;ay<=0;bx<=0;by<=0;
            dx<=0;dy<=0;ux<=0;uy<=0;vx<=0;vy<=0;du<=0;dv<=0;
            mul_a<=0;mul_b<=0;product<=0;p1<=0;norm<=0;epsilon2<=0;best_score<=0;
            m_x<=0;m_y<=0;m_index<=0;m_count<=0;m_first<=0;m_last<=0;
            m_empty<=0;m_error<=0;m_tag<=0;
        end else case(state)
            CAPTURE: if(s_valid) begin
                if(!started) begin epsilon<=s_epsilon;m_tag<=s_tag;started<=1;end
                if(accepted_keep) begin
                    x_mem[count]<=s_x;y_mem[count]<=s_y;count<=next_count;
                end else if(s_keep) overflow<=1;
                if(s_last) begin
                    frame_count<=next_count;
                    m_error<=overflow || (s_keep && count==MAX_POINTS);
                    state<=PREPARE;
                end
            end
            PREPARE: begin
                kept<=0;m_count<=0;out_index<=0;out_ordinal<=0;
                if(m_error || frame_count==0) begin
                    m_x<=0;m_y<=0;m_index<=0;m_first<=1;m_last<=1;
                    m_empty<=1;state<=OUT_HOLD;
                end else begin
                    kept[0]<=1;kept[frame_count-1'b1]<=1;
                    stack_lo[0]<=0;stack_hi[0]<=frame_count-1'b1;sp<=1;
                    mul_a<=$signed({{(MW-COORD_W){1'b0}},epsilon});
                    mul_b<=$signed({{(MW-COORD_W){1'b0}},epsilon});
                    resume<=EPS_DONE;state<=MULTIPLY;
                end
            end
            MULTIPLY: begin product<=mul_a*mul_b;state<=resume;end
            EPS_DONE: begin epsilon2<=product[MW-1:0];state<=POP;end
            POP: if(sp==0) begin scan<=0;m_count<=0;state<=COUNT_KEEP;end
                 else begin
                     seg_lo<=stack_lo[sp-1'b1];seg_hi<=stack_hi[sp-1'b1];
                     sp<=sp-1'b1;state<=SEG_CHECK;
                 end
            SEG_CHECK: if(seg_hi<=seg_lo+1'b1) state<=POP;else state<=A_READ;
            A_READ: begin x_q<=x_mem[seg_lo];y_q<=y_mem[seg_lo];state<=B_READ;end
            B_READ: begin
                ax<=x_q;ay<=y_q;x_q<=x_mem[seg_hi];y_q<=y_mem[seg_hi];
                state<=ENDPOINTS;
            end
            ENDPOINTS: begin
                bx<=x_q;by<=y_q;
                dx<=$signed({x_q[COORD_W-1],x_q})-$signed({ax[COORD_W-1],ax});
                dy<=$signed({y_q[COORD_W-1],y_q})-$signed({ay[COORD_W-1],ay});
                state<=NORM_X;
            end
            NORM_X: begin
                mul_a<=extend_difference(dx);mul_b<=extend_difference(dx);
                resume<=NORM_Y;state<=MULTIPLY;
            end
            NORM_Y: begin
                p1<=product;mul_a<=extend_difference(dy);mul_b<=extend_difference(dy);
                resume<=NORM_DONE;state<=MULTIPLY;
            end
            NORM_DONE: begin
                norm<=pair_sum[MW-1:0];scan<=seg_lo+1'b1;
                best_index<=seg_lo+1'b1;best_score<=0;state<=P_READ;
            end
            P_READ: begin x_q<=x_mem[scan];y_q<=y_mem[scan];state<=P_LOAD;end
            P_LOAD: begin
                ux<=$signed({x_q[COORD_W-1],x_q})-$signed({ax[COORD_W-1],ax});
                uy<=$signed({y_q[COORD_W-1],y_q})-$signed({ay[COORD_W-1],ay});
                vx<=$signed({x_q[COORD_W-1],x_q})-$signed({bx[COORD_W-1],bx});
                vy<=$signed({y_q[COORD_W-1],y_q})-$signed({by[COORD_W-1],by});
                state<=DOT_X;
            end
            DOT_X: if(norm==0) begin du<=ux;dv<=uy;state<=DIST_X;end
                else begin
                    mul_a<=extend_difference(ux);mul_b<=extend_difference(dx);
                    resume<=DOT_Y;state<=MULTIPLY;
                end
            DOT_Y: begin
                p1<=product;mul_a<=extend_difference(uy);mul_b<=extend_difference(dy);
                resume<=DOT_DONE;state<=MULTIPLY;
            end
            DOT_DONE: if(pair_sum<=0) begin du<=ux;dv<=uy;state<=DIST_X;end
                else if(pair_sum >= $signed({{(RW-MW){1'b0}},norm})) begin
                    du<=vx;dv<=vy;state<=DIST_X;
                end else state<=CROSS_X;
            CROSS_X: begin
                mul_a<=extend_difference(ux);mul_b<=extend_difference(dy);
                resume<=CROSS_Y;state<=MULTIPLY;
            end
            CROSS_Y: begin
                p1<=product;mul_a<=extend_difference(uy);mul_b<=extend_difference(dx);
                resume<=CROSS_DONE;state<=MULTIPLY;
            end
            CROSS_DONE: begin
                mul_a<=$signed(cross_magnitude);mul_b<=$signed(cross_magnitude);
                resume<=EVALUATE;state<=MULTIPLY;
            end
            DIST_X: begin
                mul_a<=extend_difference(du);mul_b<=extend_difference(du);
                resume<=DIST_Y;state<=MULTIPLY;
            end
            DIST_Y: begin
                p1<=product;mul_a<=extend_difference(dv);mul_b<=extend_difference(dv);
                resume<=DIST_DONE;state<=MULTIPLY;
            end
            DIST_DONE: begin
                mul_a<=$signed(pair_sum[MW-1:0]);mul_b<=$signed(denominator);
                resume<=EVALUATE;state<=MULTIPLY;
            end
            EVALUATE: begin
                // Strict improvement gives the first input index on exact ties.
                if($unsigned(product)>best_score) begin
                    best_score<=$unsigned(product);best_index<=scan;
                end
                if(scan+1'b1==seg_hi) state<=THRESHOLD;
                else begin scan<=scan+1'b1;state<=P_READ;end
            end
            THRESHOLD: begin
                mul_a<=$signed(epsilon2);mul_b<=$signed(denominator);
                resume<=SPLIT;state<=MULTIPLY;
            end
            SPLIT: begin
                if(best_score>$unsigned(product)) begin
                    kept[best_index]<=1;
                    // Right then left: LIFO processes the left child first.
                    stack_lo[sp]<=best_index;stack_hi[sp]<=seg_hi;
                    stack_lo[sp+1'b1]<=seg_lo;stack_hi[sp+1'b1]<=best_index;
                    sp<=sp+2'd2;
                end
                state<=POP;
            end
            COUNT_KEEP: begin
                if(kept[scan]) m_count<=m_count+1'b1;
                if(scan+1'b1==frame_count) begin out_index<=0;state<=OUT_SCAN;end
                else scan<=scan+1'b1;
            end
            OUT_SCAN: if(kept[out_index]) begin
                x_q<=x_mem[out_index];y_q<=y_mem[out_index];state<=OUT_LOAD;
            end else out_index<=out_index+1'b1;
            OUT_LOAD: begin
                m_x<=x_q;m_y<=y_q;m_index<=out_index[IW-1:0];
                m_first<=out_ordinal==0;m_last<=out_ordinal+1'b1==m_count;
                m_empty<=0;state<=OUT_HOLD;
            end
            OUT_HOLD: if(m_ready) begin
                if(m_last) begin
                    count<=0;started<=0;overflow<=0;state<=CAPTURE;
                end else begin
                    out_ordinal<=out_ordinal+1'b1;out_index<=out_index+1'b1;state<=OUT_SCAN;
                end
            end
            default: state<=CAPTURE;
        endcase
    end
endmodule
