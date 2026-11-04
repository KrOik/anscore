`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Small unordered point-set hull: insertion sort, deduplication, monotone chain.
module point_convex_hull #(
    parameter integer COORD_W=16,
    parameter integer MAX_POINTS=32,
    parameter integer TAG_W=8,
    localparam integer CW=(MAX_POINTS>1)?$clog2(MAX_POINTS+1):1,
    localparam integer HW=$clog2(2*MAX_POINTS+1),
    localparam integer VW=COORD_W+1,
    localparam integer PRODUCT_W=2*VW,
    localparam integer CROSS_W=PRODUCT_W+1
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_mask,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire signed [COORD_W-1:0] m_x,m_y,
    output wire [CW-1:0] m_index,
    output reg [CW-1:0] m_count,
    output wire m_first,m_last,m_empty,m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam [3:0] CAPTURE=0,FINISH=1,SORT_LOAD=2,SORT_STEP=3,
        UNIQUE_START=4,UNIQUE_STEP=5,HULL_START=6,FETCH=7,
        TURN_SETUP=8,MUL_FIRST=9,MUL_SECOND=10,APPEND=11,
        NEXT_POINT=12,EMIT=13;
    reg [3:0] state;
    reg [CW-1:0] count,i,j,scan,unique_count,out_index;
    reg [HW-1:0] hull_length,threshold;
    reg upper,started,overflow;
    reg signed [COORD_W-1:0] px[0:MAX_POINTS-1],py[0:MAX_POINTS-1];
    reg signed [COORD_W-1:0] hx[0:2*MAX_POINTS-1],hy[0:2*MAX_POINTS-1];
    reg signed [COORD_W-1:0] key_x,key_y,last_x,last_y,candidate_x,candidate_y;
    wire [CW-1:0] previous_index=(j!=0)?j-1'b1:0;
    wire [HW-1:0] origin_index=(hull_length>=2)?hull_length-2:0;
    wire [HW-1:0] endpoint_index=(hull_length!=0)?hull_length-1'b1:0;
    wire signed [COORD_W-1:0] origin_x=hx[origin_index],origin_y=hy[origin_index];
    wire signed [COORD_W-1:0] endpoint_x=hx[endpoint_index],endpoint_y=hy[endpoint_index];
    reg signed [VW-1:0] dx1,dy1,dx2,dy2;
    wire signed [VW-1:0] multiply_a=(state==MUL_FIRST)?dx1:dy1;
    wire signed [VW-1:0] multiply_b=(state==MUL_FIRST)?dy2:dx2;
    wire signed [PRODUCT_W-1:0] product=multiply_a*multiply_b;
    reg signed [PRODUCT_W-1:0] first_product;
    wire signed [CROSS_W-1:0] turn=$signed({first_product[PRODUCT_W-1],first_product})-
        $signed({product[PRODUCT_W-1],product});
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==EMIT;
    assign m_empty=m_count==0;
    assign m_error=overflow;
    assign m_x=m_empty?{COORD_W{1'b0}}:hx[out_index];
    assign m_y=m_empty?{COORD_W{1'b0}}:hy[out_index];
    assign m_index=out_index;
    assign m_first=out_index==0;
    assign m_last=m_empty || out_index==m_count-1'b1;
`ifndef SYNTHESIS
    initial if(COORD_W<2 || COORD_W>24 || MAX_POINTS<1 || MAX_POINTS>64 ||
               TAG_W<1 || TAG_W>32)
        $fatal(1,"invalid point_convex_hull parameters");
`endif
    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;count<=0;started<=0;overflow<=0;
            out_index<=0;m_count<=0;m_tag<=0;
        end else case(state)
            CAPTURE: if(s_valid) begin
                if(!started) begin started<=1;m_tag<=s_tag;end
                if(s_mask) begin
                    if(count<MAX_POINTS) begin px[count]<=s_x;py[count]<=s_y;count<=count+1'b1;end
                    else overflow<=1;
                end
                if(s_last) state<=FINISH;
            end
            FINISH: begin
                out_index<=0;
                if(overflow || count==0) begin m_count<=0;state<=EMIT;end
                else if(count==1) state<=UNIQUE_START;
                else begin i<=1;state<=SORT_LOAD;end
            end
            SORT_LOAD: begin key_x<=px[i];key_y<=py[i];j<=i;state<=SORT_STEP;end
            SORT_STEP: begin
                if(j!=0 && (($signed(px[previous_index])>key_x) ||
                    (px[previous_index]==key_x && $signed(py[previous_index])>key_y))) begin
                    px[j]<=px[previous_index];py[j]<=py[previous_index];j<=j-1'b1;
                end else begin
                    px[j]<=key_x;py[j]<=key_y;
                    if(i==count-1'b1) state<=UNIQUE_START;
                    else begin i<=i+1'b1;state<=SORT_LOAD;end
                end
            end
            UNIQUE_START: begin unique_count<=0;scan<=0;state<=UNIQUE_STEP;end
            UNIQUE_STEP: begin
                if(unique_count==0 || px[scan]!=last_x || py[scan]!=last_y) begin
                    px[unique_count]<=px[scan];py[unique_count]<=py[scan];
                    last_x<=px[scan];last_y<=py[scan];unique_count<=unique_count+1'b1;
                end
                if(scan==count-1'b1) state<=HULL_START;
                else scan<=scan+1'b1;
            end
            HULL_START: begin
                if(unique_count==1) begin
                    hx[0]<=px[0];hy[0]<=py[0];m_count<=1;state<=EMIT;
                end else begin hull_length<=0;threshold<=2;i<=0;upper<=0;state<=FETCH;end
            end
            FETCH: begin candidate_x<=px[i];candidate_y<=py[i];state<=TURN_SETUP;end
            TURN_SETUP: begin
                if(hull_length>=threshold) begin
                    dx1<=$signed({endpoint_x[COORD_W-1],endpoint_x})-$signed({origin_x[COORD_W-1],origin_x});
                    dy1<=$signed({endpoint_y[COORD_W-1],endpoint_y})-$signed({origin_y[COORD_W-1],origin_y});
                    dx2<=$signed({candidate_x[COORD_W-1],candidate_x})-$signed({origin_x[COORD_W-1],origin_x});
                    dy2<=$signed({candidate_y[COORD_W-1],candidate_y})-$signed({origin_y[COORD_W-1],origin_y});
                    state<=MUL_FIRST;
                end else state<=APPEND;
            end
            MUL_FIRST: begin first_product<=product;state<=MUL_SECOND;end
            MUL_SECOND: begin
                if(turn<=0) begin hull_length<=hull_length-1'b1;state<=TURN_SETUP;end
                else state<=APPEND;
            end
            APPEND: begin
                hx[hull_length]<=candidate_x;hy[hull_length]<=candidate_y;
                hull_length<=hull_length+1'b1;state<=NEXT_POINT;
            end
            NEXT_POINT: begin
                if(!upper) begin
                    if(i==unique_count-1'b1) begin
                        upper<=1;threshold<=hull_length+1'b1;i<=unique_count-2;state<=FETCH;
                    end else begin i<=i+1'b1;state<=FETCH;end
                end else if(i==0) begin m_count<=hull_length-1'b1;state<=EMIT;end
                else begin i<=i-1'b1;state<=FETCH;end
            end
            EMIT: if(m_ready) begin
                if(m_last) begin state<=CAPTURE;count<=0;started<=0;overflow<=0;out_index<=0;m_count<=0;end
                else out_index<=out_index+1'b1;
            end
        endcase
    end
endmodule
