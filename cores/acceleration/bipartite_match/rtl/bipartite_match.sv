// SPDX-License-Identifier: Apache-2.0
// Bounded unweighted maximum bipartite matching, serialized alternating BFS.
module bipartite_match #(
    parameter integer LEFT_N=8,
    parameter integer RIGHT_N=8,
    parameter integer TAG_W=8,
    localparam integer LEFT_W=(LEFT_N<2)?1:$clog2(LEFT_N),
    localparam integer RIGHT_W=(RIGHT_N<2)?1:$clog2(RIGHT_N),
    localparam integer MAX_MATCH=(LEFT_N<RIGHT_N)?LEFT_N:RIGHT_N,
    localparam integer COUNT_W=(MAX_MATCH<2)?1:$clog2(MAX_MATCH+1)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [LEFT_W-1:0] s_left,
    input wire [RIGHT_W-1:0] s_right,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [LEFT_W-1:0] m_left,
    output wire [RIGHT_W-1:0] m_right,
    output wire m_matched,m_last,
    output wire [COUNT_W-1:0] m_cardinality,
    output wire m_bad_index,
    output wire [TAG_W-1:0] m_tag
);
    generate if(LEFT_N<1 || LEFT_N>32 || RIGHT_N<1 || RIGHT_N>32 || TAG_W<1 || TAG_W>32) begin : g_invalid
        bipartite_match_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    localparam integer QUEUE_W=(LEFT_N<2)?1:$clog2(LEFT_N+1);
    localparam [3:0] CLEAR=0,CAPTURE=1,START_ROOT=2,DEQUEUE=3,ROW_READ=4,
        SCAN=5,AUGMENT_READ=6,AUGMENT_WRITE=7,NEXT_ROOT=8,EMIT=9;
    reg [3:0] state;
    reg [LEFT_W-1:0] clear_left,root,current_left,augment_left,out_left;
    reg [RIGHT_W-1:0] scan_right,walk_right;
    reg [QUEUE_W-1:0] queue_head,queue_tail;
    reg [COUNT_W-1:0] cardinality;
    reg [TAG_W-1:0] graph_tag;
    reg first_beat,bad_index;
    reg [RIGHT_N-1:0] adjacency[0:LEFT_N-1];
    reg [RIGHT_N-1:0] row_q;
    reg [LEFT_N-1:0] left_valid,seen_left;
    reg [RIGHT_N-1:0] right_valid,seen_right;
    reg [RIGHT_W-1:0] left_match[0:LEFT_N-1];
    reg [LEFT_W-1:0] right_match[0:RIGHT_N-1];
    reg [LEFT_W-1:0] parent_right[0:RIGHT_N-1];
    reg [LEFT_W-1:0] queue[0:LEFT_N-1];
    wire input_indices_valid=({1'b0,s_left}<(LEFT_W+1)'(LEFT_N)) &&
                             ({1'b0,s_right}<(RIGHT_W+1)'(RIGHT_N));
    wire [LEFT_W-1:0] matched_left=right_match[scan_right];
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==EMIT;
    assign m_left=out_left;
    assign m_matched=left_valid[out_left];
    assign m_right=m_matched?left_match[out_left]:{RIGHT_W{1'b0}};
    assign m_last=out_left==LEFT_W'(LEFT_N-1);
    assign m_cardinality=cardinality;
    assign m_bad_index=bad_index;
    assign m_tag=graph_tag;

    // One adjacency row is sampled before its neighbors are examined. Dynamic
    // bit writes and small indexed scratch maps do not promise block RAM.
    always @(posedge clk) begin
        if(!rst && state==CLEAR) adjacency[clear_left]<={RIGHT_N{1'b0}};
        if(!rst && state==CAPTURE && s_valid && s_keep && input_indices_valid)
            adjacency[s_left][s_right]<=1'b1;
        if(!rst && state==ROW_READ) row_q<=adjacency[current_left];
        if(!rst && state==AUGMENT_READ) augment_left<=parent_right[walk_right];
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=CLEAR;clear_left<=0;root<=0;current_left<=0;out_left<=0;
            scan_right<=0;walk_right<=0;queue_head<=0;queue_tail<=0;
            cardinality<=0;graph_tag<=0;first_beat<=1;bad_index<=0;
            left_valid<=0;right_valid<=0;seen_left<=0;seen_right<=0;
        end else case(state)
            CLEAR: begin
                if(clear_left==LEFT_W'(LEFT_N-1)) state<=CAPTURE;
                else clear_left<=clear_left+1'b1;
            end
            CAPTURE: if(s_valid) begin
                if(first_beat) begin graph_tag<=s_tag;first_beat<=0;end
                if(s_keep && !input_indices_valid) bad_index<=1;
                if(s_last) begin root<=0;state<=START_ROOT;end
            end
            START_ROOT: begin
                if(left_valid[root]) state<=NEXT_ROOT;
                else begin
                    seen_left<=({{(LEFT_N-1){1'b0}},1'b1}<<root);
                    seen_right<=0;queue_head<=0;queue_tail<=QUEUE_W'(1);
                    queue[0]<=root;state<=DEQUEUE;
                end
            end
            DEQUEUE: begin
                if(queue_head==queue_tail) state<=NEXT_ROOT;
                else begin
                    current_left<=queue[queue_head];queue_head<=queue_head+1'b1;
                    scan_right<=0;state<=ROW_READ;
                end
            end
            ROW_READ: state<=SCAN;
            SCAN: begin
                if(scan_right==RIGHT_W'(RIGHT_N-1)) state<=DEQUEUE;
                else scan_right<=scan_right+1'b1;
                if(row_q[scan_right] && !seen_right[scan_right]) begin
                    seen_right[scan_right]<=1'b1;
                    parent_right[scan_right]<=current_left;
                    if(!right_valid[scan_right]) begin
                        walk_right<=scan_right;state<=AUGMENT_READ;
                    end else if(!seen_left[matched_left]) begin
                        queue[queue_tail]<=matched_left;queue_tail<=queue_tail+1'b1;
                        seen_left[matched_left]<=1'b1;
                    end
                end
            end
            AUGMENT_READ: state<=AUGMENT_WRITE;
            AUGMENT_WRITE: begin
                left_match[augment_left]<=walk_right;left_valid[augment_left]<=1'b1;
                right_match[walk_right]<=augment_left;right_valid[walk_right]<=1'b1;
                if(augment_left==root) begin
                    cardinality<=cardinality+1'b1;state<=NEXT_ROOT;
                end else begin
                    walk_right<=left_match[augment_left];state<=AUGMENT_READ;
                end
            end
            NEXT_ROOT: begin
                if(root==LEFT_W'(LEFT_N-1)) begin out_left<=0;state<=EMIT;end
                else begin root<=root+1'b1;state<=START_ROOT;end
            end
            EMIT: if(m_ready) begin
                if(m_last) begin
                    state<=CLEAR;clear_left<=0;first_beat<=1;bad_index<=0;graph_tag<=0;
                    cardinality<=0;left_valid<=0;right_valid<=0;
                end else out_left<=out_left+1'b1;
            end
            default: state<=CLEAR;
        endcase
    end
endmodule
