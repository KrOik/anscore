`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Bounded directed nonnegative graph -> exact distances and a shortest-path tree.
module dijkstra_sssp #(
    parameter integer NUM_NODES=16,
    parameter integer WEIGHT_W=16,
    parameter integer TAG_W=8,
    localparam integer NODE_W=(NUM_NODES>1)?$clog2(NUM_NODES):1,
    localparam integer DIST_W=WEIGHT_W+NODE_W
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,s_source,
    input wire [WEIGHT_W-1:0] s_weight,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [NODE_W-1:0] m_vertex,m_parent,
    output wire [DIST_W-1:0] m_distance,
    output wire m_reachable,m_parent_valid,m_first,m_last,
    output reg [31:0] m_source,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer EDGES=NUM_NODES*NUM_NODES;
    localparam integer ADDR_W=(EDGES>1)?$clog2(EDGES):1;
    localparam integer STATE_W=DIST_W+NODE_W+3;
    localparam [3:0] CLEAR_EDGES=0,CAPTURE=1,EDGE_STORE=2,INIT_NODES=3,
        SELECT_READ=4,SELECT_COMPARE=5,SELECT_COMMIT=6,
        RELAX_READ=7,RELAX_COMPARE=8,OUTPUT_READ=9,OUTPUT_HOLD=10;
    reg [3:0] state;
    // Packed edge {present, weight}; zero weight is a real edge.
    reg [WEIGHT_W:0] edges[0:EDGES-1];
    // Packed node {visited, reachable, parent_valid, parent, distance}.
    reg [STATE_W-1:0] nodes[0:NUM_NODES-1];
    reg [STATE_W-1:0] node_q,best_record;
    reg [WEIGHT_W:0] edge_q;
    reg [ADDR_W-1:0] clear_index,pending_address,best_base;
    reg [WEIGHT_W-1:0] pending_weight;
    reg pending_last,started,best_found;
    reg [NODE_W-1:0] init_index,scan_index,best_vertex,neighbor,out_index;
    reg [DIST_W-1:0] best_distance;
    wire [ADDR_W-1:0] input_address=s_from[NODE_W-1:0]*NUM_NODES+s_to[NODE_W-1:0];
    wire [ADDR_W-1:0] neighbor_address=best_base+neighbor;
    wire [DIST_W-1:0] read_distance=node_q[DIST_W-1:0];
    wire read_reachable=node_q[STATE_W-2];
    wire read_visited=node_q[STATE_W-1];
    wire [DIST_W:0] trial_distance={1'b0,best_distance}+
        {{(NODE_W+1){1'b0}},edge_q[WEIGHT_W-1:0]};
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUTPUT_HOLD;
    assign m_vertex=out_index;
    assign m_distance=node_q[DIST_W-1:0];
    assign m_parent=node_q[DIST_W+:NODE_W];
    assign m_parent_valid=node_q[STATE_W-3];
    assign m_reachable=node_q[STATE_W-2];
    assign m_first=out_index==0;
    assign m_last=out_index==NUM_NODES-1;
    generate if(NUM_NODES<1 || NUM_NODES>64 || WEIGHT_W<1 || WEIGHT_W>24 ||
                TAG_W<1 || TAG_W>32) begin : g_invalid
        dijkstra_sssp_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    always @(posedge clk) begin
        if(rst) begin
            state<=CLEAR_EDGES;clear_index<=0;started<=0;
            m_source<=0;m_error<=0;m_tag<=0;out_index<=0;
            node_q<=0;edge_q<=0;best_record<=0;best_found<=0;
            pending_address<=0;pending_weight<=0;pending_last<=0;
            init_index<=0;scan_index<=0;best_vertex<=0;neighbor<=0;
            best_base<=0;best_distance<=0;
        end else case(state)
            CLEAR_EDGES: begin
                edges[clear_index]<=0;
                if(clear_index==EDGES-1) begin clear_index<=0;state<=CAPTURE;end
                else clear_index<=clear_index+1'b1;
            end
            CAPTURE: if(s_valid) begin
                if(!started) begin
                    started<=1;m_source<=s_source;m_tag<=s_tag;
                    m_error[1]<=s_source>=NUM_NODES;
                end
                if(s_keep && (s_from>=NUM_NODES || s_to>=NUM_NODES)) m_error[0]<=1;
                if(s_keep && s_from<NUM_NODES && s_to<NUM_NODES) begin
                    edge_q<=edges[input_address];pending_address<=input_address;
                    pending_weight<=s_weight;pending_last<=s_last;state<=EDGE_STORE;
                end else if(s_last) begin init_index<=0;state<=INIT_NODES;end
            end
            EDGE_STORE: begin
                // Parallel edges collapse to their minimum, independent of order.
                if(!edge_q[WEIGHT_W] || pending_weight<edge_q[WEIGHT_W-1:0])
                    edges[pending_address]<={1'b1,pending_weight};
                if(pending_last) begin init_index<=0;state<=INIT_NODES;end
                else state<=CAPTURE;
            end
            INIT_NODES: begin
                nodes[init_index]<={1'b0,(!m_error[1] && init_index==m_source),
                    1'b0,{NODE_W{1'b0}},{DIST_W{1'b0}}};
                if(init_index==NUM_NODES-1) begin
                    scan_index<=0;best_found<=0;out_index<=0;
                    state<=m_error[1]?OUTPUT_READ:SELECT_READ;
                end else init_index<=init_index+1'b1;
            end
            SELECT_READ: begin node_q<=nodes[scan_index];state<=SELECT_COMPARE;end
            SELECT_COMPARE: begin
                // Ascending scan + strict improvement selects lowest ID on ties.
                if(read_reachable && !read_visited && (!best_found || read_distance<best_distance)) begin
                    best_found<=1;best_distance<=read_distance;best_vertex<=scan_index;
                    best_record<=node_q;best_base<=scan_index*NUM_NODES;
                end
                if(scan_index==NUM_NODES-1) state<=SELECT_COMMIT;
                else begin scan_index<=scan_index+1'b1;state<=SELECT_READ;end
            end
            SELECT_COMMIT: if(!best_found) begin out_index<=0;state<=OUTPUT_READ;end
                else begin
                    nodes[best_vertex]<={1'b1,best_record[STATE_W-2:0]};
                    neighbor<=0;state<=RELAX_READ;
                end
            RELAX_READ: begin
                edge_q<=edges[neighbor_address];node_q<=nodes[neighbor];state<=RELAX_COMPARE;
            end
            RELAX_COMPARE: begin
                if(edge_q[WEIGHT_W] && !read_visited &&
                   (!read_reachable || trial_distance<{1'b0,read_distance}))
                    nodes[neighbor]<={1'b0,1'b1,1'b1,best_vertex,trial_distance[DIST_W-1:0]};
                if(neighbor==NUM_NODES-1) begin scan_index<=0;best_found<=0;state<=SELECT_READ;end
                else begin neighbor<=neighbor+1'b1;state<=RELAX_READ;end
            end
            OUTPUT_READ: begin node_q<=nodes[out_index];state<=OUTPUT_HOLD;end
            OUTPUT_HOLD: if(m_ready) begin
                if(out_index==NUM_NODES-1) begin
                    clear_index<=0;started<=0;m_error<=0;m_source<=0;m_tag<=0;state<=CLEAR_EDGES;
                end else begin out_index<=out_index+1'b1;state<=OUTPUT_READ;end
            end
            default: state<=CLEAR_EDGES;
        endcase
    end
endmodule
