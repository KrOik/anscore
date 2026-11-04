// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module signed_sssp #(
    parameter integer NUM_NODES=8, WEIGHT_W=8, TAG_W=8,
    localparam integer NODE_W=(NUM_NODES>1)?$clog2(NUM_NODES):1,
    localparam integer COUNT_W=(NUM_NODES>0)?$clog2(NUM_NODES+1):1,
    localparam integer DIST_W=WEIGHT_W+((NUM_NODES>1)?$clog2(NUM_NODES):0)+1
)(
    input wire clk,rst,s_valid, output wire s_ready,
    input wire [31:0] s_from,s_to,s_source,
    input wire signed [WEIGHT_W-1:0] s_weight,
    input wire s_present,s_keep,s_first,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg [NODE_W-1:0] m_vertex,m_source,
    output reg signed [DIST_W-1:0] m_distance,
    output reg m_reachable,m_negative_infinite,m_has_negative_cycle,
    output reg m_keep,m_first,m_last,
    output reg [TAG_W-1:0] m_tag, output reg [2:0] m_errors
);
    generate if(NUM_NODES<1 || NUM_NODES>32 || WEIGHT_W<1 || WEIGHT_W>16 ||
                TAG_W<1 || TAG_W>32)begin:bad_parameters
        signed_sssp_invalid_parameters__see_README invalid();
    end endgenerate
    localparam integer AW=(NUM_NODES*NUM_NODES>1)?$clog2(NUM_NODES*NUM_NODES):1;
    localparam [3:0] CLEAR=0,CAPTURE=1,INIT_D=2,V_READ=3,V_INIT=4,
        E_READ=5,RELAX=6,V_WRITE=7,PASS_END=8,P_READ=9,P_STEP=10,
        P_END=11,O_READ=12,O_LOAD=13,HOLD=14,ERROR_LOAD=15;
    reg [3:0] state;
    reg [WEIGHT_W:0] adjacency[0:NUM_NODES*NUM_NODES-1],edge_q;
    reg [DIST_W:0] distance0[0:NUM_NODES-1],distance1[0:NUM_NODES-1];
    reg [DIST_W:0] distance_q,old_q,best_q;
    reg bank,changed,flag_changed,frame_open;
    reg [NODE_W-1:0] source,node_u,node_v,init_node,out_node;
    reg [AW-1:0] clear_address;
    reg [COUNT_W-1:0] pass,prop_pass;
    reg [NUM_NODES-1:0] negative;
    reg [TAG_W-1:0] tag;
    reg [2:0] errors;
    wire endpoints_ok=s_from<NUM_NODES && s_to<NUM_NODES;
    wire [2:0] offered_errors=errors |
        ((!frame_open && s_source>=NUM_NODES)?3'b001:3'b000) |
        ((s_keep && !endpoints_ok)?3'b010:3'b000) |
        ((s_first!=!frame_open)?3'b100:3'b000);
    wire signed [DIST_W:0] candidate=
        $signed({distance_q[DIST_W-1],distance_q[DIST_W-1:0]})+
        $signed({{(DIST_W+1-WEIGHT_W){edge_q[WEIGHT_W-1]}},edge_q[WEIGHT_W-1:0]});
    wire improved=best_q[DIST_W] && (!old_q[DIST_W] ||
        $signed(best_q[DIST_W-1:0])<$signed(old_q[DIST_W-1:0]));
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;clear_address<=0;bank<=0;changed<=0;
            flag_changed<=0;frame_open<=0;source<=0;node_u<=0;node_v<=0;
            init_node<=0;out_node<=0;pass<=0;prop_pass<=0;negative<=0;
            tag<=0;errors<=0;edge_q<=0;distance_q<=0;old_q<=0;best_q<=0;
            m_vertex<=0;m_source<=0;m_distance<=0;m_reachable<=0;
            m_negative_infinite<=0;m_has_negative_cycle<=0;
            m_keep<=0;m_first<=0;m_last<=0;m_tag<=0;m_errors<=0;
        end else case(state)
            CLEAR:begin
                adjacency[clear_address]<=0;
                if(clear_address==NUM_NODES*NUM_NODES-1)begin
                    state<=CAPTURE;frame_open<=0;source<=0;errors<=0;
                    tag<=0;negative<=0;
                end else clear_address<=clear_address+1'b1;
            end
            CAPTURE:if(s_valid)begin
                if(!frame_open)begin source<=s_source[NODE_W-1:0];tag<=s_tag;end
                frame_open<=1;errors<=offered_errors;
                // Direct assignment, including deletion; full IDs checked first.
                if(s_keep && endpoints_ok && offered_errors==0)
                    adjacency[s_from[NODE_W-1:0]*NUM_NODES+s_to[NODE_W-1:0]]<={s_present,s_weight};
                if(s_last)begin
                    if(offered_errors!=0)state<=ERROR_LOAD;
                    else begin init_node<=0;bank<=0;state<=INIT_D;end
                end
            end
            INIT_D:begin
                distance0[init_node]<={(init_node==source),{DIST_W{1'b0}}};
                distance1[init_node]<=0;
                if(init_node==NUM_NODES-1)begin
                    pass<=1;node_v<=0;changed<=0;state<=V_READ;
                end else init_node<=init_node+1'b1;
            end
            V_READ:begin
                if(bank)distance_q<=distance1[node_v];else distance_q<=distance0[node_v];
                state<=V_INIT;
            end
            V_INIT:begin old_q<=distance_q;best_q<=distance_q;node_u<=0;state<=E_READ;end
            E_READ:begin
                edge_q<=adjacency[node_u*NUM_NODES+node_v];
                if(bank)distance_q<=distance1[node_u];else distance_q<=distance0[node_u];
                state<=RELAX;
            end
            RELAX:begin
                if(edge_q[WEIGHT_W] && distance_q[DIST_W] &&
                    (!best_q[DIST_W] || candidate<$signed({best_q[DIST_W-1],best_q[DIST_W-1:0]})))
                    best_q<={1'b1,candidate[DIST_W-1:0]};
                if(node_u==NUM_NODES-1)state<=V_WRITE;
                else begin node_u<=node_u+1'b1;state<=E_READ;end
            end
            V_WRITE:begin
                if(bank)distance0[node_v]<=best_q;else distance1[node_v]<=best_q;
                if(improved)begin
                    changed<=1;
                    if(pass==NUM_NODES)negative[node_v]<=1;
                end
                if(node_v==NUM_NODES-1)state<=PASS_END;
                else begin node_v<=node_v+1'b1;state<=V_READ;end
            end
            PASS_END:begin
                out_node<=0;
                if(!changed)state<=O_READ; // A fixed point has no reachable negative cycle.
                else if(pass==NUM_NODES)begin
                    // Keep D_(N-1) for unaffected finite distances; D_N only seeds.
                    node_u<=0;node_v<=0;prop_pass<=1;flag_changed<=0;
                    if(NUM_NODES==1 || &negative)state<=O_READ;else state<=P_READ;
                end else begin
                    bank<=!bank;pass<=pass+1'b1;node_v<=0;changed<=0;state<=V_READ;
                end
            end
            P_READ:begin edge_q<=adjacency[node_u*NUM_NODES+node_v];state<=P_STEP;end
            P_STEP:begin
                if(edge_q[WEIGHT_W] && negative[node_u] && !negative[node_v])begin
                    negative[node_v]<=1;flag_changed<=1;
                end
                if(node_u==NUM_NODES-1)begin
                    if(node_v==NUM_NODES-1)state<=P_END;
                    else begin node_v<=node_v+1'b1;node_u<=0;state<=P_READ;end
                end else begin node_u<=node_u+1'b1;state<=P_READ;end
            end
            P_END:begin
                if(!flag_changed || prop_pass==NUM_NODES-1)state<=O_READ;
                else begin
                    prop_pass<=prop_pass+1'b1;flag_changed<=0;
                    node_u<=0;node_v<=0;state<=P_READ;
                end
            end
            O_READ:begin
                if(bank)distance_q<=distance1[out_node];else distance_q<=distance0[out_node];
                state<=O_LOAD;
            end
            O_LOAD:begin
                m_vertex<=out_node;m_source<=source;
                m_reachable<=distance_q[DIST_W];m_negative_infinite<=negative[out_node];
                m_has_negative_cycle<=|negative;
                m_distance<=(distance_q[DIST_W] && !negative[out_node])?distance_q[DIST_W-1:0]:{DIST_W{1'b0}};
                m_keep<=1;m_first<=(out_node==0);m_last<=(out_node==NUM_NODES-1);
                m_tag<=tag;m_errors<=0;state<=HOLD;
            end
            ERROR_LOAD:begin
                m_vertex<=0;m_source<=0;m_distance<=0;m_reachable<=0;
                m_negative_infinite<=0;m_has_negative_cycle<=0;
                m_keep<=0;m_first<=1;m_last<=1;m_tag<=tag;m_errors<=errors;state<=HOLD;
            end
            HOLD:if(m_ready)begin
                if(m_last)begin clear_address<=0;state<=CLEAR;end
                else begin out_node<=out_node+1'b1;state<=O_READ;end
            end
            default:begin clear_address<=0;state<=CLEAR;end
        endcase
    end
endmodule
