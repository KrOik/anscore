// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// All-pole synthesis lattice, descending reflection stages, saturating state.
module iir_lattice_synthesis #(
    parameter integer DATA_W=16,
    parameter integer STATE_W=24,
    parameter integer FRAC=16,
    parameter integer ORDER=4,
    parameter integer TAG_W=8,
    localparam integer IW=$clog2(ORDER+1),
    localparam integer PW=STATE_W+FRAC+1,
    localparam integer MCW=(FRAC<2)?1:$clog2(FRAC+1)
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire signed [FRAC:0] c_k,
    output reg c_done,c_error,
    output reg configured,
    input wire s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [STATE_W-1:0] m_data,
    output reg m_last,m_clipped,
    output reg [TAG_W-1:0] m_tag
);
    localparam [2:0] IDLE=0,CFG_LOAD=1,CFG_COMMIT=2,
        STAGE=3,MUL_RUN=4,BACK_SETUP=5,EMIT=6;
    generate if(DATA_W<2 || DATA_W>24 || STATE_W<DATA_W || STATE_W>32 ||
                FRAC<1 || FRAC>20 || ORDER<1 || ORDER>8 || TAG_W<1 || TAG_W>32) begin : g_invalid
        iir_lattice_synthesis_invalid_parameter__see_README invalid_configuration();
    end endgenerate
    reg [2:0] state;
    reg [IW-1:0] config_index,commit_index,stage;
    reg config_bad,sample_clipped,forward;
    reg signed [FRAC:0] coefficients[1:ORDER],shadow[1:ORDER];
    reg signed [STATE_W-1:0] history[0:ORDER-1];
    reg signed [STATE_W-1:0] f_current,back_old;
    wire invalid_coefficient=c_k=={1'b1,{FRAC{1'b0}}}; // exactly -1.0
    wire signed [STATE_W-1:0] stage_back=history[stage-1'b1];
    wire signed [FRAC:0] stage_k=coefficients[stage];
    wire [FRAC:0] coefficient_abs=stage_k[FRAC] ? -$unsigned(stage_k):$unsigned(stage_k);
    wire [STATE_W-1:0] back_abs=stage_back[STATE_W-1] ? -$unsigned(stage_back):$unsigned(stage_back);
    wire [STATE_W-1:0] forward_abs=f_current[STATE_W-1] ? -$unsigned(f_current):$unsigned(f_current);
    reg [PW-1:0] mul_shift,mul_acc;
    reg [FRAC-1:0] mul_factor;
    reg [MCW-1:0] mul_step;
    reg mul_negative;
    wire [PW-1:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:{PW{1'b0}});
    wire [PW-1:0] quantized_abs=mul_next>>FRAC;
    wire signed [PW:0] product_q=mul_negative ? -$signed({1'b0,quantized_abs}):$signed({1'b0,quantized_abs});
    wire signed [PW:0] arithmetic_value=forward ?
        ($signed(f_current)-product_q):($signed(back_old)+product_q);
    localparam signed [PW:0] MAXIMUM={{(PW+1-STATE_W){1'b0}},1'b0,{(STATE_W-1){1'b1}}};
    localparam signed [PW:0] MINIMUM={{(PW+1-STATE_W){1'b1}},1'b1,{(STATE_W-1){1'b0}}};
    wire arithmetic_clipped=arithmetic_value<MINIMUM || arithmetic_value>MAXIMUM;
    wire signed [STATE_W-1:0] saturated_value=(arithmetic_value<MINIMUM)?
        {1'b1,{(STATE_W-1){1'b0}}}:((arithmetic_value>MAXIMUM)?
        {1'b0,{(STATE_W-1){1'b1}}}:arithmetic_value[STATE_W-1:0]);
    assign c_ready=!rst && (state==IDLE || state==CFG_LOAD);
    assign s_ready=!rst && state==IDLE && configured && !c_valid;
    assign m_valid=!rst && state==EMIT;

    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;configured<=0;c_done<=0;c_error<=0;
            config_index<=1;commit_index<=1;config_bad<=0;stage<=ORDER;
            sample_clipped<=0;m_data<=0;m_last<=0;m_clipped<=0;m_tag<=0;
        end else begin
            c_done<=0;
            case(state)
                IDLE: begin
                    // Configuration wins simultaneous configuration/sample offers.
                    if(c_valid) begin
                        shadow[1]<=c_k;config_bad<=invalid_coefficient;
                        if(ORDER==1) begin commit_index<=1;state<=CFG_COMMIT;end
                        else begin config_index<=2;state<=CFG_LOAD;end
                    end else if(s_valid && configured) begin
                        f_current<=$signed(s_data);sample_clipped<=0;stage<=ORDER;
                        m_last<=s_last;m_tag<=s_tag;state<=STAGE;
                    end
                end
                CFG_LOAD: if(c_valid) begin
                    shadow[config_index]<=c_k;config_bad<=config_bad||invalid_coefficient;
                    if(config_index==ORDER) begin commit_index<=1;state<=CFG_COMMIT;end
                    else config_index<=config_index+1'b1;
                end
                CFG_COMMIT: begin
                    if(config_bad) begin c_done<=1;c_error<=1;state<=IDLE;end
                    else begin
                        coefficients[commit_index]<=shadow[commit_index];history[commit_index-1'b1]<=0;
                        if(commit_index==ORDER) begin configured<=1;c_done<=1;c_error<=0;state<=IDLE;end
                        else commit_index<=commit_index+1'b1;
                    end
                end
                STAGE: begin
                    back_old<=stage_back;mul_shift<=back_abs;mul_factor<=coefficient_abs[FRAC-1:0];
                    mul_negative<=stage_back[STATE_W-1]^stage_k[FRAC];
                    mul_acc<=0;mul_step<=0;forward<=1;state<=MUL_RUN;
                end
                BACK_SETUP: begin
                    mul_shift<=forward_abs;mul_factor<=coefficient_abs[FRAC-1:0];
                    mul_negative<=f_current[STATE_W-1]^stage_k[FRAC];
                    mul_acc<=0;mul_step<=0;forward<=0;state<=MUL_RUN;
                end
                MUL_RUN: begin
                    mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;mul_acc<=mul_next;
                    if(mul_step==FRAC-1) begin
                        sample_clipped<=sample_clipped||arithmetic_clipped;
                        if(forward) begin
                            f_current<=saturated_value;
                            if(stage==ORDER) begin
                                // b_ORDER is never consumed by this all-pole output.
                                if(stage==1) begin
                                    history[0]<=saturated_value;m_data<=saturated_value;
                                    m_clipped<=sample_clipped||arithmetic_clipped;state<=EMIT;
                                end else begin stage<=stage-1'b1;state<=STAGE;end
                            end else state<=BACK_SETUP;
                        end else begin
                            history[stage]<=saturated_value;
                            if(stage==1) begin
                                history[0]<=f_current;m_data<=f_current;
                                m_clipped<=sample_clipped||arithmetic_clipped;state<=EMIT;
                            end else begin stage<=stage-1'b1;state<=STAGE;end
                        end
                    end else mul_step<=mul_step+1'b1;
                end
                EMIT: if(m_ready) state<=IDLE;
                default: begin state<=IDLE;configured<=0;end
            endcase
        end
    end
endmodule
