`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Integer directed maximum flow with a residual-reachability minimum cut.
module maxflow_mincut #(
    parameter integer NUM_NODES=8,CAP_W=16,TAG_W=8,
    localparam integer NODE_W=(NUM_NODES>2)?$clog2(NUM_NODES):1,
    localparam integer QUEUE_W=(NUM_NODES>1)?$clog2(NUM_NODES+1):1,
    localparam integer MATRIX_W=(NUM_NODES>1)?$clog2(NUM_NODES*NUM_NODES):1,
    localparam integer FLOW_W=CAP_W+((NUM_NODES>1)?$clog2(NUM_NODES):0)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,s_source,s_sink,
    input wire [CAP_W-1:0] s_capacity,
    input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_keep,m_first,m_last,
    output wire [NODE_W-1:0] m_from,m_to,
    output wire [CAP_W-1:0] m_capacity,m_flow,
    output reg [FLOW_W-1:0] m_total_flow,
    output reg [NUM_NODES-1:0] m_cut,
    output wire [2:0] m_error,
    output reg [31:0] m_source,m_sink,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer RES_W=CAP_W+1,RECORD_W=2*CAP_W+1;
    localparam [3:0] CLEAR=0,COLLECT=1,BFS_INIT=2,BFS_POP=3,EDGE_READ=4,
        EDGE_CHECK=5,AUG_PARENT=6,AUG_FWD_READ=7,AUG_FWD_WRITE=8,
        AUG_REV_READ=9,AUG_REV_WRITE=10,OUTPUT_READ=11,OUTPUT_HOLD=12,STATUS_HOLD=13;
    reg [3:0] state;
    // The upper field is immutable capacity; lower is unsigned residual.
    reg [RECORD_W-1:0] graph[0:NUM_NODES*NUM_NODES-1];
    reg [RECORD_W-1:0] edge_q,output_q;
    reg [NODE_W-1:0] queue[0:NUM_NODES-1],parent[0:NUM_NODES-1];
    reg [RES_W-1:0] bottleneck[0:NUM_NODES-1];
    reg [QUEUE_W-1:0] head,tail;
    reg [NUM_NODES-1:0] seen;
    reg [NODE_W-1:0] vertex,neighbor,cursor,previous,out_from,out_to;
    reg [MATRIX_W-1:0] clear_index;
    reg [RES_W-1:0] delta;
    reg [2:0] errors;
    reg started;
    wire [RES_W-1:0] residual=edge_q[RES_W-1:0];
    wire [RES_W-1:0] path_limit=(residual<bottleneck[vertex])?residual:bottleneck[vertex];
    wire [RES_W-1:0] output_capacity={1'b0,output_q[RES_W+:CAP_W]};
    wire [RES_W-1:0] positive_flow=output_capacity-output_q[RES_W-1:0];
    wire [2:0] incoming_errors=errors |
        {(!started && s_source==s_sink),
         (!started && (s_source>=NUM_NODES || s_sink>=NUM_NODES)),
         (s_keep && (s_from>=NUM_NODES || s_to>=NUM_NODES))};
    function [MATRIX_W-1:0] address(input [NODE_W-1:0] a,b);
        address=a*NUM_NODES+b;
    endfunction
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && (state==OUTPUT_HOLD || state==STATUS_HOLD);
    assign m_keep=state==OUTPUT_HOLD;
    assign m_from=m_keep?out_from:{NODE_W{1'b0}};
    assign m_to=m_keep?out_to:{NODE_W{1'b0}};
    assign m_capacity=m_keep?output_q[RES_W+:CAP_W]:{CAP_W{1'b0}};
    assign m_flow=(m_keep && output_capacity>output_q[RES_W-1:0])?
        positive_flow[CAP_W-1:0]:{CAP_W{1'b0}};
    assign m_first=!m_keep || (out_from==0 && out_to==0);
    assign m_last=!m_keep || (out_from==NUM_NODES-1 && out_to==NUM_NODES-1);
    assign m_error=errors;
    generate if(NUM_NODES<2 || NUM_NODES>32 || CAP_W<1 || CAP_W>24 || TAG_W<1 || TAG_W>32)
        begin : g_invalid
            maxflow_mincut_invalid_parameters__see_README invalid_configuration();
        end
    endgenerate
    task next_neighbor;
        begin
            if(neighbor==NUM_NODES-1) begin head<=head+1'b1;state<=BFS_POP;end
            else begin neighbor<=neighbor+1'b1;state<=EDGE_READ;end
        end
    endtask
    task retire_graph;
        begin
            state<=CLEAR;clear_index<=0;started<=0;errors<=0;
            m_total_flow<=0;m_cut<=0;m_source<=0;m_sink<=0;m_tag<=0;
        end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=CLEAR;clear_index<=0;started<=0;errors<=0;head<=0;tail<=0;seen<=0;
            vertex<=0;neighbor<=0;cursor<=0;previous<=0;out_from<=0;out_to<=0;delta<=0;
            edge_q<=0;output_q<=0;m_total_flow<=0;m_cut<=0;m_source<=0;m_sink<=0;m_tag<=0;
        end else case(state)
            CLEAR: begin
                graph[clear_index]<=0;
                if(clear_index==NUM_NODES*NUM_NODES-1) state<=COLLECT;
                else clear_index<=clear_index+1'b1;
            end
            COLLECT: if(s_valid) begin
                if(!started) begin started<=1;m_source<=s_source;m_sink<=s_sink;m_tag<=s_tag;end
                errors<=incoming_errors;
                if(s_keep && s_from<NUM_NODES && s_to<NUM_NODES)
                    graph[address(s_from[NODE_W-1:0],s_to[NODE_W-1:0])]<={s_capacity,1'b0,s_capacity};
                if(s_last) begin
                    if(incoming_errors!=0) state<=STATUS_HOLD;
                    else state<=BFS_INIT;
                end
            end
            BFS_INIT: begin
                seen<=({{(NUM_NODES-1){1'b0}},1'b1}<<m_source);
                queue[0]<=m_source[NODE_W-1:0];head<=0;tail<=1;
                bottleneck[m_source[NODE_W-1:0]]<={RES_W{1'b1}};state<=BFS_POP;
            end
            BFS_POP: begin
                if(head==tail) begin m_cut<=seen;out_from<=0;out_to<=0;state<=OUTPUT_READ;end
                else begin vertex<=queue[head];neighbor<=0;state<=EDGE_READ;end
            end
            EDGE_READ: begin edge_q<=graph[address(vertex,neighbor)];state<=EDGE_CHECK;end
            EDGE_CHECK: begin
                if(!seen[neighbor] && residual!=0) begin
                    seen[neighbor]<=1;parent[neighbor]<=vertex;bottleneck[neighbor]<=path_limit;
                    if(neighbor==m_sink) begin delta<=path_limit;cursor<=neighbor;state<=AUG_PARENT;end
                    else begin queue[tail]<=neighbor;tail<=tail+1'b1;next_neighbor();end
                end else next_neighbor();
            end
            AUG_PARENT: begin previous<=parent[cursor];state<=AUG_FWD_READ;end
            AUG_FWD_READ: begin edge_q<=graph[address(previous,cursor)];state<=AUG_FWD_WRITE;end
            AUG_FWD_WRITE: begin
                graph[address(previous,cursor)]<={edge_q[RES_W+:CAP_W],(residual-delta)};
                state<=AUG_REV_READ;
            end
            AUG_REV_READ: begin edge_q<=graph[address(cursor,previous)];state<=AUG_REV_WRITE;end
            AUG_REV_WRITE: begin
                graph[address(cursor,previous)]<={edge_q[RES_W+:CAP_W],(residual+delta)};
                if(previous==m_source) begin m_total_flow<=m_total_flow+delta;state<=BFS_INIT;end
                else begin cursor<=previous;state<=AUG_PARENT;end
            end
            OUTPUT_READ: begin output_q<=graph[address(out_from,out_to)];state<=OUTPUT_HOLD;end
            OUTPUT_HOLD: if(m_ready) begin
                if(out_from==NUM_NODES-1 && out_to==NUM_NODES-1) retire_graph();
                else begin
                    if(out_to==NUM_NODES-1) begin out_to<=0;out_from<=out_from+1'b1;end
                    else out_to<=out_to+1'b1;
                    state<=OUTPUT_READ;
                end
            end
            STATUS_HOLD: if(m_ready) retire_graph();
            default: state<=CLEAR;
        endcase
    end
endmodule
