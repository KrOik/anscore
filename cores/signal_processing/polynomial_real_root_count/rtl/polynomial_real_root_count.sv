// SPDX-License-Identifier: Apache-2.0
`default_nettype none
module polynomial_real_root_count #(
    parameter integer DATA_W=8, MAX_DEG=3, TAG_W=8
)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire signed [DATA_W-1:0] s_c0,s_c1,s_c2,s_c3,s_lower,s_upper,
    input wire [2:0] s_degree, input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg [2:0] m_count, output reg [1:0] m_endpoints,m_status,
    output reg [2:0] m_degree, output reg [TAG_W-1:0] m_tag,
    output reg signed [DATA_W-1:0] m_lower,m_upper
);
    localparam integer W=DATA_W, EW=5*W+7, MW=$clog2(EW);
    localparam [4:0] IDLE=0, VALIDATE=1, CALC_START=2, CALC_SAVE=3,
        MUL_RUN=4, ANALYZE=5, RAT_PREP=6, RAT_LO_START=7,
        RAT_LO_DONE=8, RAT_HI_DONE=9, EVAL_START=10, EVAL_MUL=11,
        EVAL_ADD=12, EVAL_SIGN=13, EVAL_NEXT=14, STURM_COMMIT=15, EMIT=16;
    generate if(W<1 || W>16 || MAX_DEG<1 || MAX_DEG>3 || TAG_W<1 || TAG_W>32)begin:g_invalid
        polynomial_real_root_count_invalid_parameter__see_README reject();
    end endgenerate
    reg [4:0] state,return_state;
    reg [3:0] operation;
    reg signed [EW-1:0] a,b,c,d,aa,bb,cc,delta,temporary,numerator,denominator;
    reg signed [EW-1:0] eval_acc,mul_result;
    reg [EW-1:0] mul_acc,mul_term,mul_factor;
    reg mul_negative;
    reg [MW-1:0] mul_step;
    reg [1:0] poly,eval_index,eval_degree;
    reg endpoint,previous_valid,previous_negative;
    reg [2:0] variations,variation_lower,variation_upper;
    reg rational_second,rational_inside,rational_low_equal;
    wire [EW-1:0] mul_added=mul_acc+(mul_factor[0]?mul_term:{EW{1'b0}});
    wire signed [EW-1:0] lower_ext={{(EW-W){m_lower[W-1]}},m_lower};
    wire signed [EW-1:0] upper_ext={{(EW-W){m_upper[W-1]}},m_upper};
    wire [1:0] last_poly=(m_degree==2 || aa==0)?2:3;
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==EMIT;

    // This is the only data-product engine. All callers obey the EW bound.
    task launch;
        input signed [EW-1:0] left,right;
        input [4:0] destination;
        begin
            mul_acc<=0;mul_term<=left<0?-left:left;
            mul_factor<=right<0?-right:right;mul_negative<=left[EW-1]^right[EW-1];
            mul_step<=0;return_state<=destination;state<=MUL_RUN;
        end
    endtask
    function [1:0] polynomial_degree;
        input [1:0] which;
        begin
            case(which)
                0:polynomial_degree=m_degree[1:0];
                1:polynomial_degree=m_degree[1:0]-1'b1;
                2:polynomial_degree=(m_degree==3 && aa!=0)?1:0;
                default:polynomial_degree=0;
            endcase
        end
    endfunction
    function signed [EW-1:0] coefficient;
        input [1:0] which,index;
        begin
            coefficient=0;
            case(which)
                0:case(index)
                    0:coefficient=a;1:coefficient=b;2:coefficient=c;3:coefficient=d;
                endcase
                1:if(m_degree==3)case(index)
                    0:coefficient=(a<<<1)+a;1:coefficient=b<<<1;2:coefficient=c;
                endcase
                else case(index)
                    0:coefficient=a<<<1;1:coefficient=b;
                endcase
                2:if(m_degree==2)coefficient=a<0?-delta:delta;
                else if(aa==0)coefficient=a<0?-bb:bb;
                else if(index==0)coefficient=a<0?-aa:aa;
                else coefficient=a<0?-bb:bb;
                3:coefficient=cc;
            endcase
        end
    endfunction
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;return_state<=IDLE;operation<=0;
            a<=0;b<=0;c<=0;d<=0;aa<=0;bb<=0;cc<=0;delta<=0;temporary<=0;
            numerator<=0;denominator<=0;eval_acc<=0;mul_result<=0;
            mul_acc<=0;mul_term<=0;mul_factor<=0;mul_negative<=0;mul_step<=0;
            poly<=0;eval_index<=0;eval_degree<=0;endpoint<=0;previous_valid<=0;previous_negative<=0;
            variations<=0;variation_lower<=0;variation_upper<=0;
            rational_second<=0;rational_inside<=0;rational_low_equal<=0;
            m_count<=0;m_endpoints<=0;m_status<=0;m_degree<=0;m_tag<=0;m_lower<=0;m_upper<=0;
        end else case(state)
            IDLE:if(s_valid)begin
                m_degree<=s_degree;m_tag<=s_tag;m_lower<=s_lower;m_upper<=s_upper;
                m_count<=0;m_endpoints<=0;m_status<=0;rational_second<=0;
                aa<=0;bb<=0;cc<=0;delta<=0;
                case(s_degree)
                    0:begin a<=s_c0;b<=0;c<=0;d<=0;end
                    1:begin a<=s_c1;b<=s_c0;c<=0;d<=0;end
                    2:begin a<=s_c2;b<=s_c1;c<=s_c0;d<=0;end
                    default:begin a<=s_c3;b<=s_c2;c<=s_c1;d<=s_c0;end
                endcase
                state<=VALIDATE;
            end
            VALIDATE:begin
                if(m_degree>MAX_DEG)begin m_status<=1;state<=EMIT;end
                else if(m_lower>m_upper)begin m_status<=2;state<=EMIT;end
                else if(a==0)begin m_status<=3;state<=EMIT;end
                else if(m_degree==0)state<=EMIT;
                else if(m_degree==1)begin numerator<=-b;denominator<=a;state<=RAT_PREP;end
                else begin operation<=0;state<=CALC_START;end
            end
            CALC_START:case(operation)
                0:launch(b,b,CALC_SAVE);
                1:launch(a,c,CALC_SAVE);
                2:launch(b,c,CALC_SAVE);
                3:launch(a,d,CALC_SAVE);
                4:launch(bb,bb,CALC_SAVE);
                5:launch(a,temporary,CALC_SAVE);
                6:launch(aa,bb,CALC_SAVE);
                7:launch(b,temporary,CALC_SAVE);
                8:launch(aa,aa,CALC_SAVE);
                9:launch(c,temporary,CALC_SAVE);
                10:launch(a,bb,CALC_SAVE);
                11:launch(b,aa,CALC_SAVE);
                12:launch(a,aa,CALC_SAVE);
                default:state<=IDLE;
            endcase
            CALC_SAVE:begin
                operation<=operation+1'b1;state<=CALC_START;
                case(operation)
                    0:temporary<=mul_result;
                    1:if(m_degree==2)begin delta<=temporary-(mul_result<<<2);state<=ANALYZE;end
                      else aa<=(temporary-((mul_result<<<1)+mul_result))<<<1;
                    2:temporary<=mul_result;
                    3:bb<=temporary-((mul_result<<<3)+mul_result);
                    4:temporary<=mul_result;
                    5:cc<=-((mul_result<<<1)+mul_result);
                    6:temporary<=mul_result;
                    7:cc<=cc+(mul_result<<<1);
                    8:temporary<=mul_result;
                    9:begin cc<=cc-mul_result;state<=ANALYZE;end
                    10:temporary<=mul_result<<<1;
                    11:numerator<=temporary-mul_result;
                    12:begin denominator<=mul_result;state<=RAT_PREP;end
                endcase
            end
            MUL_RUN:begin
                mul_acc<=mul_added;mul_term<=mul_term<<1;mul_factor<=mul_factor>>1;
                if(mul_step==EW-1)begin
                    mul_result<=mul_negative?-$signed(mul_added):$signed(mul_added);state<=return_state;
                end else mul_step<=mul_step+1'b1;
            end
            ANALYZE:begin
                if(m_degree==2 && delta==0)begin
                    numerator<=-b;denominator<=a<<<1;state<=RAT_PREP;
                end else if(m_degree==3 && aa==0 && bb==0)begin
                    numerator<=-b;denominator<=(a<<<1)+a;state<=RAT_PREP;
                end else if(m_degree==3 && aa!=0 && cc==0)begin
                    numerator<=-bb;denominator<=aa;rational_second<=1;state<=RAT_PREP;
                end else begin
                    endpoint<=0;poly<=0;variations<=0;previous_valid<=0;previous_negative<=0;state<=EVAL_START;
                end
            end
            RAT_PREP:begin
                if(denominator<0)begin numerator<=-numerator;denominator<=-denominator;end
                state<=RAT_LO_START;
            end
            RAT_LO_START:launch(lower_ext,denominator,RAT_LO_DONE);
            RAT_LO_DONE:begin
                rational_inside<=numerator>=mul_result;rational_low_equal<=numerator==mul_result;
                launch(upper_ext,denominator,RAT_HI_DONE);
            end
            RAT_HI_DONE:begin
                if(rational_inside && numerator<=mul_result)m_count<=m_count+1'b1;
                m_endpoints<=m_endpoints|{numerator==mul_result,rational_low_equal};
                if(rational_second)begin rational_second<=0;operation<=10;state<=CALC_START;end
                else state<=EMIT;
            end
            EVAL_START:begin
                eval_acc<=coefficient(poly,0);eval_degree<=polynomial_degree(poly);eval_index<=1;
                if(polynomial_degree(poly)==0)state<=EVAL_SIGN;else state<=EVAL_MUL;
            end
            EVAL_MUL:launch(eval_acc,endpoint?upper_ext:lower_ext,EVAL_ADD);
            EVAL_ADD:begin
                eval_acc<=mul_result+coefficient(poly,eval_index);
                if(eval_index==eval_degree)state<=EVAL_SIGN;
                else begin eval_index<=eval_index+1'b1;state<=EVAL_MUL;end
            end
            EVAL_SIGN:begin
                if(poly==0 && eval_acc==0)m_endpoints[endpoint]<=1;
                if(eval_acc!=0)begin
                    if(previous_valid && previous_negative!=eval_acc[EW-1])variations<=variations+1'b1;
                    previous_valid<=1;previous_negative<=eval_acc[EW-1];
                end
                state<=EVAL_NEXT;
            end
            EVAL_NEXT:begin
                if(poly==last_poly)begin
                    if(!endpoint)begin
                        variation_lower<=variations;endpoint<=1;poly<=0;variations<=0;
                        previous_valid<=0;previous_negative<=0;state<=EVAL_START;
                    end else begin variation_upper<=variations;state<=STURM_COMMIT;end
                end else begin poly<=poly+1'b1;state<=EVAL_START;end
            end
            STURM_COMMIT:begin m_count<=variation_lower-variation_upper+{2'b0,m_endpoints[0]};state<=EMIT;end
            EMIT:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
