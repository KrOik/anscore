// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Serial successive shortest residual paths; all original prices are unsigned.
module min_cost_flow #(
    parameter integer NUM_NODES=8, MAX_EDGES=16,
    parameter integer CAP_W=8, COST_W=8, TAG_W=8,
    parameter integer V=(NUM_NODES<=2)?1:$clog2(NUM_NODES),
    parameter integer EI=(MAX_EDGES<=2)?1:$clog2(MAX_EDGES),
    parameter integer FW=CAP_W+$clog2(MAX_EDGES),
    parameter integer TW=CAP_W+COST_W+$clog2(MAX_EDGES)
)(
    input wire clk, rst,
    input wire c_valid, output wire c_ready,
    input wire [31:0] c_source,c_sink,c_limit,
    input wire [TAG_W-1:0] c_tag,
    input wire s_valid, output wire s_ready,
    input wire [31:0] s_from,s_to,
    input wire [CAP_W-1:0] s_capacity,
    input wire [COST_W-1:0] s_cost,
    input wire s_keep,s_last,s_error,
    output reg m_valid, input wire m_ready,
    output reg m_keep,m_last,
    output reg [EI-1:0] m_index,
    output reg [CAP_W-1:0] m_edge_flow,
    output wire [FW-1:0] m_total_flow,
    output wire [TW-1:0] m_total_cost,
    output wire m_target_met,
    output wire [5:0] m_error,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer EC=$clog2(MAX_EDGES+1), NC=$clog2(NUM_NODES+1);
    localparam integer DW=COST_W+$clog2((NUM_NODES-1)*2*MAX_EDGES+2)+1;
    localparam integer EB=2*V+2*CAP_W+COST_W, NB=DW+EI+2, PB=EI+1;
    localparam [5:0] IDLE=0,LOAD=1,CHECK=2,INIT=3,EDGE_READ=4,EDGE_USE=5,
        SRC_READ=6,SRC_USE=7,DST_READ=8,DST_USE=9,RELAX_WRITE=10,NEXT_ARC=11,
        PASS_DONE=12,SINK_READ=13,SINK_USE=14,TRACE_INIT=15,NODE_READ=16,
        NODE_USE=17,TRACE_EDGE_READ=18,TRACE_EDGE_USE=19,PATH_WRITE=20,
        TRACE_NEXT=21,UPDATE_INIT=22,PATH_READ=23,PATH_USE=24,
        UPDATE_EDGE_READ=25,UPDATE_EDGE_USE=26,UPDATE_WRITE=27,UPDATE_NEXT=28,
        AUGMENT_DONE=29,SUM_INIT=30,SUM_READ=31,SUM_PRODUCT=32,SUM_ADD=33,
        OUT_READ=34,OUT_USE=35,HOLD=36;
    reg [EB-1:0] edge_ram[0:MAX_EDGES-1];
    reg [NB-1:0] node_ram[0:NUM_NODES-1];
    reg [PB-1:0] path_ram[0:NUM_NODES-2];
    reg [EB-1:0] edge_q;
    reg [NB-1:0] node_q;
    reg [PB-1:0] path_q;
    reg [5:0] state;
    reg [V-1:0] source,sink,init_node,arc_u,arc_v,trace_node,next_node;
    reg [EI-1:0] edge_index,trace_edge;
    reg [EC-1:0] edge_count;
    reg [NC-1:0] path_count,path_index;
    reg [V-1:0] pass_index;
    reg reverse_arc,trace_reverse,update_reverse,changed;
    reg [CAP_W-1:0] residual_capacity,bottleneck,updated_flow;
    reg signed [DW-1:0] arc_cost,source_distance,candidate_distance;
    reg [FW-1:0] total_flow;
    reg [TW-1:0] total_cost;
    reg [CAP_W+COST_W-1:0] product_q;
    reg [31:0] limit_q;
    reg [TAG_W-1:0] tag_q;
    reg [5:0] error_q;
    wire [CAP_W-1:0] eq_flow=edge_q[CAP_W-1:0];
    wire [COST_W-1:0] eq_cost=edge_q[CAP_W+:COST_W];
    wire [CAP_W-1:0] eq_cap=edge_q[CAP_W+COST_W+:CAP_W];
    wire [V-1:0] eq_to=edge_q[2*CAP_W+COST_W+:V];
    wire [V-1:0] eq_from=edge_q[2*CAP_W+COST_W+V+:V];
    wire nq_reach=node_q[NB-1];
    wire signed [DW-1:0] nq_dist=$signed(node_q[EI+1+:DW]);
    wire [EI-1:0] nq_parent=node_q[1+:EI];
    wire nq_reverse=node_q[0];
    wire signed [DW-1:0] cost_extended=$signed({{(DW-COST_W){1'b0}},eq_cost});
    wire [31:0] remaining=limit_q-{{(32-FW){1'b0}},total_flow};
    wire [31:0] cap_extended={{(32-CAP_W){1'b0}},{CAP_W{1'b1}}};
    assign c_ready=!rst && state==IDLE;
    assign s_ready=!rst && state==LOAD;
    assign m_total_flow=total_flow;
    assign m_total_cost=total_cost;
    assign m_target_met=(error_q==0 && {{(32-FW){1'b0}},total_flow}==limit_q);
    assign m_error=error_q;
    assign m_tag=tag_q;
    generate if(NUM_NODES<2 || NUM_NODES>16 || MAX_EDGES<1 || MAX_EDGES>32 ||
                CAP_W<1 || CAP_W>8 || COST_W<1 || COST_W>8 || TAG_W<1 || TAG_W>32 ||
                V!=((NUM_NODES<=2)?1:$clog2(NUM_NODES)) ||
                EI!=((MAX_EDGES<=2)?1:$clog2(MAX_EDGES)) ||
                FW!=CAP_W+$clog2(MAX_EDGES) || TW!=CAP_W+COST_W+$clog2(MAX_EDGES)) begin:bad
        min_cost_flow_illegal_parameters invalid_parameter();
    end endgenerate
    // Each bank has one scheduled synchronous access per cycle. No payload reset.
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; m_valid<=0; m_keep<=0; m_last<=0;m_index<=0;m_edge_flow<=0;
            edge_count<=0; total_flow<=0;total_cost<=0;error_q<=0;tag_q<=0;limit_q<=0;
        end else begin
            case(state)
            IDLE: if(c_valid) begin
                source<=c_source[V-1:0];sink<=c_sink[V-1:0];limit_q<=c_limit;tag_q<=c_tag;
                error_q<={4'b0,(c_source==c_sink),(c_source>=NUM_NODES || c_sink>=NUM_NODES)};
                edge_count<=0;total_flow<=0;total_cost<=0;state<=LOAD;
                m_valid<=0;m_keep<=0;m_last<=0;m_index<=0;m_edge_flow<=0;
            end
            LOAD: if(s_valid) begin
                if(s_error) error_q[4]<=1;
                if(s_keep) begin
                    if(s_from>=NUM_NODES || s_to>=NUM_NODES) error_q[2]<=1;
                    if(edge_count==MAX_EDGES) error_q[3]<=1;
                    else begin
                        edge_ram[edge_count]<= {s_from[V-1:0],s_to[V-1:0],s_capacity,s_cost,{CAP_W{1'b0}}};
                        edge_count<=edge_count+1'b1;
                    end
                end
                if(s_last) state<=CHECK;
            end
            CHECK: begin
                if(error_q!=0) begin
                    m_valid<=1;m_keep<=0;m_last<=1;m_index<=0;m_edge_flow<=0;state<=HOLD;
                end else if(limit_q==0 || edge_count==0) state<=SUM_INIT;
                else begin init_node<=0;state<=INIT;end
            end
            INIT: begin
                node_ram[init_node]<={(init_node==source),{DW{1'b0}},{EI{1'b0}},1'b0};
                if(init_node==NUM_NODES-1) begin
                    edge_index<=0;reverse_arc<=0;pass_index<=0;changed<=0;state<=EDGE_READ;
                end else init_node<=init_node+1'b1;
            end
            EDGE_READ: begin edge_q<=edge_ram[edge_index];state<=EDGE_USE;end
            EDGE_USE: begin
                arc_u<=reverse_arc?eq_to:eq_from;arc_v<=reverse_arc?eq_from:eq_to;
                residual_capacity<=reverse_arc?eq_flow:(eq_cap-eq_flow);
                arc_cost<=reverse_arc?-cost_extended:cost_extended;state<=SRC_READ;
            end
            SRC_READ: begin node_q<=node_ram[arc_u];state<=SRC_USE;end
            SRC_USE: begin
                if(nq_reach && residual_capacity!=0) begin
                    source_distance<=nq_dist;state<=DST_READ;
                end else state<=NEXT_ARC;
            end
            DST_READ: begin node_q<=node_ram[arc_v];state<=DST_USE;end
            DST_USE: begin
                if(!nq_reach || source_distance+arc_cost<nq_dist) begin
                    candidate_distance<=source_distance+arc_cost;state<=RELAX_WRITE;
                end else state<=NEXT_ARC;
            end
            RELAX_WRITE: begin
                node_ram[arc_v]<={1'b1,candidate_distance,edge_index,reverse_arc};
                changed<=1;state<=NEXT_ARC;
            end
            NEXT_ARC: begin
                if(!reverse_arc) begin reverse_arc<=1;state<=EDGE_READ;end
                else if(edge_index+1'b1==edge_count) state<=PASS_DONE;
                else begin edge_index<=edge_index+1'b1;reverse_arc<=0;state<=EDGE_READ;end
            end
            PASS_DONE: begin
                if(changed && pass_index<NUM_NODES-2) begin
                    pass_index<=pass_index+1'b1;edge_index<=0;reverse_arc<=0;changed<=0;state<=EDGE_READ;
                end else state<=SINK_READ;
            end
            SINK_READ: begin node_q<=node_ram[sink];state<=SINK_USE;end
            SINK_USE: if(nq_reach) state<=TRACE_INIT; else state<=SUM_INIT;
            TRACE_INIT: begin
                trace_node<=sink;path_count<=0;
                bottleneck<=remaining>cap_extended?{CAP_W{1'b1}}:remaining[CAP_W-1:0];state<=NODE_READ;
            end
            NODE_READ: begin node_q<=node_ram[trace_node];state<=NODE_USE;end
            NODE_USE: begin
                if(!nq_reach || path_count>=NUM_NODES-1 || nq_parent>=edge_count) begin
                    error_q[5]<=1;total_flow<=0;total_cost<=0;
                    m_valid<=1;m_keep<=0;m_last<=1;m_index<=0;m_edge_flow<=0;state<=HOLD;
                end else begin trace_edge<=nq_parent;trace_reverse<=nq_reverse;state<=TRACE_EDGE_READ;end
            end
            TRACE_EDGE_READ: begin edge_q<=edge_ram[trace_edge];state<=TRACE_EDGE_USE;end
            TRACE_EDGE_USE: begin
                next_node<=trace_reverse?eq_to:eq_from;
                if((trace_reverse?eq_flow:(eq_cap-eq_flow))<bottleneck)
                    bottleneck<=trace_reverse?eq_flow:(eq_cap-eq_flow);
                state<=PATH_WRITE;
            end
            PATH_WRITE: begin path_ram[path_count]<={trace_edge,trace_reverse};path_count<=path_count+1'b1;state<=TRACE_NEXT;end
            TRACE_NEXT: if(next_node==source) state<=UPDATE_INIT;
                else begin trace_node<=next_node;state<=NODE_READ;end
            UPDATE_INIT: begin
                path_index<=0;
                if(bottleneck==0) begin
                    error_q[5]<=1;total_flow<=0;total_cost<=0;
                    m_valid<=1;m_keep<=0;m_last<=1;m_index<=0;m_edge_flow<=0;state<=HOLD;
                end else state<=PATH_READ;
            end
            PATH_READ: begin path_q<=path_ram[path_index];state<=PATH_USE;end
            PATH_USE: begin edge_index<=path_q[1+:EI];update_reverse<=path_q[0];state<=UPDATE_EDGE_READ;end
            UPDATE_EDGE_READ: begin edge_q<=edge_ram[edge_index];state<=UPDATE_EDGE_USE;end
            UPDATE_EDGE_USE: begin updated_flow<=update_reverse?eq_flow-bottleneck:eq_flow+bottleneck;state<=UPDATE_WRITE;end
            UPDATE_WRITE: begin edge_ram[edge_index]<={edge_q[EB-1:CAP_W],updated_flow};state<=UPDATE_NEXT;end
            UPDATE_NEXT: if(path_index+1'b1==path_count) state<=AUGMENT_DONE;
                else begin path_index<=path_index+1'b1;state<=PATH_READ;end
            AUGMENT_DONE: begin
                total_flow<=total_flow+{{(FW-CAP_W){1'b0}},bottleneck};
                if({{(32-FW){1'b0}},total_flow}+{{(32-CAP_W){1'b0}},bottleneck}==limit_q) state<=SUM_INIT;
                else begin init_node<=0;state<=INIT;end
            end
            SUM_INIT: begin
                edge_index<=0;total_cost<=0;
                if(edge_count==0) begin
                    m_valid<=1;m_keep<=0;m_last<=1;m_index<=0;m_edge_flow<=0;state<=HOLD;
                end else state<=SUM_READ;
            end
            SUM_READ: begin edge_q<=edge_ram[edge_index];state<=SUM_PRODUCT;end
            SUM_PRODUCT: begin product_q<=eq_flow*eq_cost;state<=SUM_ADD;end
            SUM_ADD: begin
                total_cost<=total_cost+{{(TW-CAP_W-COST_W){1'b0}},product_q};
                if(edge_index+1'b1==edge_count) begin edge_index<=0;state<=OUT_READ;end
                else begin edge_index<=edge_index+1'b1;state<=SUM_READ;end
            end
            OUT_READ: begin edge_q<=edge_ram[edge_index];state<=OUT_USE;end
            OUT_USE: begin
                m_valid<=1;m_keep<=1;m_last<=(edge_index+1'b1==edge_count);
                m_index<=edge_index;m_edge_flow<=eq_flow;state<=HOLD;
            end
            HOLD: if(m_valid && m_ready) begin
                m_valid<=0;
                if(m_last) state<=IDLE;
                else begin edge_index<=edge_index+1'b1;state<=OUT_READ;end
            end
            default: state<=IDLE;
            endcase
        end
    end
endmodule
