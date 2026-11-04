// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ram_fenwick_index #(
    parameter integer BUCKETS=64,COUNT_W=16,TAG_W=8,
    localparam integer IW=BUCKETS>1?$clog2(BUCKETS):1,
    localparam integer SW=COUNT_W+(BUCKETS>1?$clog2(BUCKETS):0)
)(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_lo,c_hi,
    input wire [COUNT_W-1:0] c_value,
    input wire [SW-1:0] c_rank,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,
    output wire [1:0] r_op,
    output reg [1:0] r_status,
    output reg [IW-1:0] r_index,
    output reg [SW-1:0] r_sum,
    output wire [SW-1:0] r_total,
    output reg [TAG_W-1:0] r_tag
);
    localparam integer NW=BUCKETS>1?$clog2(BUCKETS+1):1;
    localparam [NW-1:0] FIRST_STEP=(1<<(NW-1));
    localparam [3:0] CLEAR=0,IDLE=1,LEAF_READ=2,LEAF_CHECK=3,
        UPDATE_READ=4,UPDATE_CALC=5,UPDATE_WRITE=6,
        PREFIX_READ=7,PREFIX_ACCUM=8,PREFIX_NEXT=9,RANGE_FINISH=10,
        SELECT_STEP=11,SELECT_READ=12,SELECT_CHECK=13,SELECT_FINISH=14,RESPONSE=15;
    reg [3:0] state;
    reg [COUNT_W-1:0] leaves[0:BUCKETS-1];
    reg [SW-1:0] tree[0:BUCKETS-1];
    reg [COUNT_W-1:0] leaf_q,value_q,delta;
    reg [SW-1:0] tree_q,tree_next,rank_q,prefix_acc,right_sum,search_mass,total;
    reg [IW-1:0] clear_index,leaf_index;
    reg [NW-1:0] walk,left_end,search_index,step;
    reg [1:0] op_q;
    reg subtract,left_phase,clear_response;
    wire [NW-1:0] lowbit=walk&(~walk+1'b1);
    wire [NW:0] next_update={1'b0,walk}+{1'b0,lowbit};
    wire [NW:0] select_candidate={1'b0,search_index}+{1'b0,step};
    wire [NW:0] select_address=select_candidate-1'b1;
    wire [NW-1:0] walk_address=walk-1'b1;
    wire [SW:0] selected_mass={1'b0,search_mass}+{1'b0,tree_q};
    assign c_ready=!rst && state==IDLE;
    assign r_valid=!rst && state==RESPONSE;
    assign r_total=total;
    assign r_op=op_q;

    // Two independent single-read/single-write banks. All read and write phases
    // are disjoint; neither bank relies on read-during-write collision semantics.
    always @(posedge clk)if(!rst)begin
        if(state==CLEAR)begin leaves[clear_index]<=0;tree[clear_index]<=0;end
        if(state==LEAF_READ)leaf_q<=leaves[leaf_index];
        if(state==LEAF_CHECK)leaves[leaf_index]<=value_q;
        if(state==UPDATE_READ || state==PREFIX_READ)tree_q<=tree[walk_address[IW-1:0]];
        if(state==SELECT_READ)tree_q<=tree[select_address[IW-1:0]];
        if(state==UPDATE_WRITE)tree[walk_address[IW-1:0]]<=tree_next;
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;clear_index<=0;op_q<=0;clear_response<=0;total<=0;
            r_status<=0;r_index<=0;r_sum<=0;r_tag<=0;
        end else case(state)
            CLEAR:if(clear_index==BUCKETS-1)state<=clear_response?RESPONSE:IDLE;
                else clear_index<=clear_index+1'b1;
            IDLE:if(c_valid)begin
                op_q<=c_op;r_tag<=c_tag;r_status<=0;r_index<=0;r_sum<=0;
                case(c_op)
                    0:if(c_lo>=BUCKETS)begin r_status<=1;state<=RESPONSE;end
                        else begin leaf_index<=c_lo[IW-1:0];value_q<=c_value;
                            walk<=c_lo+1'b1;state<=LEAF_READ;end
                    1:if(c_lo>=BUCKETS || c_hi>=BUCKETS || c_lo>c_hi)begin r_status<=1;state<=RESPONSE;end
                        else begin left_end<=c_lo[NW-1:0];walk<=c_hi+1'b1;
                            prefix_acc<=0;right_sum<=0;left_phase<=0;state<=PREFIX_READ;end
                    2:if(c_rank>=total)begin r_status<=2;state<=RESPONSE;end
                        else begin rank_q<=c_rank;search_index<=0;search_mass<=0;step<=FIRST_STEP;state<=SELECT_STEP;end
                    3:begin clear_index<=0;clear_response<=1;total<=0;state<=CLEAR;end
                endcase
            end
            LEAF_READ:state<=LEAF_CHECK;
            LEAF_CHECK:begin
                r_index<=leaf_index;r_sum<=leaf_q;
                subtract<=value_q<leaf_q;
                delta<=value_q<leaf_q?leaf_q-value_q:value_q-leaf_q;
                total<=value_q<leaf_q?total-(leaf_q-value_q):total+(value_q-leaf_q);
                state<=value_q==leaf_q?RESPONSE:UPDATE_READ;
            end
            UPDATE_READ:state<=UPDATE_CALC;
            UPDATE_CALC:begin tree_next<=subtract?tree_q-delta:tree_q+delta;state<=UPDATE_WRITE;end
            UPDATE_WRITE:if(next_update>BUCKETS)state<=RESPONSE;
                else begin walk<=next_update[NW-1:0];state<=UPDATE_READ;end
            PREFIX_READ:state<=PREFIX_ACCUM;
            PREFIX_ACCUM:begin prefix_acc<=prefix_acc+tree_q;walk<=walk-lowbit;state<=PREFIX_NEXT;end
            PREFIX_NEXT:if(walk!=0)state<=PREFIX_READ;
                else if(!left_phase)begin
                    right_sum<=prefix_acc;prefix_acc<=0;walk<=left_end;left_phase<=1;
                    state<=left_end==0?RANGE_FINISH:PREFIX_READ;
                end else state<=RANGE_FINISH;
            RANGE_FINISH:begin r_sum<=right_sum-prefix_acc;state<=RESPONSE;end
            SELECT_STEP:if(step==0)state<=SELECT_FINISH;
                else if(select_candidate>BUCKETS)step<=step>>1;
                else state<=SELECT_READ;
            SELECT_READ:state<=SELECT_CHECK;
            SELECT_CHECK:begin
                if(selected_mass<={1'b0,rank_q})begin
                    search_index<=select_candidate[NW-1:0];search_mass<=selected_mass[SW-1:0];
                end
                step<=step>>1;state<=SELECT_STEP;
            end
            SELECT_FINISH:begin r_index<=search_index[IW-1:0];r_sum<=search_mass;state<=RESPONSE;end
            RESPONSE:if(r_ready)state<=IDLE;
        endcase
    end
    generate if(BUCKETS<1 || BUCKETS>256 || COUNT_W<1 || COUNT_W>32 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        ram_fenwick_index_invalid_parameters__see_README rejected();
    end endgenerate
endmodule
