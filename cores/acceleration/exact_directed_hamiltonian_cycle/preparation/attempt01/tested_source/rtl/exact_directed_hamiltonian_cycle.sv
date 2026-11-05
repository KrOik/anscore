// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE bounded exact directed tour engine; see README and SOURCES.
`timescale 1ns/1ps
module exact_directed_hamiltonian_cycle #(
    parameter integer NUM_NODES=8, WEIGHT_W=16, TAG_W=8,
    localparam integer IW=(NUM_NODES>=2 && NUM_NODES<=12)?$clog2(NUM_NODES):1,
    localparam integer CW=(NUM_NODES>=2 && NUM_NODES<=12)?$clog2(NUM_NODES+1):2,
    localparam integer SCORE_W=((WEIGHT_W>=2 && WEIGHT_W<=24)?WEIGHT_W:2)+IW
)(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire [31:0] s_from, s_to,
    input wire signed [WEIGHT_W-1:0] s_weight,
    input wire s_present, s_keep, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg m_keep, m_last, m_feasible,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag,
    output reg [CW-1:0] m_position,
    output reg [IW-1:0] m_vertex,
    output reg signed [SCORE_W-1:0] m_cost
);
    // Invalid parameters elaborate a named missing module, while declaration
    // clamps prevent invalid sizes from hiding that intended diagnostic.
    localparam integer N=(NUM_NODES>=2 && NUM_NODES<=12)?NUM_NODES:2;
    localparam integer K=N-1, ENTRIES=K*(1<<K), DW=SCORE_W+IW+1;
    localparam integer EAW=$clog2(N*N), DAW=(ENTRIES>1)?$clog2(ENTRIES):1;
    localparam [K-1:0] ONE={{(K-1){1'b0}},1'b1}, ALL={K{1'b1}};
    localparam [4:0] INIT=0, LOAD=1, ENTRY=2, SINGLE_READ=3,
        SINGLE_USE=4, PRED_SCAN=5, PAIR_READ=6, PAIR_SUM=7,
        PAIR_COMPARE=8, COMMIT=9, CLOSE_SCAN=10, CLOSE_READ=11,
        CLOSE_SUM=12, CLOSE_COMPARE=13, TRACE_READ=14, TRACE_USE=15,
        EMIT=16, SUMMARY=17;
    reg [4:0] state;
    reg [WEIGHT_W:0] edges [0:N*N-1];
    reg [DW-1:0] dp [0:ENTRIES-1];
    reg [WEIGHT_W:0] edge_q;
    reg [DW-1:0] dp_q;
    reg [EAW-1:0] init_address, edge_read_address;
    reg [DAW-1:0] dp_read_address;
    reg [K-1:0] mask, remainder;
    reg [IW-1:0] node, best_parent, final_node;
    reg [CW-1:0] scan, trace_position, output_position;
    reg signed [SCORE_W-1:0] best_score, total_cost;
    reg signed [SCORE_W:0] sum_q;
    reg best_valid, total_valid, candidate_valid, first;
    reg [(N+1)*IW-1:0] tour;
    reg [TAG_W-1:0] tag;
    reg [1:0] frame_error;

    wire bad_index=s_keep && (s_from>=NUM_NODES || s_to>=NUM_NODES);
    wire bad_loop=s_keep && !bad_index && s_from==s_to;
    wire [1:0] next_error=(bad_index || frame_error==1)?2'd1:
                          (bad_loop || frame_error==2)?2'd2:2'd0;
    wire [EAW-1:0] input_address=EAW'(s_from*N+s_to);
    wire [DAW-1:0] current_address=DAW'(mask*K+(node-1'b1));
    wire [K-1:0] without_node=mask & ~(ONE<<(node-1'b1));
    wire signed [SCORE_W:0] predecessor_score=
        $signed({dp_q[SCORE_W-1],dp_q[SCORE_W-1:0]});
    wire signed [SCORE_W:0] edge_score=
        (SCORE_W+1)'($signed(edge_q[WEIGHT_W-1:0]));
    // Shared signed addition; comparison occurs one register later.
    wire signed [SCORE_W:0] candidate_sum=predecessor_score+edge_score;
    wire signed [SCORE_W-1:0] comparison_best=
        (state==CLOSE_COMPARE)?total_cost:best_score;
    wire candidate_better=sum_q<$signed({comparison_best[SCORE_W-1],comparison_best});

    assign s_ready=!rst && state==LOAD;
    assign m_valid=!rst && (state==EMIT || state==SUMMARY);
    generate if(NUM_NODES<2 || NUM_NODES>12 || WEIGHT_W<2 || WEIGHT_W>24 ||
                TAG_W<1 || TAG_W>32)begin : g_invalid
        exact_directed_hamiltonian_cycle_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    always @* begin
        edge_read_address=0;dp_read_address=0;
        case(state)
            SINGLE_READ:edge_read_address=EAW'(node);
            PAIR_READ:begin
                edge_read_address=EAW'(scan*N+node);
                dp_read_address=DAW'(remainder*K+(scan-1'b1));
            end
            CLOSE_READ:begin
                edge_read_address=EAW'(scan*N);
                dp_read_address=DAW'(ALL*K+(scan-1'b1));
            end
            TRACE_READ:dp_read_address=current_address;
            default:begin end
        endcase
    end
    // Two independent single-port banks. A bank reads OR writes on an edge;
    // RAM payload and read registers have no reset fanout.
    always @(posedge clk)if(!rst)begin
        if(state==INIT)edges[init_address]<=0;
        else if(state==LOAD && s_valid && s_keep && !bad_index &&
                !bad_loop && frame_error==0)
            edges[input_address]<={s_present,s_weight};
        else if(state==SINGLE_READ || state==PAIR_READ || state==CLOSE_READ)
            edge_q<=edges[edge_read_address];
        if(state==COMMIT)dp[current_address]<={best_valid,best_parent,best_score};
        else if(state==PAIR_READ || state==CLOSE_READ || state==TRACE_READ)
            dp_q<=dp[dp_read_address];
    end
    always @* begin
        m_keep=0;m_last=1;m_feasible=0;m_error=0;m_tag=tag;
        m_position=0;m_vertex=0;m_cost=0;
        if(state==EMIT)begin
            m_keep=1;m_last=(output_position==N);m_feasible=1;
            m_position=output_position;
            m_vertex=tour[output_position*IW+:IW];m_cost=total_cost;
        end else if(state==SUMMARY)m_error=frame_error;
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=INIT;init_address<=0;mask<=0;remainder<=0;
            node<=1;scan<=1;best_parent<=0;final_node<=0;
            trace_position<=0;output_position<=0;best_score<=0;
            total_cost<=0;sum_q<=0;best_valid<=0;total_valid<=0;
            candidate_valid<=0;first<=1;tour<=0;tag<=0;frame_error<=0;
        end else case(state)
            INIT:begin
                if(init_address==N*N-1)begin
                    first<=1;frame_error<=0;state<=LOAD;
                end else init_address<=init_address+1'b1;
            end
            LOAD:if(s_valid)begin
                if(first)begin tag<=s_tag;first<=0;end
                frame_error<=next_error;
                if(s_last)begin
                    if(next_error!=0)state<=SUMMARY;
                    else begin mask<=ONE;node<=1;state<=ENTRY;end
                end
            end
            ENTRY:begin
                best_valid<=0;best_score<=0;best_parent<=0;
                remainder<=without_node;
                if(!mask[node-1'b1])begin
                    if(node==N-1)begin mask<=mask+1'b1;node<=1;end
                    else node<=node+1'b1;
                end else if(without_node==0)state<=SINGLE_READ;
                else begin scan<=1;state<=PRED_SCAN;end
            end
            SINGLE_READ:state<=SINGLE_USE;
            SINGLE_USE:begin
                best_valid<=edge_q[WEIGHT_W];
                best_score<=SCORE_W'($signed(edge_q[WEIGHT_W-1:0]));
                best_parent<=0;state<=COMMIT;
            end
            PRED_SCAN:begin
                if(scan==N)state<=COMMIT;
                else if(remainder[scan-1'b1])state<=PAIR_READ;
                else scan<=scan+1'b1;
            end
            PAIR_READ:state<=PAIR_SUM;
            PAIR_SUM:begin
                sum_q<=candidate_sum;
                candidate_valid<=edge_q[WEIGHT_W] && dp_q[DW-1];
                state<=PAIR_COMPARE;
            end
            PAIR_COMPARE:begin
                // i increases; strict improvement gives the declared tie rule.
                if(candidate_valid && (!best_valid || candidate_better))begin
                    best_valid<=1;best_score<=sum_q[SCORE_W-1:0];
                    best_parent<=IW'(scan);
                end
                scan<=scan+1'b1;state<=PRED_SCAN;
            end
            COMMIT:begin
                if(node==N-1)begin
                    if(mask==ALL)begin
                        scan<=1;total_valid<=0;total_cost<=0;
                        final_node<=0;state<=CLOSE_SCAN;
                    end else begin mask<=mask+1'b1;node<=1;state<=ENTRY;end
                end else begin node<=node+1'b1;state<=ENTRY;end
            end
            CLOSE_SCAN:begin
                if(scan==N)begin
                    if(!total_valid)state<=SUMMARY;
                    else begin
                        mask<=ALL;node<=final_node;trace_position<=CW'(N-1);
                        tour<=0;output_position<=0;state<=TRACE_READ;
                    end
                end else state<=CLOSE_READ;
            end
            CLOSE_READ:state<=CLOSE_SUM;
            CLOSE_SUM:begin
                sum_q<=candidate_sum;
                candidate_valid<=edge_q[WEIGHT_W] && dp_q[DW-1];
                state<=CLOSE_COMPARE;
            end
            CLOSE_COMPARE:begin
                if(candidate_valid && (!total_valid || candidate_better))begin
                    total_valid<=1;total_cost<=sum_q[SCORE_W-1:0];
                    final_node<=IW'(scan);
                end
                scan<=scan+1'b1;state<=CLOSE_SCAN;
            end
            TRACE_READ:state<=TRACE_USE;
            TRACE_USE:begin
                tour[trace_position*IW+:IW]<=node;
                mask<=without_node;node<=dp_q[SCORE_W+:IW];
                if(trace_position==1)state<=EMIT;
                else begin trace_position<=trace_position-1'b1;state<=TRACE_READ;end
            end
            EMIT:if(m_ready)begin
                if(output_position==N)begin init_address<=0;state<=INIT;end
                else output_position<=output_position+1'b1;
            end
            SUMMARY:if(m_ready)begin init_address<=0;state<=INIT;end
            default:begin state<=INIT;init_address<=0;end
        endcase
    end
endmodule
