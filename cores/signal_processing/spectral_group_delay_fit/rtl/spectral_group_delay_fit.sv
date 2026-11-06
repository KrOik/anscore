// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// OLS delay of consecutive FFT bins. Binary-turn phase; final delay is samples Q16.
module spectral_group_delay_fit #(
    parameter integer PHASE_W=16, MAX_BINS=64, TAG_W=8, MAX_FFT_LOG2=16,
    parameter integer L=$clog2(MAX_BINS), COUNT_W=$clog2(MAX_BINS+1),
    parameter integer ACC_W=PHASE_W+L, SY_W=ACC_W+L,
    parameter integer SX_W=2*L, SXX_W=3*L, SXY_W=ACC_W+2*L+1,
    parameter integer SYY_W=2*ACC_W+L, B_W=SXY_W+COUNT_W+1,
    parameter integer C_W=SYY_W+COUNT_W+1, D_W=SXX_W+COUNT_W+1,
    parameter integer RES_W=((C_W+D_W>2*B_W)?C_W+D_W:2*B_W)+1,
    parameter integer DELAY_W=MAX_FFT_LOG2+17
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire [31:0] c_count,c_first_bin,c_fft_log2,
    input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,
    input wire [PHASE_W-1:0] s_phase,input wire s_last,s_invalid,
    output wire m_valid,input wire m_ready,
    output reg [2:0] m_status,
    output wire signed [DELAY_W-1:0] m_delay_q16,
    output wire signed [B_W-1:0] m_b,
    output wire [C_W-1:0] m_c,output wire [D_W-1:0] m_d,
    output wire [RES_W-1:0] m_residual_numerator,
    output reg [31:0] m_count,m_first_bin,m_fft_log2,m_received,
    output reg [TAG_W-1:0] m_tag,output wire busy
);
    localparam integer MUL_W=((B_W>C_W)?((B_W>D_W)?B_W:D_W):((C_W>D_W)?C_W:D_W))+1;
    localparam integer PRODUCT_W=2*MUL_W, DIV_W=B_W+MAX_FFT_LOG2+16;
    localparam [3:0] IDLE=0,FEED=1,UNWRAP=2,SQR_REQ=3,SQR_WAIT=4,
        XY_REQ=5,XY_WAIT=6,FINAL_REQ=7,FINAL_WAIT=8,DIV_REQ=9,DIV_WAIT=10,
        FENCE=11,HOLD=12;
    localparam [2:0] OK=0,BAD_CONFIG=1,BAD_LAST=2,INVALID_PHASE=3,ARITH=4;
    reg [3:0] state;
    reg [2:0] operation;
    reg [COUNT_W-1:0] index;
    reg [SXX_W-1:0] index_square;
    reg [SX_W-1:0] sx;
    reg [SXX_W-1:0] sxx;
    reg signed [SY_W-1:0] sy;
    reg signed [SXY_W-1:0] sxy;
    reg [SYY_W-1:0] syy;
    reg signed [ACC_W-1:0] phase;
    reg signed [B_W-1:0] b,b_temp;
    reg [C_W-1:0] c,c_temp;
    reg [D_W-1:0] d,d_temp;
    reg [RES_W-1:0] residual,residual_temp;
    reg signed [DELAY_W-1:0] delay_q16;
    wire helper_reset=rst || state==FENCE;
    wire [32:0] command_end={1'b0,c_first_bin}+{1'b0,c_count};
    wire [32:0] command_fft_size=33'd1 << c_fft_log2;
    wire config_ok=c_count>=2 && c_count<=MAX_BINS && c_fft_log2>=4 &&
        c_fft_log2<=MAX_FFT_LOG2 && command_end<=command_fft_size;
    wire expected_last=m_received==m_count-1;
    wire input_legal=!s_invalid && s_last==expected_last;
    wire unwrap_ready,unwrap_valid,unwrap_first,unwrap_overflow,unwrap_last;
    wire signed [ACC_W-1:0] unwrapped;
    assign c_ready=!rst && state==IDLE;
    assign s_ready=!rst && state==FEED && unwrap_ready;
    assign m_valid=!rst && state==HOLD;
    assign busy=!rst && state!=IDLE;
    assign m_delay_q16=delay_q16;
    assign m_b=b;assign m_c=c;assign m_d=d;assign m_residual_numerator=residual;
    stream_phase_unwrap #(.PHASE_W(PHASE_W),.ACC_W(ACC_W),.TAG_W(1)) unwrap(
        .clk(clk),.rst(helper_reset),.s_valid(s_valid && !rst && state==FEED && input_legal),
        .s_ready(unwrap_ready),.s_phase(s_phase),.s_restart(m_received==0),.s_last(s_last),.s_tag(1'b0),
        .m_valid(unwrap_valid),.m_ready(state==UNWRAP && !rst),.m_phase(unwrapped),
        .m_delta(),.m_first(unwrap_first),.m_overflow(unwrap_overflow),.m_last(unwrap_last),.m_tag());
    wire [ACC_W-1:0] phase_magnitude=phase[ACC_W-1] ? (~phase+1'b1) : phase;
    wire [SY_W-1:0] sy_magnitude=sy[SY_W-1] ? (~sy+1'b1) : sy;
    wire [SXY_W-1:0] sxy_magnitude=sxy[SXY_W-1] ? (~sxy+1'b1) : sxy;
    wire [B_W-1:0] b_magnitude=b[B_W-1] ? (~b+1'b1) : b;
    reg [MUL_W-1:0] multiply_a,multiply_b;
    reg multiply_negative;
    wire multiply_ready,multiply_valid;
    wire [PRODUCT_W-1:0] product;
    wire multiply_request=state==SQR_REQ || state==XY_REQ || state==FINAL_REQ;
    wire multiply_consume=state==SQR_WAIT || state==XY_WAIT || state==FINAL_WAIT;
    wire signed [PRODUCT_W:0] signed_product=multiply_negative ?
        -$signed({1'b0,product}) : $signed({1'b0,product});
    always @* begin
        multiply_a=0;multiply_b=0;multiply_negative=0;
        if(state==SQR_REQ || state==SQR_WAIT)begin
            multiply_a=phase_magnitude;multiply_b=phase_magnitude;
        end else if(state==XY_REQ || state==XY_WAIT)begin
            multiply_a=index;multiply_b=phase_magnitude;multiply_negative=phase[ACC_W-1];
        end else case(operation)
            0:begin multiply_a=m_count; multiply_b=sxy_magnitude;multiply_negative=sxy[SXY_W-1];end
            1:begin multiply_a=sx;multiply_b=sy_magnitude;multiply_negative=sy[SY_W-1];end
            2:begin multiply_a=m_count;multiply_b=sxx;end
            3:begin multiply_a=sx;multiply_b=sx;end
            4:begin multiply_a=m_count;multiply_b=syy;end
            5:begin multiply_a=sy_magnitude;multiply_b=sy_magnitude;end
            6:begin multiply_a=c;multiply_b=d;end
            7:begin multiply_a=b_magnitude;multiply_b=b_magnitude;end
        endcase
    end
    img_hist_serial_multiply #(.A_W(MUL_W),.B_W(MUL_W)) multiply(
        .clk(clk),.rst_n(!helper_reset),.clk_en(1'b1),
        .s_valid(!rst && multiply_request),.s_ready(multiply_ready),.s_a(multiply_a),.s_b(multiply_b),
        .m_valid(multiply_valid),.m_ready(!rst && multiply_consume),.m_product(product));
    wire [DIV_W-1:0] numerator={{(DIV_W-B_W){1'b0}},b_magnitude} << (m_fft_log2+16);
    wire [DIV_W-1:0] denominator={{(DIV_W-D_W){1'b0}},d} << PHASE_W;
    wire divide_ready,divide_valid,divide_zero;
    wire [DIV_W-1:0] quotient,remainder;
    wire round_up=(remainder>denominator-remainder) ||
        (remainder==denominator-remainder && quotient[0]);
    wire [DIV_W:0] rounded={1'b0,quotient}+{{DIV_W{1'b0}},round_up};
    integer_divider #(.W(DIV_W)) divide(
        .clk(clk),.rst(helper_reset),.s_valid(!rst && state==DIV_REQ),.s_ready(divide_ready),
        .s_numerator(numerator),.s_denominator(denominator),
        .m_valid(divide_valid),.m_ready(!rst && state==DIV_WAIT),
        .m_quotient(quotient),.m_remainder(remainder),.m_divzero(divide_zero));
    initial begin
        if(PHASE_W<8 || PHASE_W>24 || MAX_BINS<2 || MAX_BINS>256 || TAG_W<1 || TAG_W>32 ||
           MAX_FFT_LOG2<4 || MAX_FFT_LOG2>16 || L!=$clog2(MAX_BINS) || COUNT_W!=$clog2(MAX_BINS+1) ||
           ACC_W!=PHASE_W+L || SY_W!=ACC_W+L || SX_W!=2*L || SXX_W!=3*L ||
           SXY_W!=ACC_W+2*L+1 || SYY_W!=2*ACC_W+L || B_W!=SXY_W+COUNT_W+1 ||
           C_W!=SYY_W+COUNT_W+1 || D_W!=SXX_W+COUNT_W+1 ||
           RES_W!=((C_W+D_W>2*B_W)?C_W+D_W:2*B_W)+1 || DELAY_W!=MAX_FFT_LOG2+17)
            $fatal(1,"spectral_group_delay_fit illegal parameters / derived width override");
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;operation<=0;index<=0;index_square<=0;
            sx<=0;sxx<=0;sy<=0;sxy<=0;syy<=0;phase<=0;
            b<=0;c<=0;d<=0;residual<=0;b_temp<=0;c_temp<=0;d_temp<=0;residual_temp<=0;delay_q16<=0;
            m_status<=0;m_count<=0;m_first_bin<=0;m_fft_log2<=0;m_received<=0;m_tag<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                m_count<=c_count;m_first_bin<=c_first_bin;m_fft_log2<=c_fft_log2;m_tag<=c_tag;
                m_received<=0;m_status<=config_ok?OK:BAD_CONFIG;
                index<=0;index_square<=0;sx<=0;sxx<=0;sy<=0;sxy<=0;syy<=0;phase<=0;
                b<=0;c<=0;d<=0;residual<=0;delay_q16<=0;
                state<=config_ok?FEED:FENCE;
            end
            FEED:if(s_valid && s_ready)begin
                m_received<=m_received+1'b1;
                if(!input_legal)begin m_status<=s_invalid?INVALID_PHASE:BAD_LAST;state<=FENCE;end
                else state<=UNWRAP;
            end
            UNWRAP:if(unwrap_valid)begin
                if(unwrap_overflow || unwrap_first!=(m_received==1) || unwrap_last!=(m_received==m_count))begin
                    m_status<=ARITH;state<=FENCE;
                end else begin
                    phase<=unwrapped;
                    sy<=sy+$signed({{(SY_W-ACC_W){unwrapped[ACC_W-1]}},unwrapped});
                    sx<=sx+{{(SX_W-COUNT_W){1'b0}},index};sxx<=sxx+index_square;
                    state<=SQR_REQ;
                end
            end
            SQR_REQ:if(multiply_ready)state<=SQR_WAIT;
            SQR_WAIT:if(multiply_valid)begin syy<=syy+product[SYY_W-1:0];state<=XY_REQ;end
            XY_REQ:if(multiply_ready)state<=XY_WAIT;
            XY_WAIT:if(multiply_valid)begin
                sxy<=sxy+signed_product[SXY_W-1:0];
                if(m_received==m_count)begin operation<=0;state<=FINAL_REQ;end
                else begin
                    index<=index+1'b1;
                    index_square<=index_square+({{(SXX_W-COUNT_W){1'b0}},index}<<1)+1'b1;
                    state<=FEED;
                end
            end
            FINAL_REQ:if(multiply_ready)state<=FINAL_WAIT;
            FINAL_WAIT:if(multiply_valid)begin
                operation<=operation+1'b1;state<=FINAL_REQ;
                case(operation)
                    0:b_temp<=signed_product[B_W-1:0];
                    1:b<=b_temp-$signed(signed_product[B_W-1:0]);
                    2:d_temp<=product[D_W-1:0];
                    3:if({{(PRODUCT_W-D_W){1'b0}},d_temp}<=product)begin m_status<=ARITH;state<=FENCE;end
                      else d<=d_temp-product[D_W-1:0];
                    4:c_temp<=product[C_W-1:0];
                    5:if({{(PRODUCT_W-C_W){1'b0}},c_temp}<product)begin m_status<=ARITH;state<=FENCE;end
                      else c<=c_temp-product[C_W-1:0];
                    6:residual_temp<=product[RES_W-1:0];
                    7:if({{(PRODUCT_W-RES_W){1'b0}},residual_temp}<product)begin m_status<=ARITH;state<=FENCE;end
                      else begin residual<=residual_temp-product[RES_W-1:0];state<=DIV_REQ;end
                endcase
            end
            DIV_REQ:if(divide_ready)state<=DIV_WAIT;
            DIV_WAIT:if(divide_valid)begin
                if(divide_zero || (rounded>>(DELAY_W-1))!=0 || remainder>=denominator)begin
                    m_status<=ARITH;state<=FENCE;
                end else begin
                    delay_q16<=b[B_W-1]?$signed(rounded[DELAY_W-1:0]):-$signed(rounded[DELAY_W-1:0]);
                    state<=HOLD;
                end
            end
            FENCE:begin b<=0;c<=0;d<=0;residual<=0;delay_q16<=0;state<=HOLD;end
            HOLD:if(m_ready)state<=IDLE;
            default:begin m_status<=ARITH;state<=FENCE;end
        endcase
    end
endmodule
