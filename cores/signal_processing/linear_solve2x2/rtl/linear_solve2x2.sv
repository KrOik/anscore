// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Exact integer 2x2 Cramer's numerators; final fixed-point division only.
module linear_solve2x2 #(
    parameter integer W=16,
    parameter integer FRAC=16,
    parameter integer RESULT_W=32,
    parameter integer TAG_W=8
) (
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire signed [W-1:0] s_a00, s_a01, s_a10, s_a11, s_b0, s_b1,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg signed [RESULT_W-1:0] m_x, m_y,
    output reg signed [2*W:0] m_determinant,
    output reg m_singular,
    output reg [1:0] m_saturated,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer PW=2*W+1;
    localparam integer DW=PW+FRAC;
    localparam integer QW=(DW>RESULT_W)?DW:RESULT_W;
    localparam integer MCW=$clog2(W+1);
    localparam integer DCW=$clog2(DW+1);
    localparam [2:0] IDLE=0, MUL_SETUP=1, MUL_RUN=2,
        DIV_SETUP=3, DIV_RUN=4, EMIT=5;
    generate if(W<2 || W>24 || FRAC<0 || FRAC>24 || RESULT_W<2 ||
                RESULT_W>64 || TAG_W<1 || TAG_W>32) begin : g_invalid
        linear_solve2x2_invalid_parameter__see_README invalid_configuration();
    end endgenerate

    reg [2:0] state, operation;
    reg signed [W-1:0] a00,a01,a10,a11,b0,b1;
    reg signed [W-1:0] mul_left,mul_right;
    reg [2*W-1:0] mul_shift,mul_acc;
    reg [W-1:0] mul_factor;
    reg [MCW-1:0] mul_step;
    reg mul_negative;
    reg signed [PW-1:0] first_product,numerator_x,numerator_y;
    wire [2*W-1:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:{(2*W){1'b0}});
    wire signed [PW-1:0] product_signed=mul_negative ?
        -$signed({1'b0,mul_next}) : $signed({1'b0,mul_next});
    wire signed [PW-1:0] difference=first_product-product_signed;
    wire [W-1:0] left_abs=mul_left[W-1] ? -$unsigned(mul_left) : $unsigned(mul_left);
    wire [W-1:0] right_abs=mul_right[W-1] ? -$unsigned(mul_right) : $unsigned(mul_right);

    reg axis,div_negative;
    reg [PW-1:0] divisor;
    reg [DW-1:0] dividend,quotient;
    reg [PW:0] remainder;
    reg [DCW-1:0] div_step;
    wire signed [PW-1:0] selected_numerator=axis?numerator_y:numerator_x;
    wire [PW-1:0] numerator_abs=selected_numerator[PW-1] ?
        -$unsigned(selected_numerator) : $unsigned(selected_numerator);
    wire [PW-1:0] determinant_abs=m_determinant[PW-1] ?
        -$unsigned(m_determinant) : $unsigned(m_determinant);
    wire [PW:0] trial={remainder[PW-1:0],dividend[DW-1]};
    wire take_bit=trial>={1'b0,divisor};
    wire [DW-1:0] quotient_next={quotient[DW-2:0],take_bit};
    wire [QW-1:0] quotient_wide=quotient_next;
    wire [QW-1:0] positive_limit={{(QW-RESULT_W){1'b0}},1'b0,{(RESULT_W-1){1'b1}}};
    wire [QW-1:0] negative_limit={{(QW-RESULT_W){1'b0}},1'b1,{(RESULT_W-1){1'b0}}};
    wire result_clamped=div_negative ? quotient_wide>negative_limit : quotient_wide>positive_limit;
    wire signed [RESULT_W-1:0] signed_result=result_clamped ?
        (div_negative ? {1'b1,{(RESULT_W-1){1'b0}}} : {1'b0,{(RESULT_W-1){1'b1}}}) :
        (div_negative ? -$signed(quotient_wide[RESULT_W-1:0]) : $signed(quotient_wide[RESULT_W-1:0]));
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==EMIT;

    always @* begin
        mul_left=a00; mul_right=a11;
        case(operation)
            1: begin mul_left=a01; mul_right=a10; end
            2: begin mul_left=b0;  mul_right=a11; end
            3: begin mul_left=a01; mul_right=b1;  end
            4: begin mul_left=a00; mul_right=b1;  end
            5: begin mul_left=b0;  mul_right=a10; end
            default: begin end
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; operation<=0; axis<=0;
            a00<=0;a01<=0;a10<=0;a11<=0;b0<=0;b1<=0;
            m_x<=0;m_y<=0;m_determinant<=0;m_singular<=0;m_saturated<=0;m_tag<=0;
        end else case(state)
            IDLE: if(s_valid) begin
                a00<=s_a00;a01<=s_a01;a10<=s_a10;a11<=s_a11;b0<=s_b0;b1<=s_b1;
                m_tag<=s_tag;m_x<=0;m_y<=0;m_singular<=0;m_saturated<=0;
                operation<=0;state<=MUL_SETUP;
            end
            MUL_SETUP: begin
                mul_acc<=0;mul_shift<=left_abs;mul_factor<=right_abs;
                mul_negative<=mul_left[W-1]^mul_right[W-1];mul_step<=0;state<=MUL_RUN;
            end
            MUL_RUN: begin
                mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
                if(mul_step==W-1) begin
                    if(!operation[0]) first_product<=product_signed;
                    case(operation)
                        1: begin
                            m_determinant<=difference;
                            if(difference==0) begin m_singular<=1;state<=EMIT;end
                            else state<=MUL_SETUP;
                        end
                        3: begin numerator_x<=difference;state<=MUL_SETUP;end
                        5: begin numerator_y<=difference;axis<=0;state<=DIV_SETUP;end
                        default: state<=MUL_SETUP;
                    endcase
                    operation<=operation+1'b1;
                end else mul_step<=mul_step+1'b1;
            end
            DIV_SETUP: begin
                divisor<=determinant_abs;dividend<={numerator_abs,{FRAC{1'b0}}};
                quotient<=0;remainder<=0;div_step<=0;
                div_negative<=selected_numerator[PW-1]^m_determinant[PW-1];state<=DIV_RUN;
            end
            DIV_RUN: begin
                dividend<=dividend<<1;quotient<=quotient_next;
                remainder<=take_bit ? trial-{1'b0,divisor} : trial;
                if(div_step==DW-1) begin
                    if(!axis) begin m_x<=signed_result;m_saturated[0]<=result_clamped;axis<=1;state<=DIV_SETUP;end
                    else begin m_y<=signed_result;m_saturated[1]<=result_clamped;state<=EMIT;end
                end else div_step<=div_step+1'b1;
            end
            EMIT: if(m_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
