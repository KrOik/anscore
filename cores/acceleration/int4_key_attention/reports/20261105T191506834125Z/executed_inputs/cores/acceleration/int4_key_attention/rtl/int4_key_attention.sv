// SPDX-License-Identifier: Apache-2.0
// Original scheduler: resident INT4 key scores -> legacy softmax -> S8 V mix.
`default_nettype none
module int4_key_attention #(
    parameter integer MAX_COLS=64, MAX_VALUES=8, TAG_W=8
) (
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [15:0] c_row,c_word,input wire [31:0] c_data,
    input wire signed [31:0] c_bias,input wire [15:0] c_scale,
    input wire [4:0] c_shift,input wire signed [7:0] c_zero,
    output wire c_rsp_valid,input wire c_rsp_ready,output reg [1:0] c_error,
    input wire cmd_valid,output wire cmd_ready,
    input wire [15:0] cmd_tokens,cmd_cols,cmd_values,
    input wire [7:0] cmd_x_zero,input wire [TAG_W-1:0] cmd_tag,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,output reg signed [7:0] m_data,
    output reg [15:0] m_index,output reg m_last,output reg [2:0] m_error,
    output reg [TAG_W-1:0] m_tag,
    output reg m_score_clip,m_score_inexact,m_prob_clip,
    output wire [12:0] m_prob_sum
);
    localparam integer VW=(MAX_VALUES+3)/4,VS=16*VW;
    localparam [4:0] IDLE=0,C_SEND=1,C_WAIT=2,C_REPLY=3,V_CHECK=4,
        K_SEND=5,K_RUN=6,SM_READ=7,SM_FEED=8,SM_CAPTURE=9,
        V_READ=10,V_MAC=11,DIV_SEND=12,DIV_WAIT=13,OUTPUT_ROW=14,ERROR_ROW=15;
    reg [4:0] state;
    reg [VS-1:0] value_valid;
    reg [31:0] value_mem [0:VS-1];
    reg signed [7:0] score_mem [0:15];
    reg [7:0] probability_mem [0:15];
    reg [1:0] config_op;
    reg [15:0] config_row,config_word;
    reg [31:0] config_data;
    reg signed [31:0] config_bias;
    reg [15:0] config_scale;
    reg [4:0] config_shift;
    reg signed [7:0] config_zero;
    reg [15:0] tokens,cols,values,value_index,check_word;
    reg [4:0] token_index;
    reg [7:0] x_zero;
    reg [1:0] softmax_pass;
    reg signed [11:0] logit_read;
    reg [31:0] value_read;
    reg [7:0] probability_read;
    reg [12:0] probability_total;
    reg signed [20:0] accumulator;
    wire kc_ready,kc_valid,kcmd_ready,ks_ready,km_valid,km_last,km_clip,km_inexact;
    wire [1:0] kc_error,km_error;
    wire signed [7:0] km_data;
    wire [15:0] km_row;
    wire [TAG_W-1:0] km_tag;
    wire kbusy;
    wire signed [11:0] sm_max;
    wire [12:0] sm_sum;
    wire [7:0] sm_exp,sm_p,sm_count;
    wire sm_valid,sm_clip;
    wire [1:0] sm_phase;
    wire signed [13:0] sm_residual;
    wire [31:0] sm_id;
    wire div_ready,div_valid,div_zero;
    wire [20:0] quotient,remainder;
    wire [20:0] magnitude=accumulator[20]?-accumulator:accumulator;
    wire [21:0] twice_remainder={remainder,1'b0};
    wire round_up=(twice_remainder>{9'd0,probability_total})||
        ((twice_remainder=={9'd0,probability_total})&&quotient[0]);
    wire [21:0] rounded_magnitude={1'b0,quotient}+{{21{1'b0}},round_up};
    wire signed [22:0] rounded_signed=accumulator[20]?
        -$signed({1'b0,rounded_magnitude}):$signed({1'b0,rounded_magnitude});
    wire signed [7:0] selected_value=$signed(value_read[value_index[1:0]*8+:8]);
    wire signed [16:0] weighted=$signed({1'b0,probability_read})*selected_value;
    wire signed [20:0] next_sum=accumulator+{{4{weighted[16]}},weighted};
    generate if(MAX_COLS<1||MAX_COLS>1024||MAX_VALUES<1||MAX_VALUES>32||TAG_W<1||TAG_W>32)begin:invalid
        int4_key_attention_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    int4_weight_matvec #(.MAX_ROWS(16),.MAX_COLS(MAX_COLS),.TAG_W(TAG_W)) keys (
        .clk(clk),.rst(rst),.c_valid(state==C_SEND),.c_ready(kc_ready),.c_op(config_op),
        .c_row(config_row),.c_word(config_word),.c_weights(config_data),.c_bias(config_bias),
        .c_scale(config_scale),.c_shift(config_shift),.c_zero(config_zero),
        .c_rsp_valid(kc_valid),.c_rsp_ready(state==C_WAIT),.c_error(kc_error),
        .cmd_valid(state==K_SEND),.cmd_ready(kcmd_ready),.cmd_rows(tokens),.cmd_cols(cols),
        .cmd_x_zero(x_zero),.cmd_tag(m_tag),.s_valid(state==K_RUN&&s_valid),
        .s_ready(ks_ready),.s_data(s_data),.s_last(s_last),.m_valid(km_valid),
        .m_ready(state==K_RUN),.m_data(km_data),.m_row(km_row),.m_tag(km_tag),
        .m_last(km_last),.m_clip(km_clip),.m_inexact(km_inexact),.m_error(km_error),.busy(kbusy));
    // CE-qualified legacy interface is private. Only SM_FEED consumes a logit;
    // its registered result is sampled at SM_CAPTURE even though CE is then0.
    ips_softmax_fixed #(.LANES(16),.LB(12),.PB(8)) softmax (
        .clk(clk),.clk_en(state==SM_FEED),.rst_n(!rst),.in_valid(1'b1),.lg(logit_read),
        .rmax(sm_max),.rsum(sm_sum),.exp_last(sm_exp),.p(sm_p),.p_vld(sm_valid),
        .sat_sticky(sm_clip),.clip_count(sm_count),.ph_last(sm_phase),
        .resid(sm_residual),.cfg_id(sm_id));
    integer_divider #(.W(21)) normalize (
        .clk(clk),.rst(rst),.s_valid(state==DIV_SEND),.s_ready(div_ready),
        .s_numerator(magnitude),.s_denominator({8'd0,probability_total}),
        .m_valid(div_valid),.m_ready(state==DIV_WAIT),.m_quotient(quotient),
        .m_remainder(remainder),.m_divzero(div_zero));
    assign c_ready=!rst&&state==IDLE;
    assign cmd_ready=c_ready&&!c_valid;
    assign c_rsp_valid=!rst&&state==C_REPLY;
    assign s_ready=!rst&&state==K_RUN&&ks_ready;
    assign m_valid=!rst&&(state==OUTPUT_ROW||state==ERROR_ROW);
    assign m_prob_sum=probability_total;
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;value_valid<=0;config_op<=0;config_row<=0;config_word<=0;config_data<=0;
            config_bias<=0;config_scale<=0;config_shift<=0;config_zero<=0;c_error<=0;
            tokens<=0;cols<=0;values<=0;value_index<=0;check_word<=0;token_index<=0;x_zero<=0;
            softmax_pass<=0;logit_read<=0;value_read<=0;probability_read<=0;probability_total<=0;accumulator<=0;
            m_data<=0;m_index<=0;m_last<=0;m_error<=0;m_tag<=0;
            m_score_clip<=0;m_score_inexact<=0;m_prob_clip<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                c_error<=0;
                if(c_op<=2)begin
                    config_op<=c_op[1:0];config_row<=c_row;config_word<=c_word;config_data<=c_data;
                    config_bias<=c_bias;config_scale<=c_scale;config_shift<=c_shift;config_zero<=c_zero;
                    if(c_op==2)value_valid<=0;
                    state<=C_SEND;
                end else begin
                    state<=C_REPLY;
                    if(c_op==3)begin
                        if(c_row>=16||c_word>=VW)c_error<=1;
                        else begin value_mem[c_row*VW+c_word]<=c_data;value_valid[c_row*VW+c_word]<=1;end
                    end else c_error<=2;
                end
            end else if(cmd_valid)begin
                tokens<=cmd_tokens;cols<=cmd_cols;values<=cmd_values;x_zero<=cmd_x_zero;m_tag<=cmd_tag;
                m_data<=0;m_index<=0;m_last<=1;m_error<=0;m_score_clip<=0;m_score_inexact<=0;m_prob_clip<=0;
                probability_total<=0;token_index<=0;check_word<=0;value_index<=0;accumulator<=0;
                if(cmd_tokens==0||cmd_tokens>16||cmd_cols==0||cmd_cols>MAX_COLS||cmd_values==0||cmd_values>MAX_VALUES)begin
                    m_error<=1;state<=ERROR_ROW;
                end else state<=V_CHECK;
            end
            C_SEND:if(kc_ready)state<=C_WAIT;
            C_WAIT:if(kc_valid)begin c_error<=kc_error;state<=C_REPLY;end
            C_REPLY:if(c_rsp_ready)state<=IDLE;
            V_CHECK:begin
                if(!value_valid[token_index*VW+check_word])begin m_error<=4;state<=ERROR_ROW;end
                else if(check_word==((values-1'b1)>>2))begin
                    check_word<=0;
                    if(token_index==tokens-1'b1)begin token_index<=0;state<=K_SEND;end
                    else token_index<=token_index+1'b1;
                end else check_word<=check_word+1'b1;
            end
            K_SEND:if(kcmd_ready)state<=K_RUN;
            K_RUN:if(km_valid)begin
                if(km_error!=0)begin m_error<={1'b0,km_error};state<=ERROR_ROW;end
                else begin
                    score_mem[km_row[3:0]]<=km_data;
                    m_score_clip<=m_score_clip|km_clip;m_score_inexact<=m_score_inexact|km_inexact;
                    if(km_last)begin token_index<=0;softmax_pass<=0;state<=SM_READ;end
                end
            end
            SM_READ:begin
                logit_read<=(token_index<tokens)?{{4{score_mem[token_index[3:0]][7]}},score_mem[token_index[3:0]]}:-12'sd2048;
                state<=SM_FEED;
            end
            SM_FEED:state<=SM_CAPTURE;
            SM_CAPTURE:begin
                if(softmax_pass==2)begin
                    probability_mem[token_index[3:0]]<=sm_p;
                    probability_total<=probability_total+{5'd0,sm_p};
                end
                if(token_index==15)begin
                    token_index<=0;
                    if(softmax_pass==2)begin
                        m_prob_clip<=sm_clip;value_index<=0;accumulator<=0;state<=V_READ;
                    end else begin softmax_pass<=softmax_pass+1'b1;state<=SM_READ;end
                end else begin token_index<=token_index+1'b1;state<=SM_READ;end
            end
            V_READ:begin
                if(probability_total==0)begin m_error<=5;state<=ERROR_ROW;end
                else begin
                    value_read<=value_mem[token_index*VW+(value_index>>2)];
                    probability_read<=probability_mem[token_index[3:0]];state<=V_MAC;
                end
            end
            V_MAC:begin
                accumulator<=next_sum;
                if(token_index==tokens-1'b1)state<=DIV_SEND;
                else begin token_index<=token_index+1'b1;state<=V_READ;end
            end
            DIV_SEND:if(div_ready)state<=DIV_WAIT;
            DIV_WAIT:if(div_valid)begin
                if(div_zero||rounded_signed>127||rounded_signed< -128)begin m_error<=5;m_data<=0;m_index<=0;m_last<=1;state<=ERROR_ROW;end
                else begin m_data<=rounded_signed[7:0];m_index<=value_index;m_last<=value_index==values-1'b1;state<=OUTPUT_ROW;end
            end
            OUTPUT_ROW:if(m_ready)begin
                if(m_last)state<=IDLE;
                else begin value_index<=value_index+1'b1;token_index<=0;accumulator<=0;state<=V_READ;end
            end
            ERROR_ROW:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
