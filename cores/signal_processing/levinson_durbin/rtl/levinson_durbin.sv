// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Fixed-point autocorrelation LPC with explicitly shared iterative arithmetic.
module levinson_durbin #(
    parameter integer DATA_W=16,
    parameter integer FRAC=16,
    parameter integer ORDER=4,
    parameter integer TAG_W=8,
    localparam integer COEFF_W=FRAC+ORDER+2,
    localparam integer IW=$clog2(ORDER+1),
    localparam integer EW=DATA_W+FRAC+1,
    localparam integer ACW=DATA_W+COEFF_W+$clog2(ORDER+1)+2,
    localparam integer M0=DATA_W+2*FRAC+3,
    localparam integer MW=(M0>COEFF_W+1)?M0:COEFF_W+1,
    localparam integer DW=ACW+FRAC,
    localparam integer MCW=$clog2(MW+1),
    localparam integer DCW=$clog2(DW+1)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_r,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire signed [COEFF_W-1:0] m_a,
    output wire signed [FRAC:0] m_reflection,
    output wire [IW-1:0] m_index,
    output wire m_last,
    output wire [EW-1:0] m_energy,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam [3:0] LOAD=0,START=1,STAGE_START=2,SUM_START=3,
        MUL_SETUP=4,MUL_RUN=5,DIV_SETUP=6,DIV_RUN=7,
        UPDATE_START=8,ENERGY_START=9,ENERGY_SECOND=10,
        COMMIT=11,EMIT=12;
    localparam [1:0] SUM=0,UPDATE=1,ENERGY_K=2,ENERGY_KK=3;
    generate if(DATA_W<2 || DATA_W>24 || FRAC<1 || FRAC>20 ||
                ORDER<1 || ORDER>8 || TAG_W<1 || TAG_W>32) begin : g_invalid
        levinson_durbin_invalid_parameter__see_README invalid_configuration();
    end endgenerate
    reg [3:0] state;
    reg [1:0] purpose;
    reg [IW-1:0] load_index,stage,index,out_index;
    reg bad_r0;
    reg signed [DATA_W-1:0] r[0:ORDER];
    reg signed [COEFF_W-1:0] a[1:ORDER],next_a[1:ORDER];
    reg signed [FRAC:0] reflections[1:ORDER],reflection;
    reg [EW-1:0] energy;
    reg signed [ACW-1:0] acc;
    wire signed [ACW-1:0] stage_r={{(ACW-DATA_W){r[stage][DATA_W-1]}},r[stage]};

    reg signed [MW-1:0] mul_left,mul_right,energy_product;
    reg [2*MW-1:0] mul_shift,mul_acc;
    reg [MW-1:0] mul_factor;
    reg [MCW-1:0] mul_step;
    reg mul_negative;
    wire [MW-1:0] left_abs=mul_left[MW-1] ? -$unsigned(mul_left) : $unsigned(mul_left);
    wire [MW-1:0] right_abs=mul_right[MW-1] ? -$unsigned(mul_right) : $unsigned(mul_right);
    wire [2*MW-1:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:{(2*MW){1'b0}});
    wire signed [2*MW:0] mul_result=mul_negative ? -$signed({1'b0,mul_next}):$signed({1'b0,mul_next});
    wire [2*MW-1:0] adjustment_abs=mul_next>>FRAC;
    wire signed [2*MW:0] adjustment=mul_negative ? -$signed({1'b0,adjustment_abs}):$signed({1'b0,adjustment_abs});
    wire signed [2*MW:0] updated_coefficient=$signed(a[index])+adjustment;

    reg [DW-1:0] dividend,quotient;
    reg [ACW:0] remainder;
    reg [DCW-1:0] div_step;
    reg div_negative;
    wire [ACW-1:0] acc_abs=acc[ACW-1] ? -$unsigned(acc) : $unsigned(acc);
    wire [ACW:0] trial={remainder[ACW-1:0],dividend[DW-1]};
    wire [ACW:0] divisor={{(ACW+1-EW){1'b0}},energy};
    wire take_bit=trial>=divisor;
    wire [DW-1:0] quotient_next={quotient[DW-2:0],take_bit};
    wire [DW-1:0] unity={{(DW-FRAC-1){1'b0}},1'b1,{FRAC{1'b0}}};
    wire signed [FRAC:0] next_reflection=div_negative ?
        -$signed(quotient_next[FRAC:0]):$signed(quotient_next[FRAC:0]);

    assign s_ready=!rst && state==LOAD;
    assign m_valid=!rst && state==EMIT;
    assign m_a=(m_error!=0)?{COEFF_W{1'b0}}:a[out_index];
    assign m_reflection=(m_error!=0)?{(FRAC+1){1'b0}}:reflections[out_index];
    assign m_index=out_index;
    assign m_last=out_index==ORDER;
    assign m_energy=(m_error!=0)?{EW{1'b0}}:energy;

    always @(posedge clk) begin
        if(rst) begin
            state<=LOAD;load_index<=0;stage<=1;index<=1;out_index<=1;
            bad_r0<=0;energy<=0;acc<=0;m_error<=0;m_tag<=0;
        end else case(state)
            LOAD: if(s_valid) begin
                r[load_index]<=s_r;
                if(load_index==0) begin bad_r0<=s_r<=0;m_tag<=s_tag;m_error<=0;end
                if(load_index==ORDER) begin load_index<=0;state<=START;end
                else load_index<=load_index+1'b1;
            end
            START: begin
                stage<=1;out_index<=1;
                if(bad_r0) begin m_error<=1;energy<=0;state<=EMIT;end
                else begin
                    energy<={{(EW-DATA_W){1'b0}},r[0]}<<FRAC;
                    state<=STAGE_START;
                end
            end
            STAGE_START: begin acc<=stage_r<<<FRAC;index<=1;state<=SUM_START;end
            SUM_START: begin
                if(index==stage) state<=DIV_SETUP;
                else begin mul_left<=$signed(a[index]);mul_right<=$signed(r[stage-index]);purpose<=SUM;state<=MUL_SETUP;end
            end
            MUL_SETUP: begin
                mul_shift<=left_abs;mul_factor<=right_abs;mul_acc<=0;mul_step<=0;
                mul_negative<=mul_left[MW-1]^mul_right[MW-1];state<=MUL_RUN;
            end
            MUL_RUN: begin
                mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;mul_acc<=mul_next;
                if(mul_step==MW-1) begin
                    case(purpose)
                        SUM: begin acc<=acc+mul_result;index<=index+1'b1;state<=SUM_START;end
                        UPDATE: begin next_a[index]<=updated_coefficient;index<=index+1'b1;state<=UPDATE_START;end
                        ENERGY_K: begin energy_product<=mul_result;state<=ENERGY_SECOND;end
                        ENERGY_KK: begin energy<=energy-(mul_next>>(2*FRAC));index<=1;state<=COMMIT;end
                    endcase
                end else mul_step<=mul_step+1'b1;
            end
            DIV_SETUP: begin
                dividend<={acc_abs,{FRAC{1'b0}}};quotient<=0;remainder<=0;div_step<=0;
                div_negative<=!acc[ACW-1];state<=DIV_RUN;
            end
            DIV_RUN: begin
                dividend<=dividend<<1;quotient<=quotient_next;remainder<=take_bit?trial-divisor:trial;
                if(div_step==DW-1) begin
                    if(quotient_next>=unity) begin m_error<=2;out_index<=1;state<=EMIT;end
                    else begin
                        reflection<=next_reflection;reflections[stage]<=next_reflection;
                        next_a[stage]<=next_reflection;index<=1;state<=UPDATE_START;
                    end
                end else div_step<=div_step+1'b1;
            end
            UPDATE_START: begin
                if(index==stage) state<=ENERGY_START;
                else begin mul_left<=$signed(reflection);mul_right<=$signed(a[stage-index]);purpose<=UPDATE;state<=MUL_SETUP;end
            end
            ENERGY_START: begin mul_left<=$signed({1'b0,energy});mul_right<=$signed(reflection);purpose<=ENERGY_K;state<=MUL_SETUP;end
            ENERGY_SECOND: begin mul_left<=energy_product;mul_right<=$signed(reflection);purpose<=ENERGY_KK;state<=MUL_SETUP;end
            COMMIT: begin
                a[index]<=next_a[index];
                if(index==stage) begin
                    if(stage==ORDER) begin out_index<=1;state<=EMIT;end
                    else begin stage<=stage+1'b1;state<=STAGE_START;end
                end else index<=index+1'b1;
            end
            EMIT: if(m_ready) begin
                if(out_index==ORDER) state<=LOAD;
                else out_index<=out_index+1'b1;
            end
            default: state<=LOAD;
        endcase
    end
endmodule
