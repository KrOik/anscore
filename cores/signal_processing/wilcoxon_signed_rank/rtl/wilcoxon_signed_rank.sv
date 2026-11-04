// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module wilcoxon_signed_rank #(
    parameter integer DATA_W=16,MAX_LEN=16,TAG_W=8,
    localparam integer COUNT_W=($clog2(MAX_LEN+1)<1)?1:$clog2(MAX_LEN+1),
    localparam integer SUM_W=($clog2(MAX_LEN*(MAX_LEN+1)+1)<1)?1:
        $clog2(MAX_LEN*(MAX_LEN+1)+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [DATA_W-1:0] s_x,s_y,
    input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [COUNT_W-1:0] m_count,m_nonzero,m_zeros,m_positive,m_negative,
    output reg [COUNT_W-1:0] m_tied,
    output reg [SUM_W-1:0] m_plus2,m_minus2,m_stat2,
    output wire [TAG_W-1:0] m_tag,output reg [1:0] m_errors
);
    localparam integer CW=COUNT_W,RW=CW+1;
    localparam [3:0] COLLECT=0,FINALIZE=1,TARGET_READ=2,TARGET_SETUP=3,
        SCAN_READ=4,SCAN_EVAL=5,ACCUMULATE=6,FINISH=7,EMIT=8;
    reg [3:0] state;
    reg started,overflow;
    reg [CW-1:0] count,nonzero,positive,negative,target_index,scan_index,less_count,equal_count;
    reg [TAG_W-1:0] tag_q;
    reg [DATA_W:0] entries[0:MAX_LEN-1];
    reg [DATA_W:0] read_q,target_q;
    // Extend each signed raw operand before subtracting. Even the full-range
    // negative difference has magnitude <=2^DATA_W-1, fitting unsigned DATA_W.
    wire signed [DATA_W:0] input_diff=$signed({s_x[DATA_W-1],s_x})-
        $signed({s_y[DATA_W-1],s_y});
    wire [DATA_W:0] input_abs=input_diff[DATA_W]?-input_diff:input_diff;
    wire [DATA_W-1:0] sample_magnitude=read_q[DATA_W-1:0];
    wire [DATA_W-1:0] target_magnitude=target_q[DATA_W-1:0];
    // Equal includes the target itself. Its average 1-based rank is
    // less+(equal+1)/2, so this doubled rank has no fractional loss.
    wire [RW-1:0] rank2=({1'b0,less_count}<<1)+{1'b0,equal_count}+{{CW{1'b0}},1'b1};
    wire [1:0] final_errors={overflow,nonzero==0};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;assign m_nonzero=nonzero;assign m_zeros=count-nonzero;
    assign m_positive=positive;assign m_negative=negative;assign m_tag=tag_q;

    // One synchronous read port shared by target and scan reads. Collection
    // finishes before replay; no simultaneous read/write behavior is assumed.
    always @(posedge clk)if(!rst)begin
        if(state==COLLECT && s_valid && s_ready && s_keep && count<MAX_LEN && input_diff!=0)
            entries[nonzero]<={input_diff[DATA_W],input_abs[DATA_W-1:0]};
        if(state==TARGET_READ)read_q<=entries[target_index];
        if(state==SCAN_READ)read_q<=entries[scan_index];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;started<=0;overflow<=0;count<=0;nonzero<=0;positive<=0;negative<=0;
            target_index<=0;scan_index<=0;less_count<=0;equal_count<=0;target_q<=0;tag_q<=0;
            m_plus2<=0;m_minus2<=0;m_stat2<=0;m_tied<=0;m_errors<=0;
        end else case(state)
            COLLECT: if(s_valid && s_ready)begin
                if(!started)begin started<=1;tag_q<=s_tag;end
                if(s_keep)begin
                    if(count==MAX_LEN)overflow<=1;
                    else begin
                        count<=count+1'b1;
                        if(input_diff!=0)begin
                            nonzero<=nonzero+1'b1;
                            if(input_diff[DATA_W])negative<=negative+1'b1;
                            else positive<=positive+1'b1;
                        end
                    end
                end
                if(s_last)state<=FINALIZE;
            end
            FINALIZE: begin
                m_errors<=final_errors;m_plus2<=0;m_minus2<=0;m_stat2<=0;m_tied<=0;
                target_index<=0;
                state<=(final_errors!=0)?EMIT:TARGET_READ;
            end
            TARGET_READ: state<=TARGET_SETUP;
            TARGET_SETUP: begin
                target_q<=read_q;less_count<=0;equal_count<=0;scan_index<=0;state<=SCAN_READ;
            end
            SCAN_READ: state<=SCAN_EVAL;
            SCAN_EVAL: begin
                if(sample_magnitude<target_magnitude)less_count<=less_count+1'b1;
                if(sample_magnitude==target_magnitude)equal_count<=equal_count+1'b1;
                if(scan_index==nonzero-1'b1)state<=ACCUMULATE;
                else begin scan_index<=scan_index+1'b1;state<=SCAN_READ;end
            end
            ACCUMULATE: begin
                if(target_q[DATA_W])m_minus2<=m_minus2+rank2;
                else m_plus2<=m_plus2+rank2;
                if(equal_count>1)m_tied<=m_tied+1'b1;
                if(target_index==nonzero-1'b1)state<=FINISH;
                else begin target_index<=target_index+1'b1;state<=TARGET_READ;end
            end
            FINISH: begin m_stat2<=(m_plus2<m_minus2)?m_plus2:m_minus2;state<=EMIT;end
            EMIT: if(m_ready)begin
                state<=COLLECT;started<=0;overflow<=0;count<=0;nonzero<=0;positive<=0;negative<=0;
            end
            default: state<=COLLECT;
        endcase
    end
    generate if(DATA_W<1 || DATA_W>32 || MAX_LEN<1 || MAX_LEN>64 || TAG_W<1 || TAG_W>32)
        begin: invalid_parameters
            wilcoxon_signed_rank_invalid_parameters invalid_configuration();
        end
    endgenerate
endmodule
`default_nettype wire
