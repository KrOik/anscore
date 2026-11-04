// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module directed_dominators #(
    parameter integer NUM_NODES=16,TAG_W=8,
    localparam integer IW=NUM_NODES>1?$clog2(NUM_NODES):1,
    localparam integer CW=$clog2(NUM_NODES+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,s_root,
    input wire s_present,s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg m_keep,m_last,output reg [1:0] m_errors,output reg [TAG_W-1:0] m_tag,
    output reg [IW-1:0] m_node,m_root,m_idom,
    output reg m_reachable,m_idom_valid,
    output reg [CW-1:0] m_depth,m_dom_count,m_subtree_count,m_reached_count,
    output reg [NUM_NODES-1:0] m_dominators,m_dominated
);
    localparam integer N=NUM_NODES,SW=N+IW+2*CW;
    localparam [N-1:0] ONE={{(N-1){1'b0}},1'b1};
    localparam [4:0] CLEAR=0,CAPTURE=1,IN_READ=2,IN_WRITE=3,START=4,
        R_READ=5,R_CHECK=6,R_END=7,D_INIT=8,D_READ=9,D_PREP=10,
        P_READ=11,P_MERGE=12,D_WRITE=13,D_END=14,S_READ=15,S_PREP=16,
        S_SCAN_READ=17,S_SCAN_CHECK=18,S_WRITE=19,OUT_READ=20,OUT_LOAD=21,OUTPUT=22;
    reg [4:0] state;
    reg [N-1:0] predecessors[0:N-1],dominators[0:N-1];
    reg [SW-1:0] summaries[0:N-1];
    reg [N-1:0] pred_q,dom_q,old_dom,intersection,reachable,strict_set,dominated_set;
    reg [SW-1:0] summary_q;
    reg [IW-1:0] initialize_row,pending_from,pending_to,source_root,active_node,scan_node,candidate,output_node;
    reg pending_present,pending_last,first,changed;
    reg [1:0] errors;
    reg [TAG_W-1:0] tag;
    reg [CW-1:0] pass_count,reached_count,depth_count,dominated_count;
    reg [N-1:0] input_update;
    always @* begin input_update=pred_q;input_update[pending_from]=pending_present;end
    wire [N-1:0] new_dom=intersection|(ONE<<active_node);
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUTPUT;

    // Separate read/consume and read/write phases; no collision mode assumed.
    always @(posedge clk)if(!rst)begin
        if(state==CLEAR)predecessors[initialize_row]<=0;
        if(state==IN_READ)pred_q<=predecessors[pending_to];
        if(state==IN_WRITE)predecessors[pending_to]<=input_update;
        if(state==R_READ)pred_q<=predecessors[active_node];
        if(state==D_INIT)dominators[active_node]<=active_node==source_root?(ONE<<source_root):
            (reachable[active_node]?reachable:{N{1'b0}});
        if(state==D_READ)begin pred_q<=predecessors[active_node];dom_q<=dominators[active_node];end
        if(state==P_READ)dom_q<=dominators[scan_node];
        if(state==D_WRITE)dominators[active_node]<=new_dom;
        if(state==S_READ)dom_q<=dominators[active_node];
        if(state==S_SCAN_READ)dom_q<=dominators[scan_node];
        if(state==S_WRITE)summaries[active_node]<={dominated_set,candidate,depth_count,dominated_count};
        if(state==OUT_READ)begin dom_q<=dominators[output_node];summary_q<=summaries[output_node];end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;initialize_row<=0;first<=1;errors<=0;tag<=0;
            m_keep<=0;m_last<=0;m_errors<=0;m_tag<=0;m_node<=0;m_root<=0;m_idom<=0;
            m_reachable<=0;m_idom_valid<=0;m_depth<=0;m_dom_count<=0;m_subtree_count<=0;
            m_reached_count<=0;m_dominators<=0;m_dominated<=0;
        end else case(state)
            CLEAR:if(initialize_row==N-1)begin first<=1;errors<=0;state<=CAPTURE;end
                else initialize_row<=initialize_row+1'b1;
            CAPTURE:if(s_valid)begin
                if(first)begin
                    source_root<=s_root[IW-1:0];tag<=s_tag;first<=0;
                    if(s_root>=N)errors[1]<=1;
                end
                if(s_keep && (s_from>=N || s_to>=N))errors[0]<=1;
                if(s_keep && s_from<N && s_to<N)begin
                    pending_from<=s_from[IW-1:0];pending_to<=s_to[IW-1:0];
                    pending_present<=s_present;pending_last<=s_last;state<=IN_READ;
                end else if(s_last)state<=START;
            end
            IN_READ:state<=IN_WRITE;
            IN_WRITE:state<=pending_last?START:CAPTURE;
            START:if(errors!=0)begin
                m_keep<=0;m_last<=1;m_errors<=errors;m_tag<=tag;m_node<=0;m_root<=0;m_idom<=0;
                m_reachable<=0;m_idom_valid<=0;m_depth<=0;m_dom_count<=0;m_subtree_count<=0;
                m_reached_count<=0;m_dominators<=0;m_dominated<=0;state<=OUTPUT;
            end else begin
                reachable<=ONE<<source_root;reached_count<=1;pass_count<=1;changed<=0;active_node<=0;state<=R_READ;
            end
            R_READ:state<=R_CHECK;
            R_CHECK:begin
                if(!reachable[active_node] && |(pred_q&reachable))begin
                    reachable[active_node]<=1;reached_count<=reached_count+1'b1;changed<=1;
                end
                if(active_node==N-1)state<=R_END;
                else begin active_node<=active_node+1'b1;state<=R_READ;end
            end
            R_END:begin
                active_node<=0;
                if(changed)begin changed<=0;pass_count<=pass_count+1'b1;state<=R_READ;end
                else state<=D_INIT;
            end
            D_INIT:if(active_node==N-1)begin active_node<=0;changed<=0;pass_count<=1;state<=D_READ;end
                else active_node<=active_node+1'b1;
            D_READ:state<=D_PREP;
            D_PREP:if(active_node==source_root || !reachable[active_node])begin
                if(active_node==N-1)state<=D_END;
                else begin active_node<=active_node+1'b1;state<=D_READ;end
            end else begin old_dom<=dom_q;intersection<=reachable;scan_node<=0;state<=P_READ;end
            P_READ:state<=P_MERGE;
            P_MERGE:begin
                if(pred_q[scan_node] && reachable[scan_node])intersection<=intersection&dom_q;
                if(scan_node==N-1)state<=D_WRITE;
                else begin scan_node<=scan_node+1'b1;state<=P_READ;end
            end
            D_WRITE:begin
                if(new_dom!=old_dom)changed<=1;
                if(active_node==N-1)state<=D_END;
                else begin active_node<=active_node+1'b1;state<=D_READ;end
            end
            D_END:begin
                active_node<=0;
                if(changed)begin changed<=0;pass_count<=pass_count+1'b1;state<=D_READ;end
                else state<=S_READ;
            end
            S_READ:state<=S_PREP;
            S_PREP:begin
                strict_set<=dom_q&~(ONE<<active_node);candidate<=reachable[active_node]?source_root:{IW{1'b0}};
                dominated_set<=0;depth_count<=0;dominated_count<=0;scan_node<=0;state<=S_SCAN_READ;
            end
            S_SCAN_READ:state<=S_SCAN_CHECK;
            S_SCAN_CHECK:begin
                if(strict_set[scan_node])begin
                    depth_count<=depth_count+1'b1;
                    if(dom_q[candidate])candidate<=scan_node;
                end
                if(dom_q[active_node])begin dominated_set[scan_node]<=1;dominated_count<=dominated_count+1'b1;end
                if(scan_node==N-1)state<=S_WRITE;
                else begin scan_node<=scan_node+1'b1;state<=S_SCAN_READ;end
            end
            S_WRITE:if(active_node==N-1)begin output_node<=0;state<=OUT_READ;end
                else begin active_node<=active_node+1'b1;state<=S_READ;end
            OUT_READ:state<=OUT_LOAD;
            OUT_LOAD:begin
                m_keep<=1;m_last<=output_node==N-1;m_errors<=0;m_tag<=tag;m_node<=output_node;m_root<=source_root;
                m_reachable<=reachable[output_node];m_idom_valid<=reachable[output_node] && output_node!=source_root;
                m_idom<=reachable[output_node] && output_node!=source_root?summary_q[2*CW +:IW]:{IW{1'b0}};
                m_depth<=summary_q[CW +:CW];m_dom_count<=reachable[output_node]?(summary_q[CW +:CW]+1'b1):{CW{1'b0}};
                m_subtree_count<=summary_q[0 +:CW];m_reached_count<=reached_count;
                m_dominators<=dom_q;m_dominated<=summary_q[2*CW+IW +:N];state<=OUTPUT;
            end
            OUTPUT:if(m_ready)begin
                if(m_last)begin initialize_row<=0;state<=CLEAR;end
                else begin output_node<=output_node+1'b1;state<=OUT_READ;end
            end
            default:begin initialize_row<=0;state<=CLEAR;end
        endcase
    end
    generate if(NUM_NODES<1 || NUM_NODES>64 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        directed_dominators_invalid_parameters__see_README rejected();
    end endgenerate
endmodule
