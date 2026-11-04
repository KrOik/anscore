// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module integer_polynomial_resultant #(
    parameter integer DATA_W=8,MAX_DEG=2,TAG_W=8,
    localparam integer COUNT_W=($clog2(MAX_DEG+3)<1)?1:$clog2(MAX_DEG+3),
    localparam integer RESULT_W=2*MAX_DEG*DATA_W+$clog2(MAX_DEG==1?2:MAX_DEG==2?24:720)+1
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_a,s_b,
    input wire [2:0] s_degree_a,s_degree_b,
    input wire s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [COUNT_W-1:0] m_count,
    output wire [2:0] m_degree_a,m_degree_b,
    output wire [TAG_W-1:0] m_tag,output reg [1:0] m_status,
    output reg signed [RESULT_W-1:0] m_resultant,output reg m_common_root
);
    localparam integer W=DATA_W,NB=RESULT_W,CW=COUNT_W,MAX_N=2*MAX_DEG,
        AW=($clog2(MAX_N)<1)?1:$clog2(MAX_N),
        RW=($clog2(MAX_N+1)<1)?1:$clog2(MAX_N+1),
        SW=($clog2(W)<1)?1:$clog2(W);
    localparam [3:0] COLLECT=0,FINALIZE=1,INITIALIZE=2,TERM_START=3,
        FACTOR_READ=4,FACTOR_SETUP=5,MUL_RUN=6,FACTOR_NEXT=7,
        TERM_ADD=8,NEXT_PERM=9,COMMIT=10,EMIT=11;
    reg [3:0] state;
    reg started,zero_lead_a,zero_lead_b,odd_permutation,mul_negative,present_q,select_b_q;
    reg [CW-1:0] count;
    reg [2:0] degree_a,degree_b;
    reg [RW-1:0] dimension,row,heap_i;
    reg [SW-1:0] mul_step;
    reg [TAG_W-1:0] tag_q;
    reg [2*W-1:0] coefficients[0:MAX_DEG];
    reg [2*W-1:0] coefficient_q;
    // These two tiny bounded banks are registers, initialized before use.
    reg [AW-1:0] permutation[0:MAX_N-1],heap_count[0:MAX_N-1];
    reg signed [NB-1:0] term,sum;
    reg [NB-1:0] mul_acc,mul_term;
    reg [W-1:0] mul_factor;
    wire [3:0] required_beats=(degree_a>degree_b?{1'b0,degree_a}:{1'b0,degree_b})+1'b1;
    wire select_b=row>=degree_b;
    wire [RW:0] shift_row=select_b ? row-degree_b : row;
    wire [RW:0] column={1'b0,permutation[row]};
    wire [2:0] selected_degree=select_b ? degree_b : degree_a;
    wire factor_present=column>=shift_row && column<=shift_row+selected_degree;
    wire [RW:0] coefficient_index=selected_degree-(column-shift_row);
    wire [1:0] read_index=factor_present ? coefficient_index[1:0] : 2'b00;
    wire signed [W-1:0] selected_coefficient=select_b_q ? coefficient_q[W-1:0] : coefficient_q[2*W-1:W];
    wire signed [W-1:0] factor=present_q ? selected_coefficient : {W{1'b0}};
    wire [W-1:0] factor_magnitude=factor[W-1] ? -$unsigned(factor) : $unsigned(factor);
    wire [NB-1:0] mul_total=mul_acc+(mul_factor[0]?mul_term:{NB{1'b0}});
    wire [AW-1:0] heap_slot=(heap_i<MAX_N)?heap_i[AW-1:0]:{AW{1'b0}};
    wire [AW-1:0] swap_slot=heap_i[0]?heap_count[heap_slot]:{AW{1'b0}};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;assign m_degree_a=degree_a;assign m_degree_b=degree_b;assign m_tag=tag_q;
    generate if(DATA_W<1 || DATA_W>16 || MAX_DEG<1 || MAX_DEG>3 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        integer_polynomial_resultant_invalid_parameters invalid();
    end endgenerate
    integer k;
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;started<=0;zero_lead_a<=1;zero_lead_b<=1;odd_permutation<=0;
            mul_negative<=0;present_q<=0;select_b_q<=0;count<=0;degree_a<=0;degree_b<=0;
            dimension<=0;row<=0;heap_i<=0;mul_step<=0;tag_q<=0;coefficient_q<=0;
            term<=0;sum<=0;mul_acc<=0;mul_term<=0;mul_factor<=0;
            m_status<=0;m_resultant<=0;m_common_root<=0;
        end else case(state)
            COLLECT:if(s_valid)begin
                if(!started)begin
                    started<=1;degree_a<=s_degree_a;degree_b<=s_degree_b;tag_q<=s_tag;
                    if(s_degree_a==0)zero_lead_a<=s_a==0;
                    if(s_degree_b==0)zero_lead_b<=s_b==0;
                end else begin
                    if(count==degree_a)zero_lead_a<=s_a==0;
                    if(count==degree_b)zero_lead_b<=s_b==0;
                end
                if(count<=MAX_DEG)coefficients[count]<={s_a,s_b};
                if(count<MAX_DEG+2)count<=count+1'b1;
                if(s_last)state<=FINALIZE;
            end
            FINALIZE:begin
                m_resultant<=0;m_common_root<=0;
                if(degree_a>MAX_DEG || degree_b>MAX_DEG)begin m_status<=1;state<=EMIT;end
                else if(count!=required_beats)begin m_status<=2;state<=EMIT;end
                else if(zero_lead_a || zero_lead_b)begin m_status<=3;state<=EMIT;end
                else begin
                    m_status<=0;dimension<=degree_a+degree_b;
                    if(degree_a==0 && degree_b==0)begin m_resultant<=1;state<=EMIT;end
                    else state<=INITIALIZE;
                end
            end
            INITIALIZE:begin
                for(k=0;k<MAX_N;k=k+1)begin permutation[k]<=k;heap_count[k]<=0;end
                sum<=0;odd_permutation<=0;heap_i<=1;state<=TERM_START;
            end
            TERM_START:begin term<={{(NB-1){1'b0}},1'b1};row<=0;state<=FACTOR_READ;end
            FACTOR_READ:begin
                coefficient_q<=coefficients[read_index];present_q<=factor_present;select_b_q<=select_b;
                state<=FACTOR_SETUP;
            end
            FACTOR_SETUP:begin
                mul_acc<=0;mul_term<=term[NB-1] ? -term : term;
                mul_factor<=factor_magnitude;mul_negative<=term[NB-1]^factor[W-1];
                mul_step<=0;state<=MUL_RUN;
            end
            MUL_RUN:begin
                mul_acc<=mul_total;mul_term<=mul_term<<1;mul_factor<=mul_factor>>1;
                if(mul_step==W-1)begin term<=mul_negative ? -mul_total : mul_total;state<=FACTOR_NEXT;end
                else mul_step<=mul_step+1'b1;
            end
            FACTOR_NEXT:begin
                if(row+1'b1<dimension)begin row<=row+1'b1;state<=FACTOR_READ;end
                else state<=TERM_ADD;
            end
            TERM_ADD:begin
                sum<=odd_permutation ? sum-term : sum+term;
                heap_i<=1;state<=NEXT_PERM;
            end
            NEXT_PERM:begin
                if(heap_i>=dimension)state<=COMMIT;
                else if(heap_count[heap_slot]<heap_i)begin
                    permutation[swap_slot]<=permutation[heap_slot];permutation[heap_slot]<=permutation[swap_slot];
                    heap_count[heap_slot]<=heap_count[heap_slot]+1'b1;
                    odd_permutation<=~odd_permutation;state<=TERM_START;
                end else begin heap_count[heap_slot]<=0;heap_i<=heap_i+1'b1;end
            end
            COMMIT:begin m_resultant<=sum;m_common_root<=sum==0;state<=EMIT;end
            EMIT:if(m_ready)begin
                state<=COLLECT;started<=0;count<=0;zero_lead_a<=1;zero_lead_b<=1;
            end
            default:state<=COLLECT;
        endcase
    end
endmodule
`default_nettype wire
