// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module kendall_tau_b #(
    parameter integer DATA_W=16,MAX_LEN=32,TAG_W=8,
    localparam integer COUNT_W=($clog2(MAX_LEN+1)<1)?1:$clog2(MAX_LEN+1),
    localparam integer PAIR_W=($clog2(MAX_LEN*(MAX_LEN-1)/2+1)<1)?1:
        $clog2(MAX_LEN*(MAX_LEN-1)/2+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_x,s_y,
    input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [COUNT_W-1:0] m_count,
    output wire [PAIR_W-1:0] m_pairs,m_concordant,m_discordant,m_tie_x,m_tie_y,m_tie_both,
    output reg signed [PAIR_W:0] m_score,
    output reg [2*PAIR_W-1:0] m_radicand,
    output wire [TAG_W-1:0] m_tag,output reg [2:0] m_errors
);
    localparam integer W=DATA_W,CW=COUNT_W,PW=PAIR_W,
        AW=($clog2(MAX_LEN)<1)?1:$clog2(MAX_LEN),
        LW=($clog2(PW)<1)?1:$clog2(PW);
    localparam [2:0] COLLECT=0,SCAN_READ=1,SCAN_EVAL=2,FINISH_SAMPLE=3,
        FINALIZE=4,MUL_RUN=5,EMIT=6;
    reg [2:0] state;
    reg started,overflow,tail_q,x_varies,y_varies;
    reg [CW-1:0] count,prior_count;
    reg [AW-1:0] scan_index;
    reg signed [W-1:0] x_q,y_q,first_x,first_y;
    reg [TAG_W-1:0] tag_q;
    reg [2*W-1:0] samples[0:MAX_LEN-1];
    reg [2*W-1:0] sample_q;
    reg [PW-1:0] pairs,concordant,discordant,tie_x,tie_y,tie_both;
    reg [2*PW-1:0] mul_acc,mul_term;
    reg [PW-1:0] mul_factor;
    reg [LW-1:0] mul_step;
    wire signed [W-1:0] old_x=sample_q[2*W-1:W],old_y=sample_q[W-1:0];
    wire equal_x=x_q==old_x,equal_y=y_q==old_y;
    wire concordance=(x_q<old_x)==(y_q<old_y);
    wire [2:0] final_errors={overflow,!y_varies,!x_varies};
    // Factors count pairs untied in the corresponding axis. Each <=Pmax,
    // including intermediate nonnegative sums, so PW low bits are exact.
    wire [PW:0] factor_x={1'b0,concordant}+{1'b0,discordant}+{1'b0,tie_y};
    wire [PW:0] factor_y={1'b0,concordant}+{1'b0,discordant}+{1'b0,tie_x};
    wire signed [PW:0] score=$signed({1'b0,concordant})-$signed({1'b0,discordant});
    wire [2*PW-1:0] mul_sum=mul_acc+(mul_factor[0]?mul_term:{2*PW{1'b0}});
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;assign m_tag=tag_q;
    assign m_pairs=(m_errors==0)?pairs:{PW{1'b0}};
    assign m_concordant=(m_errors==0)?concordant:{PW{1'b0}};
    assign m_discordant=(m_errors==0)?discordant:{PW{1'b0}};
    assign m_tie_x=(m_errors==0)?tie_x:{PW{1'b0}};
    assign m_tie_y=(m_errors==0)?tie_y:{PW{1'b0}};
    assign m_tie_both=(m_errors==0)?tie_both:{PW{1'b0}};

    // One synchronous sample read port. The current sample is written at
    // acceptance; scans address only the previously owned prefix [0,prior_count).
    always @(posedge clk)if(!rst)begin
        if(state==COLLECT && s_valid && s_ready && s_keep && count<MAX_LEN)
            samples[AW'(count)]<={s_x,s_y};
        if(state==SCAN_READ)sample_q<=samples[scan_index];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;started<=0;overflow<=0;tail_q<=0;x_varies<=0;y_varies<=0;
            count<=0;prior_count<=0;scan_index<=0;x_q<=0;y_q<=0;first_x<=0;first_y<=0;tag_q<=0;
            pairs<=0;concordant<=0;discordant<=0;tie_x<=0;tie_y<=0;tie_both<=0;
            mul_acc<=0;mul_term<=0;mul_factor<=0;mul_step<=0;
            m_score<=0;m_radicand<=0;m_errors<=0;
        end else case(state)
            COLLECT: if(s_valid && s_ready)begin
                if(!started)begin started<=1;tag_q<=s_tag;end
                if(s_keep && count<MAX_LEN)begin
                    if(count==0)begin first_x<=s_x;first_y<=s_y;end
                    else begin
                        if(s_x!=first_x)x_varies<=1;
                        if(s_y!=first_y)y_varies<=1;
                    end
                    x_q<=s_x;y_q<=s_y;tail_q<=s_last;
                    prior_count<=count;count<=count+1'b1;scan_index<=0;
                    state<=(count==0)?FINISH_SAMPLE:SCAN_READ;
                end else begin
                    if(s_keep)overflow<=1;
                    if(s_last)state<=FINALIZE;
                end
            end
            SCAN_READ: state<=SCAN_EVAL;
            SCAN_EVAL: begin
                pairs<=pairs+1'b1;
                if(equal_x && equal_y)tie_both<=tie_both+1'b1;
                else if(equal_x)tie_x<=tie_x+1'b1;
                else if(equal_y)tie_y<=tie_y+1'b1;
                else if(concordance)concordant<=concordant+1'b1;
                else discordant<=discordant+1'b1;
                if({1'b0,scan_index}==prior_count-1'b1)state<=FINISH_SAMPLE;
                else begin scan_index<=scan_index+1'b1;state<=SCAN_READ;end
            end
            FINISH_SAMPLE: state<=tail_q?FINALIZE:COLLECT;
            FINALIZE: begin
                m_errors<=final_errors;m_score<=0;m_radicand<=0;
                if(final_errors!=0)state<=EMIT;
                else begin
                    m_score<=score;mul_acc<=0;mul_term<={{PW{1'b0}},factor_x[PW-1:0]};
                    mul_factor<=factor_y[PW-1:0];mul_step<=0;state<=MUL_RUN;
                end
            end
            MUL_RUN: begin
                mul_acc<=mul_sum;mul_term<=mul_term<<1;mul_factor<=mul_factor>>1;
                if(mul_step==PW-1)begin m_radicand<=mul_sum;state<=EMIT;end
                else mul_step<=mul_step+1'b1;
            end
            EMIT: if(m_ready)begin
                state<=COLLECT;started<=0;overflow<=0;tail_q<=0;x_varies<=0;y_varies<=0;
                count<=0;prior_count<=0;scan_index<=0;
                pairs<=0;concordant<=0;discordant<=0;tie_x<=0;tie_y<=0;tie_both<=0;
            end
            default: state<=COLLECT;
        endcase
    end
    generate if(DATA_W<1 || DATA_W>32 || MAX_LEN<2 || MAX_LEN>256 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        kendall_tau_b_invalid_parameters invalid();
    end endgenerate
endmodule
`default_nettype wire
