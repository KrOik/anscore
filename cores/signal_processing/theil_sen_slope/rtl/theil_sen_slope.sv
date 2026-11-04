// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module theil_sen_slope #(
    parameter integer DATA_W=12,MAX_LEN=8,TAG_W=8,
    localparam integer COUNT_W=$clog2(MAX_LEN+1),
    localparam integer PAIR_W=($clog2(MAX_LEN*(MAX_LEN-1)/2+1)<1)?1:
        $clog2(MAX_LEN*(MAX_LEN-1)/2+1)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_x,s_y,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [COUNT_W-1:0] m_count,
    output wire [PAIR_W-1:0] m_pairs,m_skipped,
    output wire m_even,
    output reg signed [2*DATA_W+1:0] m_num,
    output reg [2*DATA_W:0] m_den,
    output reg signed [DATA_W:0] m_low_num,m_high_num,
    output reg [DATA_W-1:0] m_low_den,m_high_den,
    output wire [TAG_W-1:0] m_tag,
    output reg [1:0] m_errors
);
    localparam integer W=DATA_W,D=W+1,P=MAX_LEN*(MAX_LEN-1)/2;
    localparam integer STEP_W=($clog2(W)<1)?1:$clog2(W);
    localparam [4:0] COLLECT=0,FINALIZE=1,PAIR_A=2,PAIR_B=3,PAIR_EVAL=4,
        INSERT=5,SLOT_READ=6,COMPARE=7,MUL_RUN=8,MUL_DONE=9,SHIFT=10,
        WRITE=11,NEXT_PAIR=12,LOW_READ=13,LOW_CAPTURE=14,HIGH_READ=15,
        HIGH_CAPTURE=16,EMIT=17;
    localparam [2:0] CMP_LEFT=0,CMP_RIGHT=1,AVG_LEFT=2,AVG_RIGHT=3,AVG_DEN=4;
    reg [4:0] state;
    reg started,overflow,x_varies;
    reg signed [W-1:0] first_x;
    reg [COUNT_W-1:0] count,pair_i,pair_j;
    reg [PAIR_W-1:0] pairs,skipped,insert_pos;
    reg [TAG_W-1:0] tag_q;
    reg [2*W-1:0] samples[0:MAX_LEN-1];
    reg [2*W-1:0] sample_q,a_sample;
    reg [2*W:0] slopes[0:P-1];
    reg [2*W:0] slope_q;
    reg signed [D-1:0] cand_num;
    reg [W-1:0] cand_den;
    wire signed [W-1:0] ax=a_sample[2*W-1:W],ay=a_sample[W-1:0];
    wire signed [W-1:0] bx=sample_q[2*W-1:W],by=sample_q[W-1:0];
    wire signed [D-1:0] dx=$signed({bx[W-1],bx})-$signed({ax[W-1],ax});
    wire signed [D-1:0] dy=$signed({by[W-1],by})-$signed({ay[W-1],ay});
    wire signed [D-1:0] old_num=slope_q[2*W:W];
    wire [W-1:0] old_den=slope_q[W-1:0];
    reg [2*W-1:0] mul_acc,mul_term;
    reg [W-1:0] mul_factor;
    reg [STEP_W-1:0] mul_step;
    reg mul_negative;
    reg [2:0] mul_role;
    reg signed [2*W:0] product,left_product;
    wire [2*W-1:0] mul_sum=mul_acc+(mul_factor[0]?mul_term:{2*W{1'b0}});
    wire [1:0] final_errors={overflow,!x_varies};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;
    assign m_pairs=(m_errors==0)?pairs:{PAIR_W{1'b0}};
    assign m_skipped=(m_errors==0)?skipped:{PAIR_W{1'b0}};
    assign m_even=(m_errors==0) && !pairs[0];
    assign m_tag=tag_q;

    // A single signed-by-positive product engine. Legal numerator magnitudes
    // fit W bits even though signed differences require D=W+1 bits.
    task automatic begin_multiply(input signed [D-1:0] a,
        input [W-1:0] b,input [2:0] role);
        reg [D-1:0] magnitude;
        begin
            magnitude=a[D-1]?-a:a;
            mul_acc<=0;mul_term<={{W{1'b0}},magnitude[W-1:0]};
            mul_factor<=b;mul_step<=0;mul_negative<=a[D-1];mul_role<=role;
            state<=MUL_RUN;
        end
    endtask

    // Collection and pair enumeration never overlap. Each read is consumed
    // on a later edge; insertion shifts the registered old word before reread.
    always @(posedge clk) if(!rst)begin
        if(state==COLLECT && s_valid && s_ready && s_keep && count<MAX_LEN)
            samples[count]<={s_x,s_y};
        if(state==PAIR_A)sample_q<=samples[pair_i];
        if(state==PAIR_B)sample_q<=samples[pair_j];
        if(state==SLOT_READ)slope_q<=slopes[insert_pos-1'b1];
        if(state==SHIFT)slopes[insert_pos]<=slope_q;
        if(state==WRITE)slopes[insert_pos]<={cand_num,cand_den};
        if(state==LOW_READ)slope_q<=slopes[(pairs-1'b1)>>1];
        if(state==HIGH_READ)slope_q<=slopes[pairs>>1];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;started<=0;overflow<=0;x_varies<=0;first_x<=0;
            count<=0;pair_i<=0;pair_j<=0;pairs<=0;skipped<=0;insert_pos<=0;
            tag_q<=0;a_sample<=0;cand_num<=0;cand_den<=0;
            mul_acc<=0;mul_term<=0;mul_factor<=0;mul_step<=0;
            mul_negative<=0;mul_role<=0;product<=0;left_product<=0;
            m_num<=0;m_den<=0;m_low_num<=0;m_low_den<=0;
            m_high_num<=0;m_high_den<=0;m_errors<=0;
        end else case(state)
            COLLECT: if(s_valid && s_ready)begin
                if(!started)begin started<=1;tag_q<=s_tag;end
                if(s_keep)begin
                    if(count==MAX_LEN)overflow<=1;
                    else begin
                        count<=count+1'b1;
                        if(count==0)first_x<=s_x;
                        else if(s_x!=first_x)x_varies<=1;
                    end
                end
                if(s_last)state<=FINALIZE;
            end
            FINALIZE: begin
                m_errors<=final_errors;
                if(final_errors!=0)begin
                    m_num<=0;m_den<=0;m_low_num<=0;m_low_den<=0;
                    m_high_num<=0;m_high_den<=0;state<=EMIT;
                end else begin pair_i<=0;pair_j<=1;state<=PAIR_A;end
            end
            PAIR_A: state<=PAIR_B;
            PAIR_B: begin a_sample<=sample_q;state<=PAIR_EVAL;end
            PAIR_EVAL: begin
                if(dx==0)begin skipped<=skipped+1'b1;state<=NEXT_PAIR;end
                else begin
                    cand_num<=dx[D-1]?-dy:dy;
                    cand_den<=dx[D-1]?-dx:dx;state<=INSERT;
                end
            end
            INSERT: begin insert_pos<=pairs;state<=(pairs==0)?WRITE:SLOT_READ;end
            SLOT_READ: state<=COMPARE;
            COMPARE: begin_multiply(cand_num,old_den,CMP_LEFT);
            MUL_RUN: begin
                if(mul_step==W-1)begin
                    product<=mul_negative?-$signed({1'b0,mul_sum}):$signed({1'b0,mul_sum});
                    state<=MUL_DONE;
                end else begin
                    mul_acc<=mul_sum;mul_term<=mul_term<<1;
                    mul_factor<=mul_factor>>1;mul_step<=mul_step+1'b1;
                end
            end
            MUL_DONE: case(mul_role)
                CMP_LEFT: begin left_product<=product;begin_multiply(old_num,cand_den,CMP_RIGHT);end
                CMP_RIGHT: state<=(left_product<product)?SHIFT:WRITE;
                AVG_LEFT: begin left_product<=product;begin_multiply(m_high_num,m_low_den,AVG_RIGHT);end
                AVG_RIGHT: begin
                    // Extend both signed products before the potentially
                    // one-bit-wider sum; no assignment-context truncation.
                    m_num<=$signed({left_product[2*W],left_product})+
                        $signed({product[2*W],product});
                    begin_multiply($signed({1'b0,m_low_den}),m_high_den,AVG_DEN);
                end
                AVG_DEN: begin m_den<={product[2*W-1:0],1'b0};state<=EMIT;end
                default: state<=FINALIZE;
            endcase
            SHIFT: begin
                insert_pos<=insert_pos-1'b1;
                state<=(insert_pos==1)?WRITE:SLOT_READ;
            end
            WRITE: begin pairs<=pairs+1'b1;state<=NEXT_PAIR;end
            NEXT_PAIR: begin
                if(pair_j==count-1'b1)begin
                    if(pair_i==count-2)state<=LOW_READ;
                    else begin pair_i<=pair_i+1'b1;pair_j<=pair_i+2;state<=PAIR_A;end
                end else begin pair_j<=pair_j+1'b1;state<=PAIR_A;end
            end
            LOW_READ: state<=LOW_CAPTURE;
            LOW_CAPTURE: begin m_low_num<=old_num;m_low_den<=old_den;state<=HIGH_READ;end
            HIGH_READ: state<=HIGH_CAPTURE;
            HIGH_CAPTURE: begin
                m_high_num<=old_num;m_high_den<=old_den;
                if(pairs[0])begin
                    m_num<={{(W+1){old_num[D-1]}},old_num};
                    m_den<={{(W+1){1'b0}},old_den};state<=EMIT;
                end else begin_multiply(m_low_num,old_den,AVG_LEFT);
            end
            EMIT: if(m_ready)begin
                state<=COLLECT;started<=0;overflow<=0;x_varies<=0;
                count<=0;pairs<=0;skipped<=0;
            end
            default: state<=COLLECT;
        endcase
    end
    generate if(DATA_W<1 || DATA_W>16 || MAX_LEN<2 || MAX_LEN>12 || TAG_W<1 || TAG_W>32)begin: bad_parameters
        theil_sen_slope_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
`default_nettype wire
