// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module rational_polynomial_interpolate #(
    parameter integer DATA_W=8,MAX_LEN=4,TAG_W=8,
    localparam integer COUNT_W=($clog2(MAX_LEN+1)<1)?1:$clog2(MAX_LEN+1),
    localparam integer DEN_W=(DATA_W*MAX_LEN*(MAX_LEN-1)/2<1)?1:DATA_W*MAX_LEN*(MAX_LEN-1)/2,
    localparam integer NUM_W=DATA_W*(MAX_LEN*(MAX_LEN-1)/2+1)+$clog2(MAX_LEN)+1
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_x,s_y,s_query,
    input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [COUNT_W-1:0] m_count,output wire signed [DATA_W-1:0] m_query,
    output wire [TAG_W-1:0] m_tag,output reg [2:0] m_errors,
    output reg signed [NUM_W-1:0] m_numerator,output reg [DEN_W-1:0] m_denominator
);
    localparam integer W=DATA_W,CW=COUNT_W,NB=NUM_W,DB=DEN_W,
        SW=($clog2(W)<1)?1:$clog2(W);
    localparam [3:0] COLLECT=0,FINALIZE=1,PAIR_A=2,PAIR_B=3,PAIR_FACTOR=4,
        MUL_RUN=5,PAIR_NEXT=6,DEN_FINISH=7,TERM_READ=8,TERM_SETUP=9,
        Q_READ=10,Q_FACTOR=11,Q_NEXT=12,TERM_ADD=13,COMMIT=14,EMIT=15;
    reg [3:0] state;
    reg started,overflow,duplicate,numerator_role,mul_query,mul_negative,v_negative;
    reg [CW-1:0] count,pair_a,pair_b,term_i,query_i;
    reg [SW-1:0] mul_step;
    reg [TAG_W-1:0] tag_q;
    reg signed [W-1:0] query_q,pair_x;
    reg [2*W-1:0] samples[0:MAX_LEN-1];
    reg [2*W-1:0] sample_q;
    reg signed [NB-1:0] term,sum;
    reg [NB-1:0] mul_acc,mul_term;
    reg [W-1:0] mul_factor;
    wire signed [W-1:0] read_x=sample_q[2*W-1:W],read_y=sample_q[W-1:0];
    // W+1 signed subtraction preserves both signed input extrema.
    wire signed [W:0] pair_difference=$signed({read_x[W-1],read_x})-$signed({pair_x[W-1],pair_x});
    wire signed [W:0] query_difference=$signed({query_q[W-1],query_q})-$signed({read_x[W-1],read_x});
    wire signed [W:0] pair_factor=(numerator_role && (pair_a==term_i || pair_b==term_i))?
        {{W{1'b0}},1'b1}:pair_difference;
    wire signed [W:0] query_factor=(query_i==term_i)?{{W{1'b0}},1'b1}:query_difference;
    wire [W:0] pair_magnitude=pair_factor[W] ? -pair_factor : pair_factor;
    wire [W:0] query_magnitude=query_factor[W] ? -query_factor : query_factor;
    wire [NB-1:0] mul_total=mul_acc+(mul_factor[0]?mul_term:{NB{1'b0}});
    wire signed [NB-1:0] y_extended={{(NB-W){read_y[W-1]}},read_y};
    wire [CW-1:0] parity_index=count-1'b1-term_i;
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;assign m_tag=tag_q;assign m_query=query_q;
    generate if(DATA_W<1 || DATA_W>16 || MAX_LEN<2 || MAX_LEN>6 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        rational_polynomial_interpolate_invalid_parameters invalid();
    end endgenerate
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;started<=0;overflow<=0;duplicate<=0;numerator_role<=0;
            mul_query<=0;mul_negative<=0;v_negative<=0;count<=0;pair_a<=0;pair_b<=0;
            term_i<=0;query_i<=0;mul_step<=0;tag_q<=0;query_q<=0;pair_x<=0;sample_q<=0;
            term<=0;sum<=0;mul_acc<=0;mul_term<=0;mul_factor<=0;
            m_errors<=0;m_numerator<=0;m_denominator<=0;
        end else case(state)
            COLLECT:if(s_valid)begin
                if(!started)begin started<=1;tag_q<=s_tag;query_q<=s_query;end
                if(s_keep)begin
                    if(count<MAX_LEN)begin samples[count]<={s_x,s_y};count<=count+1'b1;end
                    else overflow<=1;
                end
                if(s_last)state<=FINALIZE;
            end
            FINALIZE:begin
                term<={{(NB-1){1'b0}},1'b1};sum<=0;pair_a<=0;pair_b<=1;
                numerator_role<=0;
                if(count==0)begin m_errors<=1;m_numerator<=0;m_denominator<=0;state<=EMIT;end
                else if(count==1)state<=DEN_FINISH;
                else state<=PAIR_A;
            end
            PAIR_A:begin sample_q<=samples[pair_a];state<=PAIR_B;end
            PAIR_B:begin pair_x<=read_x;sample_q<=samples[pair_b];state<=PAIR_FACTOR;end
            PAIR_FACTOR:begin
                if(!numerator_role && pair_difference==0)duplicate<=1;
                mul_acc<=0;mul_term<=term[NB-1] ? -term : term;
                mul_factor<=pair_magnitude[W-1:0];mul_negative<=term[NB-1]^pair_factor[W];
                mul_step<=0;mul_query<=0;state<=MUL_RUN;
            end
            MUL_RUN:begin
                mul_acc<=mul_total;mul_term<=mul_term<<1;mul_factor<=mul_factor>>1;
                if(mul_step==W-1)begin
                    term<=mul_negative ? -mul_total : mul_total;
                    state<=mul_query?Q_NEXT:PAIR_NEXT;
                end else mul_step<=mul_step+1'b1;
            end
            PAIR_NEXT:begin
                if(pair_b+1'b1<count)begin pair_b<=pair_b+1'b1;state<=PAIR_A;end
                else if(pair_a+2<count)begin pair_a<=pair_a+1'b1;pair_b<=pair_a+2;state<=PAIR_A;end
                else state<=numerator_role?TERM_ADD:DEN_FINISH;
            end
            DEN_FINISH:begin
                if(overflow || duplicate)begin
                    m_errors<={overflow,duplicate,1'b0};m_numerator<=0;m_denominator<=0;state<=EMIT;
                end else begin
                    m_errors<=0;m_denominator<=term[NB-1] ? -term : term;
                    v_negative<=term[NB-1];term_i<=0;numerator_role<=1;state<=TERM_READ;
                end
            end
            TERM_READ:begin sample_q<=samples[term_i];state<=TERM_SETUP;end
            TERM_SETUP:begin
                term<=parity_index[0] ? -y_extended : y_extended;
                query_i<=0;state<=Q_READ;
            end
            Q_READ:begin sample_q<=samples[query_i];state<=Q_FACTOR;end
            Q_FACTOR:begin
                mul_acc<=0;mul_term<=term[NB-1] ? -term : term;
                mul_factor<=query_magnitude[W-1:0];mul_negative<=term[NB-1]^query_factor[W];
                mul_step<=0;mul_query<=1;state<=MUL_RUN;
            end
            Q_NEXT:begin
                if(query_i+1'b1<count)begin query_i<=query_i+1'b1;state<=Q_READ;end
                else if(count==1)state<=TERM_ADD;
                else begin pair_a<=0;pair_b<=1;state<=PAIR_A;end
            end
            TERM_ADD:begin
                sum<=sum+term;
                if(term_i+1'b1<count)begin term_i<=term_i+1'b1;state<=TERM_READ;end
                else state<=COMMIT;
            end
            COMMIT:begin m_numerator<=v_negative ? -sum : sum;state<=EMIT;end
            EMIT:if(m_ready)begin
                state<=COLLECT;started<=0;count<=0;overflow<=0;duplicate<=0;
            end
            default:state<=COLLECT;
        endcase
    end
endmodule
`default_nettype wire
