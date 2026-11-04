`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Uniform-block SSIM, population covariance, K1=1/100 and K2=3/100.
module stream_ssim #(
    parameter integer BITS=8,
    parameter integer MAX_SAMPLES=64,
    parameter integer Q_BITS=15,
    parameter integer TAG_W=8,
    localparam integer CW=$clog2(MAX_SAMPLES+1),
    localparam integer SW=BITS+CW,
    localparam integer PW=2*BITS+CW,
    localparam integer MW=2*SW+18,
    localparam integer NW=2*MW,
    localparam integer DW=NW+Q_BITS,
    localparam integer MCW=$clog2(MW+1),
    localparam integer DCW=$clog2(DW+1)
)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire [BITS-1:0] s_x, s_y,
    input wire s_mask, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg signed [Q_BITS+1:0] m_score,
    output reg [CW-1:0] m_count,
    output reg m_empty, m_overflow,
    output reg [TAG_W-1:0] m_tag
);
    localparam [3:0] INPUT_PAIR=0, PIX_XX=1, PIX_YY=2, PIX_XY=3,
        BLOCK_END=4, MUL_START=5, MUL_RUN=6, FORM=7,
        DIV_START=8, DIV_RUN=9, EMIT=10;
    localparam [BITS-1:0] PEAK={BITS{1'b1}};
    localparam [2*BITS-1:0] PEAK2=PEAK*PEAK;
    reg [3:0] state, operation;
    reg [CW-1:0] count;
    reg [SW-1:0] sx,sy;
    reg [PW-1:0] sxx,syy,sxy;
    reg [BITS-1:0] px,py;
    reg last_pair, started, overflow;
    reg [TAG_W-1:0] tag;
    // One explicitly shared BITS-by-BITS multiplier; input II is four clocks.
    wire [BITS-1:0] small_a=(state==PIX_YY)?py:px;
    wire [BITS-1:0] small_b=(state==PIX_XX)?px:py;
    wire [2*BITS-1:0] small_product=small_a*small_b;

    reg [2*SW-1:0] xx,yy,xy,nxx,nyy,nxy,nn;
    reg [MW-1:0] base,a_term,c_term,d_term;
    reg signed [MW-1:0] b_term;
    // Wide products share one shift/add engine, with no wide '*' operator.
    reg [NW-1:0] mul_a,mul_acc;
    reg [MW-1:0] mul_b;
    reg [MCW-1:0] mul_step;
    wire [NW-1:0] mul_next=mul_acc+(mul_b[0]?mul_a:{NW{1'b0}});
    reg [NW-1:0] numerator,denominator;
    reg negative;
    reg [DW-1:0] dividend,quotient;
    reg [NW:0] remainder;
    reg [DCW-1:0] div_step;
    wire [NW:0] trial={remainder[NW-1:0],dividend[DW-1]};
    wire take_bit=trial>={1'b0,denominator};
    wire [DW-1:0] quotient_next={quotient[DW-2:0],take_bit};
    wire [MW-1:0] xx_w=xx, yy_w=yy, xy_w=xy;
    wire [MW-1:0] nxx_w=nxx, nyy_w=nyy, nxy_w=nxy;
    wire signed [MW-1:0] covariance=$signed(nxy_w)-$signed(xy_w);
    wire [MW-1:0] variance_sum=nxx_w+nyy_w-xx_w-yy_w;
    wire [MW-1:0] b_abs=b_term[MW-1] ? -b_term : b_term;
    assign s_ready=!rst && state==INPUT_PAIR;
    assign m_valid=!rst && state==EMIT;
`ifndef SYNTHESIS
    initial begin
        if(BITS<1 || BITS>12 || MAX_SAMPLES<1 || MAX_SAMPLES>4096 ||
           Q_BITS<1 || Q_BITS>24 || TAG_W<1 || TAG_W>32)
            $fatal(1,"invalid stream_ssim parameters");
    end
`endif

    always @(posedge clk) begin
        if(rst) begin
            state<=INPUT_PAIR; count<=0; sx<=0; sy<=0;
            sxx<=0; syy<=0; sxy<=0; started<=0; overflow<=0;
            m_score<=0; m_count<=0; m_empty<=0; m_overflow<=0; m_tag<=0;
            tag<=0; last_pair<=0; operation<=0; negative<=0;
        end else case(state)
            INPUT_PAIR: if(s_valid) begin
                if(!started) begin tag<=s_tag; started<=1; end
                if(s_mask && count<MAX_SAMPLES) begin
                    count<=count+1'b1; sx<=sx+s_x; sy<=sy+s_y;
                    px<=s_x; py<=s_y; last_pair<=s_last; state<=PIX_XX;
                end else begin
                    if(s_mask) overflow<=1;
                    if(s_last) state<=BLOCK_END;
                end
            end
            PIX_XX: begin sxx<=sxx+small_product; state<=PIX_YY; end
            PIX_YY: begin syy<=syy+small_product; state<=PIX_XY; end
            PIX_XY: begin
                sxy<=sxy+small_product;
                state<=last_pair?BLOCK_END:INPUT_PAIR;
            end
            BLOCK_END: begin
                m_count<=count; m_tag<=tag; m_empty<=count==0;
                m_overflow<=overflow;
                if(count==0) begin m_score<=0; state<=EMIT; end
                else begin operation<=0; state<=MUL_START; end
            end
            MUL_START: begin
                mul_acc<=0; mul_step<=0; state<=MUL_RUN;
                case(operation)
                    0: begin mul_a<=sx; mul_b<=sx; end
                    1: begin mul_a<=sy; mul_b<=sy; end
                    2: begin mul_a<=sx; mul_b<=sy; end
                    3: begin mul_a<=count; mul_b<=sxx; end
                    4: begin mul_a<=count; mul_b<=syy; end
                    5: begin mul_a<=count; mul_b<=sxy; end
                    6: begin mul_a<=count; mul_b<=count; end
                    7: begin mul_a<=nn; mul_b<=PEAK2; end
                    8: begin mul_a<=a_term; mul_b<=b_abs; negative<=b_term[MW-1]; end
                    9: begin mul_a<=c_term; mul_b<=d_term; end
                endcase
            end
            MUL_RUN: begin
                mul_acc<=mul_next; mul_a<=mul_a<<1; mul_b<=mul_b>>1;
                if(mul_step==MW-1) begin
                    case(operation)
                        0: xx<=mul_next;
                        1: yy<=mul_next;
                        2: xy<=mul_next;
                        3: nxx<=mul_next;
                        4: nyy<=mul_next;
                        5: nxy<=mul_next;
                        6: nn<=mul_next;
                        7: base<=mul_next;
                        8: numerator<=mul_next;
                        9: denominator<=mul_next;
                    endcase
                    operation<=operation+1'b1;
                    if(operation==7) state<=FORM;
                    else if(operation==9) state<=DIV_START;
                    else state<=MUL_START;
                end else mul_step<=mul_step+1'b1;
            end
            FORM: begin
                a_term<=xy_w*20000+base;
                b_term<=covariance*20000+$signed(base*9);
                c_term<=(xx_w+yy_w)*10000+base;
                d_term<=variance_sum*10000+base*9;
                state<=MUL_START;
            end
            DIV_START: begin
                dividend<={numerator,{Q_BITS{1'b0}}};
                quotient<=0; remainder<=0; div_step<=0; state<=DIV_RUN;
            end
            DIV_RUN: begin
                dividend<=dividend<<1;
                quotient<=quotient_next;
                remainder<=take_bit ? trial-{1'b0,denominator} : trial;
                if(div_step==DW-1) begin
                    // The SSIM bound [-1,+1] guarantees this slice is sufficient.
                    m_score<=negative ? -$signed(quotient_next[Q_BITS+1:0])
                                      : $signed(quotient_next[Q_BITS+1:0]);
                    state<=EMIT;
                end else div_step<=div_step+1'b1;
            end
            EMIT: if(m_ready) begin
                state<=INPUT_PAIR; count<=0; sx<=0; sy<=0;
                sxx<=0; syy<=0; sxy<=0; started<=0; overflow<=0;
            end
        endcase
    end
endmodule
