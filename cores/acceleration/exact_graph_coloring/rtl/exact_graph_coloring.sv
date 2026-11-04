// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module exact_graph_coloring #(
    parameter integer NUM_NODES=8, TAG_W=8,
    localparam integer IW=(NUM_NODES>1)?$clog2(NUM_NODES):1,
    localparam integer CW=$clog2(NUM_NODES+1),
    localparam integer EW=NUM_NODES+CW+1,
    localparam integer DEPTH=1<<NUM_NODES
)(
    input wire clk,rst,s_valid, output wire s_ready,
    input wire [31:0] s_u,s_v,
    input wire s_present,s_keep,s_first,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [NUM_NODES*CW-1:0] m_colors,
    output reg [CW-1:0] m_count,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag
);
    generate if(NUM_NODES<1 || NUM_NODES>10 || TAG_W<1 || TAG_W>32) begin : g_invalid
        exact_graph_coloring_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    localparam [4:0] CLEAR=0,CAPTURE=1,UP_READ_A=2,UP_WRITE_A=3,
        UP_READ_B=4,UP_WRITE_B=5,START=6,BASE=7,PREP_READ=8,PREP_EVAL=9,
        CAND_READ=10,CAND_TEST=11,DP_READ=12,DP_EVAL=13,WRITE=14,
        ADVANCE=15,BACK_READ=16,BACK_APPLY=17,HOLD=18;
    reg [4:0] state;
    reg [NUM_NODES-1:0] adjacency[0:NUM_NODES-1];
    // Packed independent flag, minimum colour count and chosen colour class.
    reg [EW-1:0] table_mem[0:DEPTH-1];
    reg [NUM_NODES-1:0] row_q,subset,candidate,best_choice,remaining;
    reg [EW-1:0] table_q;
    reg [IW-1:0] cursor,u,v;
    reg [CW-1:0] best,color;
    reg present_q,last_q,started,independent_q;
    wire endpoint_bad=s_keep && (s_u>=NUM_NODES || s_v>=NUM_NODES);
    wire [1:0] incoming_errors=m_error | {(s_first!=(!started)),endpoint_bad};
    wire [NUM_NODES-1:0] predecessor=subset & (subset-1'b1);
    wire [NUM_NODES-1:0] anchor=subset ^ predecessor;
    wire [NUM_NODES-1:0] next_candidate=(candidate-1'b1) & subset;
    wire [CW-1:0] trial=table_q[NUM_NODES+:CW]+1'b1;
    reg [IW-1:0] lowest;
    reg found;
    integer j;
    always @* begin
        lowest=0;found=0;
        for(integer k=0;k<NUM_NODES;k=k+1)
            if(subset[k] && !found)begin lowest=IW'(k);found=1;end
    end
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;

    // At most one synchronous read and one write in each bank. Read and write
    // phases do not overlap, so no target-specific collision mode is needed.
    always @(posedge clk)begin
        if(!rst)begin
            if(state==CLEAR)adjacency[cursor]<=0;
            if(state==UP_READ_A)row_q<=adjacency[u];
            if(state==UP_READ_B)row_q<=adjacency[v];
            if(state==PREP_READ)row_q<=adjacency[lowest];
            if(state==UP_WRITE_A)begin
                if(present_q)adjacency[u]<=row_q | ({{(NUM_NODES-1){1'b0}},1'b1}<<v);
                else adjacency[u]<=row_q & ~({{(NUM_NODES-1){1'b0}},1'b1}<<v);
            end
            if(state==UP_WRITE_B)begin
                if(present_q)adjacency[v]<=row_q | ({{(NUM_NODES-1){1'b0}},1'b1}<<u);
                else adjacency[v]<=row_q & ~({{(NUM_NODES-1){1'b0}},1'b1}<<u);
            end
            if(state==BASE)table_mem[0]<={1'b1,{CW{1'b0}},{NUM_NODES{1'b0}}};
            if(state==PREP_READ)table_q<=table_mem[predecessor];
            if(state==CAND_READ)table_q<=table_mem[candidate];
            if(state==DP_READ)table_q<=table_mem[subset ^ candidate];
            if(state==WRITE)table_mem[subset]<={independent_q,best,best_choice};
            if(state==BACK_READ)table_q<=table_mem[remaining];
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;cursor<=0;u<=0;v<=0;subset<=0;candidate<=0;
            best_choice<=0;remaining<=0;best<=0;color<=0;
            present_q<=0;last_q<=0;started<=0;independent_q<=0;
            m_colors<=0;m_count<=0;m_error<=0;m_tag<=0;
        end else case(state)
            CLEAR:begin
                if(cursor==NUM_NODES-1)state<=CAPTURE;
                else cursor<=cursor+1'b1;
            end
            CAPTURE:if(s_valid)begin
                if(!started)begin started<=1;m_tag<=s_tag;end
                m_error<=incoming_errors;
                if(incoming_errors==0 && s_keep && s_u!=s_v)begin
                    u<=s_u[IW-1:0];v<=s_v[IW-1:0];present_q<=s_present;
                    last_q<=s_last;state<=UP_READ_A;
                end else if(s_last)state<=START;
            end
            UP_READ_A:state<=UP_WRITE_A;
            UP_WRITE_A:state<=UP_READ_B;
            UP_READ_B:state<=UP_WRITE_B;
            UP_WRITE_B:if(last_q)state<=START;else state<=CAPTURE;
            START:begin
                m_colors<=0;m_count<=0;
                if(m_error!=0)state<=HOLD;else state<=BASE;
            end
            BASE:begin subset<=1;state<=PREP_READ;end
            PREP_READ:state<=PREP_EVAL;
            PREP_EVAL:begin
                if(table_q[EW-1] && (row_q & predecessor)==0)begin
                    independent_q<=1;best<=1;best_choice<=subset;state<=WRITE;
                end else begin
                    independent_q<=0;best<=CW'(NUM_NODES);best_choice<=0;
                    candidate<=predecessor;state<=CAND_READ;
                end
            end
            CAND_READ:state<=CAND_TEST;
            CAND_TEST:begin
                if((candidate & anchor)!=0 && table_q[EW-1])state<=DP_READ;
                else if(next_candidate==0)state<=WRITE;
                else begin candidate<=next_candidate;state<=CAND_READ;end
            end
            DP_READ:state<=DP_EVAL;
            DP_EVAL:begin
                if(best_choice==0 || trial<best)begin best<=trial;best_choice<=candidate;end
                if(next_candidate==0)state<=WRITE;
                else begin candidate<=next_candidate;state<=CAND_READ;end
            end
            WRITE:state<=ADVANCE;
            ADVANCE:begin
                if(subset=={NUM_NODES{1'b1}})begin
                    m_count<=best;remaining<=subset;color<=0;state<=BACK_READ;
                end else begin subset<=subset+1'b1;state<=PREP_READ;end
            end
            BACK_READ:state<=BACK_APPLY;
            BACK_APPLY:begin
                for(j=0;j<NUM_NODES;j=j+1)
                    if(table_q[j])m_colors[j*CW+:CW]<=color;
                if((remaining ^ table_q[NUM_NODES-1:0])==0)state<=HOLD;
                else begin
                    remaining<=remaining ^ table_q[NUM_NODES-1:0];
                    color<=color+1'b1;state<=BACK_READ;
                end
            end
            HOLD:if(m_ready)begin
                state<=CLEAR;cursor<=0;started<=0;m_error<=0;m_tag<=0;
                m_colors<=0;m_count<=0;
            end
            default:begin state<=CLEAR;cursor<=0;started<=0;end
        endcase
    end
endmodule
