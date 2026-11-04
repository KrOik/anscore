// SPDX-License-Identifier: Apache-2.0
// Minimum spanning forest composition. Signed heap order, serialized UNION.
module kruskal_msf #(
    parameter integer NUM_NODES=16,
    parameter integer MAX_EDGES=32,
    parameter integer WEIGHT_W=16,
    parameter integer EDGE_TAG_W=8,
    parameter integer GRAPH_TAG_W=8,
    localparam integer INDEX_W=(NUM_NODES<2)?1:$clog2(NUM_NODES),
    localparam integer COUNT_W=(NUM_NODES<2)?1:$clog2(NUM_NODES+1),
    localparam integer EDGE_COUNT_W=(MAX_EDGES<2)?1:$clog2(MAX_EDGES+1),
    localparam integer TOTAL_W=WEIGHT_W+((NUM_NODES<3)?0:$clog2(NUM_NODES-1))
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire [INDEX_W-1:0] s_u,s_v,
    input wire signed [WEIGHT_W-1:0] s_weight,
    input wire [EDGE_TAG_W-1:0] s_edge_tag,
    input wire s_keep,s_last,
    input wire [GRAPH_TAG_W-1:0] s_graph_tag,
    output wire m_valid,
    input wire m_ready,
    output wire m_summary,
    output wire [INDEX_W-1:0] m_u,m_v,
    output wire signed [WEIGHT_W-1:0] m_weight,
    output wire [EDGE_TAG_W-1:0] m_edge_tag,
    output wire [GRAPH_TAG_W-1:0] m_graph_tag,
    output wire m_bad_index,m_overflow,
    output wire signed [TOTAL_W-1:0] m_total_weight,
    output wire [COUNT_W-1:0] m_selected,m_components
);
    generate if(NUM_NODES<1 || NUM_NODES>256 || MAX_EDGES<1 || MAX_EDGES>1024 ||
                WEIGHT_W<2 || WEIGHT_W>24 || EDGE_TAG_W<1 || EDGE_TAG_W>32 ||
                GRAPH_TAG_W<1 || GRAPH_TAG_W>32) begin : g_invalid
        kruskal_msf_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    localparam integer PAYLOAD_W=2*INDEX_W+EDGE_TAG_W;
    localparam [3:0] BOOT=0,INPUT_EDGE=1,PUSH=2,PUSH_WAIT=3,POP=4,POP_WAIT=5,
        UNION_CMD=6,UNION_WAIT=7,EMIT_EDGE=8,EMIT_SUMMARY=9,
        HEAP_CLEAR=10,HEAP_CLEAR_WAIT=11,DSU_CLEAR=12,DSU_CLEAR_WAIT=13;
    reg [3:0] state;
    reg first_beat,last_held,bad_index,overflow;
    reg [GRAPH_TAG_W-1:0] graph_tag;
    reg [EDGE_COUNT_W-1:0] retained,remaining;
    reg [COUNT_W-1:0] selected,components;
    reg signed [TOTAL_W-1:0] total;
    reg signed [WEIGHT_W-1:0] edge_weight;
    reg [PAYLOAD_W-1:0] edge_payload;
    wire [INDEX_W-1:0] edge_u=edge_payload[PAYLOAD_W-1 -: INDEX_W];
    wire [INDEX_W-1:0] edge_v=edge_payload[EDGE_TAG_W +: INDEX_W];
    wire ids_valid=({1'b0,s_u}<(INDEX_W+1)'(NUM_NODES)) &&
                   ({1'b0,s_v}<(INDEX_W+1)'(NUM_NODES));
    wire eligible=s_keep && ids_valid && s_u!=s_v;
    wire h_ready,h_valid;
    wire [WEIGHT_W-1:0] h_key;
    wire [PAYLOAD_W-1:0] h_data;
    wire [EDGE_COUNT_W-1:0] h_count;
    wire d_ready,d_valid,d_merged;
    wire [COUNT_W-1:0] d_groups;
    wire signed [TOTAL_W-1:0] extended_weight=
        {{(TOTAL_W-WEIGHT_W){edge_weight[WEIGHT_W-1]}},edge_weight};
    binary_heap_queue #(.KEY_W(WEIGHT_W),.DATA_W(PAYLOAD_W),
        .CAPACITY(MAX_EDGES),.SIGNED_KEY(1)) heap (
        .clk(clk),.rst(rst),.s_valid(state==PUSH || state==POP || state==HEAP_CLEAR),
        .s_ready(h_ready),.s_op((state==PUSH)?2'd0:(state==POP)?2'd1:2'd3),
        .s_key(edge_weight),.s_data(edge_payload),.m_valid(h_valid),
        .m_ready(state==PUSH_WAIT || state==POP_WAIT || state==HEAP_CLEAR_WAIT),
        .m_op(),.m_status(),.m_key(h_key),.m_data(h_data),.m_count(h_count));
    disjoint_set_union #(.NUM_NODES(NUM_NODES),.TAG_W(1)) sets (
        .clk(clk),.rst(rst),.s_valid(state==UNION_CMD || state==DSU_CLEAR),
        .s_ready(d_ready),.s_op((state==UNION_CMD)?2'd1:2'd3),
        .s_a(edge_u),.s_b(edge_v),.s_tag(1'b0),.m_valid(d_valid),
        .m_ready(state==UNION_WAIT || state==DSU_CLEAR_WAIT),.m_op(),
        .m_root(),.m_same(),.m_merged(d_merged),.m_error(),.m_groups(d_groups),.m_tag());
    assign s_ready=!rst && state==INPUT_EDGE;
    assign m_valid=!rst && (state==EMIT_EDGE || state==EMIT_SUMMARY);
    assign m_summary=state==EMIT_SUMMARY;
    assign m_u=m_summary?{INDEX_W{1'b0}}:edge_u;
    assign m_v=m_summary?{INDEX_W{1'b0}}:edge_v;
    assign m_weight=m_summary?{WEIGHT_W{1'b0}}:edge_weight;
    assign m_edge_tag=m_summary?{EDGE_TAG_W{1'b0}}:edge_payload[EDGE_TAG_W-1:0];
    assign m_graph_tag=graph_tag;
    assign m_bad_index=bad_index;
    assign m_overflow=overflow;
    assign m_total_weight=total;
    assign m_selected=selected;
    assign m_components=components;
    always @(posedge clk) begin
        if(rst) begin
            state<=BOOT;first_beat<=1;last_held<=0;bad_index<=0;overflow<=0;
            graph_tag<=0;retained<=0;remaining<=0;selected<=0;
            components<=COUNT_W'(NUM_NODES);total<=0;edge_weight<=0;edge_payload<=0;
        end else case(state)
            BOOT: if(h_ready && d_ready) state<=INPUT_EDGE;
            INPUT_EDGE: if(s_valid) begin
                if(first_beat) begin graph_tag<=s_graph_tag;first_beat<=0;end
                if(s_keep && !ids_valid) bad_index<=1;
                if(eligible && retained<EDGE_COUNT_W'(MAX_EDGES)) begin
                    edge_weight<=s_weight;
                    edge_payload<=(s_u<s_v)?{s_u,s_v,s_edge_tag}:{s_v,s_u,s_edge_tag};
                    retained<=retained+1'b1;last_held<=s_last;state<=PUSH;
                end else begin
                    if(eligible) overflow<=1;
                    if(s_last) state<=(retained==0)?EMIT_SUMMARY:POP;
                end
            end
            PUSH: if(h_ready) state<=PUSH_WAIT;
            PUSH_WAIT: if(h_valid) state<=last_held?POP:INPUT_EDGE;
            POP: if(h_ready) state<=POP_WAIT;
            POP_WAIT: if(h_valid) begin
                edge_weight<=h_key;edge_payload<=h_data;remaining<=h_count;state<=UNION_CMD;
            end
            UNION_CMD: if(d_ready) state<=UNION_WAIT;
            UNION_WAIT: if(d_valid) begin
                components<=d_groups;
                if(d_merged) begin
                    total<=total+extended_weight;selected<=selected+1'b1;state<=EMIT_EDGE;
                end else state<=(remaining==0)?EMIT_SUMMARY:POP;
            end
            EMIT_EDGE: if(m_ready) state<=(remaining==0)?EMIT_SUMMARY:POP;
            EMIT_SUMMARY: if(m_ready) state<=HEAP_CLEAR;
            HEAP_CLEAR: if(h_ready) state<=HEAP_CLEAR_WAIT;
            HEAP_CLEAR_WAIT: if(h_valid) state<=DSU_CLEAR;
            DSU_CLEAR: if(d_ready) state<=DSU_CLEAR_WAIT;
            DSU_CLEAR_WAIT: if(d_valid) begin
                first_beat<=1;bad_index<=0;overflow<=0;graph_tag<=0;
                retained<=0;remaining<=0;selected<=0;components<=COUNT_W'(NUM_NODES);
                total<=0;state<=INPUT_EDGE;
            end
            default: state<=BOOT;
        endcase
    end
endmodule
