// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE exact general-graph matching; see README and SOURCES.
`timescale 1ns/1ps
module general_weighted_matching #(
    parameter integer NUM_NODES=8, WEIGHT_W=16, TAG_W=8,
    localparam integer IW=(NUM_NODES>1?$clog2(NUM_NODES):1),
    localparam integer CW=(NUM_NODES>0?$clog2(NUM_NODES+1):1),
    localparam integer SB=(WEIGHT_W-1)+((NUM_NODES/2>1)?$clog2(NUM_NODES/2):0),
    localparam integer SCORE_W=(SB>0?SB:1)
)(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire [31:0] s_from, s_to,
    input wire signed [WEIGHT_W-1:0] s_weight,
    input wire s_present, s_keep, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg m_keep, m_last,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag,
    output reg [IW-1:0] m_node, m_partner,
    output reg m_matched,
    output reg [CW-1:0] m_cardinality,
    output reg [SCORE_W-1:0] m_total_weight
);
    // Clamping only prevents malformed declarations in the invalid branch.
    localparam integer N=(NUM_NODES>=1 && NUM_NODES<=12)?NUM_NODES:1;
    localparam integer AW=(N*N>1?$clog2(N*N):1), DW=SCORE_W+CW;
    localparam integer STATES=1<<N;
    localparam [N-1:0] ONE={{(N-1){1'b0}},1'b1}, ALL={N{1'b1}};
    localparam [3:0] INIT=0, LOAD=1, ZERO=2, START=3, READ_BASE=4,
        USE_BASE=5, CHECK_EDGE=6, READ_EDGE=7, USE_EDGE=8,
        USE_CANDIDATE=9, COMMIT=10, TRACE_INIT=11, TRACE_READ=12,
        TRACE_USE=13, EMIT=14, ERROR=15;
    reg [3:0] state;
    reg [WEIGHT_W:0] edges[0:N*N-1];
    reg [DW-1:0] dp[0:STATES-1];
    // Neither RAM payload nor synchronous read-q has a reset fanout.
    reg [WEIGHT_W:0] edge_q;
    reg [DW-1:0] dp_q;
    reg [AW-1:0] init_address;
    reg [N-1:0] mask, remainder, matched;
    reg [IW-1:0] vertex, output_node;
    reg [CW-1:0] partner_scan, best_choice, cardinality;
    reg [SCORE_W-1:0] best_score, total_weight;
    reg [WEIGHT_W-1:0] candidate_weight;
    reg [N*IW-1:0] partners;
    reg first;
    reg [TAG_W-1:0] tag;
    reg [1:0] frame_error;

    function automatic [IW-1:0] least_vertex(input [N-1:0] bits);
        integer i;
        begin
            least_vertex=0;
            for(i=N-1;i>=0;i=i-1)if(bits[i])least_vertex=IW'(i);
        end
    endfunction
    wire [IW-1:0] lowest=least_vertex(mask);
    wire bad_index=s_keep && (s_from>=NUM_NODES || s_to>=NUM_NODES);
    wire bad_loop=s_keep && !bad_index && s_from==s_to;
    wire [1:0] next_error=(bad_index || frame_error==1)?2'd1:
                          (bad_loop || frame_error==2)?2'd2:2'd0;
    wire [IW-1:0] input_lo=(s_from<s_to)?s_from[IW-1:0]:s_to[IW-1:0];
    wire [IW-1:0] input_hi=(s_from<s_to)?s_to[IW-1:0]:s_from[IW-1:0];
    wire [AW-1:0] input_address=AW'(input_lo*N+input_hi);
    wire [AW-1:0] edge_address=AW'(vertex*N+partner_scan);
    wire edge_positive=edge_q[WEIGHT_W] && !edge_q[WEIGHT_W-1] &&
                       (|edge_q[WEIGHT_W-1:0]);
    wire [N-1:0] candidate_mask=remainder & ~(ONE<<partner_scan);
    wire [SCORE_W:0] candidate_score={1'b0,dp_q[SCORE_W-1:0]}+
                                    (SCORE_W+1)'(candidate_weight);
    wire [CW-1:0] trace_choice=dp_q[SCORE_W+:CW];
    wire [CW-1:0] trace_partner=trace_choice-1'b1;

    assign s_ready=!rst && state==LOAD;
    assign m_valid=!rst && (state==EMIT || state==ERROR);
    generate if(NUM_NODES<1 || NUM_NODES>12 || WEIGHT_W<1 || WEIGHT_W>32 ||
                TAG_W<1 || TAG_W>32)begin : g_invalid
        general_weighted_matching_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    // Each bank has a synchronous read OR one write per edge. No collisions.
    always @(posedge clk)if(!rst)begin
        if(state==INIT)edges[init_address]<=0;
        if(state==LOAD && s_valid && s_keep && !bad_index && !bad_loop &&
           frame_error==0)edges[input_address]<={s_present,s_weight};
        if(state==READ_EDGE)edge_q<=edges[edge_address];
        if(state==ZERO)dp[0]<=0;
        if(state==READ_BASE)dp_q<=dp[remainder];
        if(state==USE_EDGE && edge_positive)dp_q<=dp[candidate_mask];
        if(state==COMMIT)dp[mask]<={best_choice,best_score};
        if(state==TRACE_READ && mask!=0)dp_q<=dp[mask];
    end
    always @* begin
        m_keep=0;m_last=0;m_error=0;m_tag=tag;m_node=0;m_partner=0;
        m_matched=0;m_cardinality=0;m_total_weight=0;
        if(state==EMIT)begin
            m_keep=1;m_last=(output_node==N-1);m_node=output_node;
            m_matched=matched[output_node];
            if(matched[output_node])m_partner=partners[output_node*IW+:IW];
            m_cardinality=cardinality;m_total_weight=total_weight;
        end else if(state==ERROR)begin m_last=1;m_error=frame_error;end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=INIT;init_address<=0;first<=1;tag<=0;frame_error<=0;
            mask<=0;remainder<=0;matched<=0;partners<=0;vertex<=0;
            output_node<=0;partner_scan<=0;best_choice<=0;cardinality<=0;
            best_score<=0;total_weight<=0;candidate_weight<=0;
        end else case(state)
            INIT:begin
                if(init_address==N*N-1)begin
                    first<=1;frame_error<=0;state<=LOAD;
                end else init_address<=init_address+1'b1;
            end
            LOAD:if(s_valid)begin
                if(first)begin tag<=s_tag;first<=0;end
                frame_error<=next_error;
                if(s_last)state<=(next_error!=0)?ERROR:ZERO;
            end
            ZERO:begin mask<=ONE;state<=START;end
            START:begin
                vertex<=lowest;remainder<=mask & ~(ONE<<lowest);
                state<=READ_BASE;
            end
            READ_BASE:state<=USE_BASE;
            USE_BASE:begin
                best_score<=dp_q[SCORE_W-1:0];best_choice<=0;
                partner_scan<={1'b0,vertex}+1'b1;state<=CHECK_EDGE;
            end
            CHECK_EDGE:begin
                if(partner_scan==N)state<=COMMIT;
                else if(mask[partner_scan])state<=READ_EDGE;
                else partner_scan<=partner_scan+1'b1;
            end
            READ_EDGE:state<=USE_EDGE;
            USE_EDGE:begin
                if(edge_positive)begin
                    candidate_weight<=edge_q[WEIGHT_W-1:0];state<=USE_CANDIDATE;
                end else begin partner_scan<=partner_scan+1'b1;state<=CHECK_EDGE;end
            end
            USE_CANDIDATE:begin
                // All tied optima keep the prior choice: unmatched, then j↑.
                if(candidate_score>{1'b0,best_score})begin
                    best_score<=candidate_score[SCORE_W-1:0];
                    best_choice<=partner_scan+1'b1;
                end
                partner_scan<=partner_scan+1'b1;state<=CHECK_EDGE;
            end
            COMMIT:begin
                if(mask==ALL)begin total_weight<=best_score;state<=TRACE_INIT;end
                else begin mask<=mask+1'b1;state<=START;end
            end
            TRACE_INIT:begin
                mask<=ALL;matched<=0;partners<=0;cardinality<=0;state<=TRACE_READ;
            end
            TRACE_READ:begin
                if(mask==0)begin output_node<=0;state<=EMIT;end
                else state<=TRACE_USE;
            end
            TRACE_USE:begin
                mask<=mask & ~(ONE<<lowest);
                if(trace_choice!=0)begin
                    mask<=mask & ~(ONE<<lowest) & ~(ONE<<trace_partner);
                    matched[lowest]<=1;matched[trace_partner]<=1;
                    partners[lowest*IW+:IW]<=IW'(trace_partner);
                    partners[trace_partner*IW+:IW]<=lowest;
                    cardinality<=cardinality+1'b1;
                end
                state<=TRACE_READ;
            end
            EMIT:if(m_ready)begin
                if(output_node==N-1)begin init_address<=0;state<=INIT;end
                else output_node<=output_node+1'b1;
            end
            ERROR:if(m_ready)begin init_address<=0;state<=INIT;end
            default:begin state<=INIT;init_address<=0;end
        endcase
    end
endmodule
