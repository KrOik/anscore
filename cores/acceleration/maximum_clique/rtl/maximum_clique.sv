// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module maximum_clique #(
    parameter integer NUM_NODES=8,TAG_W=8,
    localparam integer IW=(NUM_NODES>1)?$clog2(NUM_NODES):1,
    localparam integer CW=$clog2(NUM_NODES+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_u,s_v,
    input wire s_present,s_keep,s_first,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [NUM_NODES-1:0] m_vertices,
    output reg [CW-1:0] m_size,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag
);
    generate if(NUM_NODES<1 || NUM_NODES>16 || TAG_W<1 || TAG_W>32) begin : g_invalid
        maximum_clique_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    localparam [3:0] CLEAR=0,CAPTURE=1,UP_READ_A=2,UP_WRITE_A=3,
        UP_READ_B=4,UP_WRITE_B=5,START=6,SEARCH=7,ADJ_READ=8,
        DESCEND=9,POP_READ=10,POP_LOAD=11,HOLD=12;
    reg [3:0] state;
    reg [NUM_NODES-1:0] adjacency[0:NUM_NODES-1];
    // Each parent records its remaining candidates and its own clique mask.
    reg [2*NUM_NODES-1:0] stack[0:NUM_NODES-1];
    reg [NUM_NODES-1:0] row_q,candidates,clique;
    reg [2*NUM_NODES-1:0] stack_q;
    reg [IW-1:0] cursor,u,v;
    reg [CW-1:0] depth;
    reg present_q,last_q,started;
    wire endpoint_bad=s_keep && (s_u>=NUM_NODES || s_v>=NUM_NODES);
    wire [1:0] incoming_errors=m_error | {(s_first!=(!started)),endpoint_bad};
    reg [IW-1:0] first_candidate;
    reg [CW-1:0] population;
    reg found;
    integer k;
    always @* begin
        first_candidate=0;population=0;found=0;
        for(k=0;k<NUM_NODES;k=k+1)begin
            population=population+CW'(candidates[k]);
            if(candidates[k] && !found)begin first_candidate=IW'(k);found=1;end
        end
    end
    wire [NUM_NODES-1:0] choice_mask=({{(NUM_NODES-1){1'b0}},1'b1}<<first_candidate);
    wire [NUM_NODES-1:0] remaining=candidates & ~choice_mask;
    wire [CW:0] cardinality_bound={1'b0,depth}+{1'b0,population};
    wire [CW-1:0] extended_depth=depth+1'b1;
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;

    // Single synchronous read and write per bank, in disjoint phases.
    // Neither bank requires a parallel reset or read-during-write semantics.
    always @(posedge clk)begin
        if(!rst)begin
            if(state==CLEAR)adjacency[cursor]<=0;
            if(state==UP_READ_A || state==ADJ_READ)row_q<=adjacency[u];
            if(state==UP_READ_B)row_q<=adjacency[v];
            if(state==UP_WRITE_A)begin
                if(present_q)adjacency[u]<=row_q | ({{(NUM_NODES-1){1'b0}},1'b1}<<v);
                else adjacency[u]<=row_q & ~({{(NUM_NODES-1){1'b0}},1'b1}<<v);
            end
            if(state==UP_WRITE_B)begin
                if(present_q)adjacency[v]<=row_q | ({{(NUM_NODES-1){1'b0}},1'b1}<<u);
                else adjacency[v]<=row_q & ~({{(NUM_NODES-1){1'b0}},1'b1}<<u);
            end
            if(state==SEARCH && candidates!=0 && cardinality_bound>{1'b0,m_size})
                stack[depth]<={clique,remaining};
            if(state==POP_READ)stack_q<=stack[depth];
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;cursor<=0;u<=0;v<=0;depth<=0;
            present_q<=0;last_q<=0;started<=0;candidates<=0;clique<=0;
            m_vertices<=0;m_size<=0;m_error<=0;m_tag<=0;
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
                candidates<={NUM_NODES{1'b1}};clique<=0;depth<=0;
                m_vertices<=0;m_size<=0;
                if(m_error!=0)state<=HOLD;else state<=SEARCH;
            end
            SEARCH:begin
                if(candidates==0 || cardinality_bound<={1'b0,m_size})begin
                    if(depth==0)state<=HOLD;
                    else begin depth<=depth-1'b1;state<=POP_READ;end
                end else begin
                    u<=first_candidate;candidates<=remaining;
                    clique<=clique | choice_mask;depth<=extended_depth;
                    if(extended_depth>m_size)begin
                        m_size<=extended_depth;m_vertices<=clique | choice_mask;
                    end
                    state<=ADJ_READ;
                end
            end
            ADJ_READ:state<=DESCEND;
            DESCEND:begin candidates<=candidates & row_q;state<=SEARCH;end
            POP_READ:state<=POP_LOAD;
            POP_LOAD:begin
                candidates<=stack_q[NUM_NODES-1:0];clique<=stack_q[NUM_NODES+:NUM_NODES];
                state<=SEARCH;
            end
            HOLD:if(m_ready)begin
                state<=CLEAR;cursor<=0;started<=0;m_error<=0;
                m_vertices<=0;m_size<=0;m_tag<=0;
            end
            default:begin state<=CLEAR;cursor<=0;started<=0;end
        endcase
    end
endmodule
