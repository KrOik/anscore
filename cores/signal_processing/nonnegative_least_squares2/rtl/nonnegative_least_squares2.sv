// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Exact two-component NNLS from raw signed sample rows, full-column-rank domain.
module nonnegative_least_squares2 #(
    parameter integer DATA_W=8,MAX_SAMPLES=16,TAG_W=8
)(
    input wire clk,rst,input wire s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_a0,s_a1,s_b,
    input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [4*DATA_W+2*$clog2(MAX_SAMPLES)+3:0] m_num_x,m_num_y,m_denominator,
    output reg signed [4*DATA_W+2*$clog2(MAX_SAMPLES)+3:0] m_determinant,
    output wire [$clog2(MAX_SAMPLES+1)-1:0] m_count,
    output reg [1:0] m_positive,m_status,output reg [TAG_W-1:0] m_tag
);
    localparam integer W=DATA_W,N=MAX_SAMPLES,IW=$clog2(N),CW=$clog2(N+1),
        EW=4*W+2*$clog2(N)+4,MW=$clog2(EW);
    localparam [3:0] COLLECT=0,CHECK=1,READ=2,SAMPLE_START=3,MUL_RUN=4,
        SAMPLE_SAVE=5,WIDE_START=6,WIDE_SAVE=7,SELECT=8,EMIT=9;
    generate if(W<1 || W>16 || N<2 || N>16 || TAG_W<1 || TAG_W>32)begin:g_invalid
        nonnegative_least_squares2_invalid_parameter__see_README reject();
    end endgenerate
    reg [3*W-1:0] rows[0:N-1];
    reg [3*W-1:0] row_q;
    reg [3:0] state,return_state;
    reg [2:0] operation;
    reg [IW-1:0] row_index;
    reg [CW-1:0] count;
    reg started,overflow;
    reg signed [EW-1:0] g00,g11,g01,h0,h1,temporary,numerator_x,numerator_y,mul_result;
    reg [EW-1:0] mul_acc,mul_term,mul_factor;
    reg [MW-1:0] mul_step,mul_limit;
    reg mul_negative;
    wire signed [W-1:0] a0=row_q[3*W-1:2*W],a1=row_q[2*W-1:W],rhs=row_q[W-1:0];
    wire signed [EW-1:0] a0_ext={{(EW-W){a0[W-1]}},a0};
    wire signed [EW-1:0] a1_ext={{(EW-W){a1[W-1]}},a1};
    wire signed [EW-1:0] rhs_ext={{(EW-W){rhs[W-1]}},rhs};
    wire [EW-1:0] mul_added=mul_acc+(mul_factor[0]?mul_term:{EW{1'b0}});
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;
    // No RAM reset. Every read belongs to the newly captured kept prefix.
    always @(posedge clk)if(!rst)begin
        if(state==COLLECT && s_valid && s_keep && count<N)rows[count[IW-1:0]]<={s_a0,s_a1,s_b};
        if(state==READ)row_q<=rows[row_index];
    end
    task launch;
        input signed [EW-1:0] left,right;
        input [MW-1:0] iterations;
        input [3:0] destination;
        begin
            mul_acc<=0;mul_term<=left<0?-left:left;mul_factor<=right<0?-right:right;
            mul_negative<=left[EW-1]^right[EW-1];mul_step<=0;mul_limit<=iterations;
            return_state<=destination;state<=MUL_RUN;
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;return_state<=COLLECT;operation<=0;row_index<=0;count<=0;
            started<=0;overflow<=0;g00<=0;g11<=0;g01<=0;h0<=0;h1<=0;
            temporary<=0;numerator_x<=0;numerator_y<=0;mul_result<=0;
            mul_acc<=0;mul_term<=0;mul_factor<=0;mul_step<=0;mul_limit<=0;mul_negative<=0;
            m_num_x<=0;m_num_y<=0;m_denominator<=0;m_determinant<=0;
            m_positive<=0;m_status<=0;m_tag<=0;
        end else case(state)
            COLLECT:if(s_valid)begin
                if(!started)begin
                    started<=1;m_tag<=s_tag;m_status<=0;m_positive<=0;
                    m_num_x<=0;m_num_y<=0;m_denominator<=0;m_determinant<=0;
                    g00<=0;g11<=0;g01<=0;h0<=0;h1<=0;
                end
                if(s_keep)begin
                    if(count<N)count<=count+1'b1;else overflow<=1;
                end
                if(s_last)state<=CHECK;
            end
            CHECK:begin
                if(overflow)begin m_status<=2;state<=EMIT;end
                else if(count==0)begin m_status<=1;state<=EMIT;end
                else begin row_index<=0;operation<=0;state<=READ;end
            end
            READ:state<=SAMPLE_START;
            SAMPLE_START:case(operation)
                0:launch(a0_ext,a0_ext,W,SAMPLE_SAVE);
                1:launch(a1_ext,a1_ext,W,SAMPLE_SAVE);
                2:launch(a0_ext,a1_ext,W,SAMPLE_SAVE);
                3:launch(a0_ext,rhs_ext,W,SAMPLE_SAVE);
                4:launch(a1_ext,rhs_ext,W,SAMPLE_SAVE);
                default:state<=COLLECT;
            endcase
            MUL_RUN:begin
                mul_acc<=mul_added;mul_term<=mul_term<<1;mul_factor<=mul_factor>>1;
                if(mul_step==mul_limit-1'b1)begin
                    mul_result<=mul_negative?-$signed(mul_added):$signed(mul_added);state<=return_state;
                end else mul_step<=mul_step+1'b1;
            end
            SAMPLE_SAVE:begin
                case(operation)
                    0:g00<=g00+mul_result;1:g11<=g11+mul_result;2:g01<=g01+mul_result;
                    3:h0<=h0+mul_result;4:h1<=h1+mul_result;
                endcase
                if(operation==4)begin
                    operation<=0;
                    if(row_index==count-1'b1)state<=WIDE_START;
                    else begin row_index<=row_index+1'b1;state<=READ;end
                end else begin operation<=operation+1'b1;state<=SAMPLE_START;end
            end
            WIDE_START:case(operation)
                0:launch(g00,g11,EW,WIDE_SAVE);
                1:launch(g01,g01,EW,WIDE_SAVE);
                2:launch(h0,g11,EW,WIDE_SAVE);
                3:launch(h1,g01,EW,WIDE_SAVE);
                4:launch(h1,g00,EW,WIDE_SAVE);
                5:launch(h0,g01,EW,WIDE_SAVE);
                default:state<=COLLECT;
            endcase
            WIDE_SAVE:begin
                case(operation)
                    0:temporary<=mul_result;1:m_determinant<=temporary-mul_result;
                    2:temporary<=mul_result;3:numerator_x<=temporary-mul_result;
                    4:temporary<=mul_result;5:numerator_y<=temporary-mul_result;
                endcase
                if(operation==5)state<=SELECT;
                else begin operation<=operation+1'b1;state<=WIDE_START;end
            end
            SELECT:begin
                if(m_determinant==0)begin m_status<=3;end
                else if(numerator_x>=0 && numerator_y>=0)begin
                    m_num_x<=numerator_x;m_num_y<=numerator_y;m_denominator<=m_determinant;
                    m_positive<={numerator_y>0,numerator_x>0};
                end else if(h0>0 && numerator_y<=0)begin
                    m_num_x<=h0;m_num_y<=0;m_denominator<=g00;m_positive<=1;
                end else if(h1>0 && numerator_x<=0)begin
                    m_num_x<=0;m_num_y<=h1;m_denominator<=g11;m_positive<=2;
                end else begin m_num_x<=0;m_num_y<=0;m_denominator<=1;m_positive<=0;end
                state<=EMIT;
            end
            EMIT:if(m_ready)begin state<=COLLECT;started<=0;count<=0;overflow<=0;end
            default:begin state<=COLLECT;started<=0;count<=0;overflow<=0;end
        endcase
    end
endmodule
`default_nettype wire
