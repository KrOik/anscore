// SPDX-License-Identifier: Apache-2.0
// Command-oriented disjoint sets. Union-by-rank; no path compression.
module disjoint_set_union #(
    parameter integer NUM_NODES=64,
    parameter integer TAG_W=8,
    localparam integer INDEX_W=(NUM_NODES<2)?1:$clog2(NUM_NODES),
    localparam integer COUNT_W=(NUM_NODES<2)?1:$clog2(NUM_NODES+1),
    localparam integer RANK_W=($clog2(NUM_NODES)<2)?1:$clog2($clog2(NUM_NODES)+1)
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire [1:0] s_op, // 0 FIND(a), 1 UNION(a,b), 2 SAME(a,b), 3 CLEAR
    input wire [INDEX_W-1:0] s_a,s_b,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg [1:0] m_op,
    output reg [INDEX_W-1:0] m_root,
    output reg m_same,m_merged,m_error,
    output wire [COUNT_W-1:0] m_groups,
    output reg [TAG_W-1:0] m_tag
);
    generate if(NUM_NODES<1 || NUM_NODES>4096 || TAG_W<1 || TAG_W>32) begin : g_invalid
        disjoint_set_union_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    localparam integer ENTRY_W=INDEX_W+RANK_W;
    localparam [2:0] INITIALIZE=0,IDLE=1,FIND_READ=2,FIND_CAPTURE=3,
        DECIDE=4,LINK=5,PROMOTE=6,EMIT=7;
    localparam [INDEX_W:0] NODE_LIMIT=(INDEX_W+1)'(NUM_NODES);
    localparam [COUNT_W-1:0] FULL_GROUPS=COUNT_W'(NUM_NODES);
    reg [2:0] state;
    reg initialize_reply,finding_b;
    reg [INDEX_W-1:0] init_index,current,node_b,root_a,root_b;
    reg [RANK_W-1:0] rank_a,rank_b;
    reg [INDEX_W-1:0] winner,loser;
    reg [RANK_W-1:0] winner_rank,loser_rank;
    reg equal_rank;
    reg [COUNT_W-1:0] groups;
    reg [ENTRY_W-1:0] nodes[0:NUM_NODES-1];
    reg [ENTRY_W-1:0] node_q;
    wire [INDEX_W-1:0] parent_q=node_q[INDEX_W-1:0];
    wire [RANK_W-1:0] rank_q=node_q[ENTRY_W-1:INDEX_W];
    wire a_wins=(rank_a>rank_b) || ((rank_a==rank_b) && (root_a<root_b));
    wire a_valid={1'b0,s_a}<NODE_LIMIT;
    wire b_valid={1'b0,s_b}<NODE_LIMIT;
    wire write_enable=!rst && (state==INITIALIZE || state==LINK || state==PROMOTE);
    wire [INDEX_W-1:0] write_address=(state==INITIALIZE)?init_index:(state==LINK)?loser:winner;
    wire [ENTRY_W-1:0] write_data=(state==INITIALIZE)?{{RANK_W{1'b0}},init_index}:
        (state==LINK)?{loser_rank,winner}:{winner_rank+1'b1,winner};
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==EMIT;
    assign m_groups=groups;

    // One synchronous read and one write port, with exclusive access states.
    // Reset initializes ownership/control, then fills singleton nodes in N
    // clocks; it does not reset an entire RAM array on a single edge.
    always @(posedge clk) begin
        if(write_enable) nodes[write_address]<=write_data;
        if(!rst && state==FIND_READ) node_q<=nodes[current];
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=INITIALIZE;init_index<=0;initialize_reply<=0;
            current<=0;node_b<=0;root_a<=0;root_b<=0;rank_a<=0;rank_b<=0;
            winner<=0;loser<=0;winner_rank<=0;loser_rank<=0;equal_rank<=0;
            groups<=0;finding_b<=0;
            m_op<=0;m_root<=0;m_same<=0;m_merged<=0;m_error<=0;m_tag<=0;
        end else case(state)
            INITIALIZE: begin
                if(init_index==NUM_NODES-1) begin
                    groups<=FULL_GROUPS;
                    state<=initialize_reply?EMIT:IDLE;
                end else init_index<=init_index+1'b1;
            end
            IDLE: if(s_valid) begin
                m_op<=s_op;m_tag<=s_tag;m_root<=0;m_same<=0;m_merged<=0;m_error<=0;
                if(s_op==3) begin
                    init_index<=0;initialize_reply<=1;state<=INITIALIZE;
                end else if(!a_valid || ((s_op!=0) && !b_valid)) begin
                    m_error<=1;state<=EMIT;
                end else begin
                    current<=s_a;node_b<=s_b;finding_b<=0;state<=FIND_READ;
                end
            end
            FIND_READ: state<=FIND_CAPTURE;
            FIND_CAPTURE: begin
                if(parent_q!=current) begin current<=parent_q;state<=FIND_READ;end
                else if(!finding_b) begin
                    root_a<=current;rank_a<=rank_q;
                    if(m_op==0) begin m_root<=current;m_same<=1;state<=EMIT;end
                    else begin current<=node_b;finding_b<=1;state<=FIND_READ;end
                end else begin root_b<=current;rank_b<=rank_q;state<=DECIDE;end
            end
            DECIDE: begin
                m_root<=root_a;
                m_same<=(root_a==root_b);
                if(m_op==2 || root_a==root_b) state<=EMIT;
                else begin
                    winner<=a_wins?root_a:root_b;
                    loser<=a_wins?root_b:root_a;
                    winner_rank<=a_wins?rank_a:rank_b;
                    loser_rank<=a_wins?rank_b:rank_a;
                    equal_rank<=(rank_a==rank_b);
                    m_root<=a_wins?root_a:root_b;
                    m_same<=1;m_merged<=1;state<=LINK;
                end
            end
            LINK: begin
                groups<=groups-1'b1;
                state<=equal_rank?PROMOTE:EMIT;
            end
            PROMOTE: state<=EMIT;
            EMIT: if(m_ready) state<=IDLE;
        endcase
    end
endmodule
