// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module binary_linear_recurrence #(
    parameter integer MAX_BITS=64,TAG_W=8,
    localparam integer COUNT_W=($clog2(MAX_BITS+1)<1)?1:$clog2(MAX_BITS+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire s_bit,s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [COUNT_W-1:0] m_count,m_order,
    output wire [MAX_BITS:0] m_connection,
    output reg m_next,output wire [TAG_W-1:0] m_tag,
    output reg [1:0] m_errors
);
    localparam integer CW=COUNT_W;
    localparam [2:0] COLLECT=0,TAP_READ=1,TAP_EVAL=2,UPDATE=3,
        FINALIZE=4,PRED_READ=5,PRED_EVAL=6,EMIT=7;
    reg [2:0] state;
    reg started,overflow,tail_q,discrepancy,predictor;
    reg [CW-1:0] count,order_q,index_q,tap;
    reg [MAX_BITS:0] connection,auxiliary;
    reg [TAG_W-1:0] tag_q;
    reg history[0:MAX_BITS-1];
    reg read_q;
    wire [CW:0] twice_order={1'b0,order_q}<<1;
    wire jump=twice_order<={1'b0,index_q};
    wire [1:0] final_errors={overflow,count==0};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;assign m_order=order_q;
    assign m_connection=connection;assign m_tag=tag_q;

    // One synchronous read port; taps only address previously written samples.
    // Collection writes and tap/prediction reads occupy disjoint states.
    always @(posedge clk)if(!rst)begin
        if(state==COLLECT && s_valid && s_ready && s_keep && count<MAX_BITS)
            history[count]<=s_bit;
        if(state==TAP_READ)read_q<=history[index_q-tap];
        if(state==PRED_READ)read_q<=history[count-tap];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;started<=0;overflow<=0;tail_q<=0;discrepancy<=0;predictor<=0;
            count<=0;order_q<=0;index_q<=0;tap<=0;tag_q<=0;
            connection<={{MAX_BITS{1'b0}},1'b1};
            auxiliary<=({{MAX_BITS{1'b0}},1'b1}<<1);
            m_next<=0;m_errors<=0;
        end else case(state)
            COLLECT: if(s_valid && s_ready)begin
                if(!started)begin started<=1;tag_q<=s_tag;end
                if(s_keep && count<MAX_BITS)begin
                    index_q<=count;count<=count+1'b1;discrepancy<=s_bit;
                    tail_q<=s_last;tap<={{(CW-1){1'b0}},1'b1};
                    state<=(order_q==0)?UPDATE:TAP_READ;
                end else begin
                    if(s_keep)overflow<=1;
                    if(s_last)state<=FINALIZE;
                end
            end
            TAP_READ: state<=TAP_EVAL;
            TAP_EVAL: begin
                discrepancy<=discrepancy^(connection[tap]&read_q);
                if(tap==order_q)state<=UPDATE;
                else begin tap<=tap+1'b1;state<=TAP_READ;end
            end
            UPDATE: begin
                if(discrepancy)connection<=connection^auxiliary;
                if(discrepancy && jump)begin
                    order_q<=index_q+1'b1-order_q;
                    // Nonblocking RHS is old C, before the discrepancy XOR.
                    auxiliary<=connection<<1;
                end else auxiliary<=auxiliary<<1;
                state<=tail_q?FINALIZE:COLLECT;
            end
            FINALIZE: begin
                m_errors<=final_errors;m_next<=0;predictor<=0;
                tap<={{(CW-1){1'b0}},1'b1};
                if(final_errors!=0)begin order_q<=0;connection<=0;state<=EMIT;end
                else if(order_q==0)state<=EMIT;
                else state<=PRED_READ;
            end
            PRED_READ: state<=PRED_EVAL;
            PRED_EVAL: begin
                predictor<=predictor^(connection[tap]&read_q);
                if(tap==order_q)begin
                    m_next<=predictor^(connection[tap]&read_q);state<=EMIT;
                end else begin tap<=tap+1'b1;state<=PRED_READ;end
            end
            EMIT: if(m_ready)begin
                state<=COLLECT;started<=0;overflow<=0;tail_q<=0;discrepancy<=0;predictor<=0;
                count<=0;order_q<=0;index_q<=0;tap<=0;
                connection<={{MAX_BITS{1'b0}},1'b1};
                auxiliary<=({{MAX_BITS{1'b0}},1'b1}<<1);
            end
            default: state<=COLLECT;
        endcase
    end
    generate if(MAX_BITS<1 || MAX_BITS>256 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        binary_linear_recurrence_invalid_parameters invalid();
    end endgenerate
endmodule
`default_nettype wire
