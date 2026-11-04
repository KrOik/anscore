// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module ks_histogram_distance #(
    parameter integer KEY_W=16,FREQ_W=12,MAX_BINS=32,TAG_W=8,
    localparam integer COUNT_W=($clog2(MAX_BINS+1)<1)?1:$clog2(MAX_BINS+1),
    localparam integer TOTAL_W=($clog2(MAX_BINS*((1<<FREQ_W)-1)+1)<1)?1:
        $clog2(MAX_BINS*((1<<FREQ_W)-1)+1)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire signed [KEY_W-1:0] s_key,
    input wire [FREQ_W-1:0] s_a,s_b,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [COUNT_W-1:0] m_bins,
    output wire [TOTAL_W-1:0] m_total_a,m_total_b,
    output reg [2*TOTAL_W-1:0] m_num,m_den,m_plus,m_minus,
    output reg signed [KEY_W-1:0] m_witness_key,
    output reg [COUNT_W-1:0] m_witness_bin,
    output reg signed [1:0] m_direction,
    output wire [TAG_W-1:0] m_tag,
    output reg [3:0] m_errors
);
    localparam integer TW=TOTAL_W,DW=2*TW,RW=KEY_W+2*FREQ_W;
    localparam integer STEP_W=($clog2(TW)<1)?1:$clog2(TW);
    localparam [2:0] COLLECT=0,FINALIZE=1,MUL_RUN=2,MUL_DONE=3,
        ROW_READ=4,ROW_EVAL=5,EMIT=6;
    localparam [1:0] DENOMINATOR=0,LEFT=1,RIGHT=2;
    reg [2:0] state;
    reg started,seen_key,order_error,overflow;
    reg signed [KEY_W-1:0] last_key;
    reg [COUNT_W-1:0] bin_count,row_index;
    reg [TW-1:0] total_a,total_b,prefix_a,prefix_b;
    reg [TAG_W-1:0] tag_q;
    reg [RW-1:0] rows[0:MAX_BINS-1];
    reg [RW-1:0] row_q;
    wire signed [KEY_W-1:0] row_key=row_q[RW-1:2*FREQ_W];
    wire [TW-1:0] row_a=row_q[2*FREQ_W-1:FREQ_W],row_b=row_q[FREQ_W-1:0];
    wire [TW-1:0] input_a=s_a,input_b=s_b;
    wire [TW-1:0] next_a=prefix_a+row_a,next_b=prefix_b+row_b;
    reg [DW-1:0] mul_acc,mul_term,product,left_product;
    reg [TW-1:0] mul_factor;
    reg [STEP_W-1:0] mul_step;
    reg [1:0] mul_role;
    wire [DW-1:0] mul_sum=mul_acc+(mul_factor[0]?mul_term:{DW{1'b0}});
    // Unsigned products are explicitly made positive signed operands before
    // subtraction; the contrast retains a sign bit above the full product.
    wire signed [DW:0] difference=$signed({1'b0,left_product})-$signed({1'b0,product});
    wire [DW:0] magnitude=difference[DW]?-$signed(difference):difference;
    wire [3:0] final_errors={overflow,order_error,total_b==0,total_a==0};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_bins=bin_count;
    assign m_total_a=total_a;
    assign m_total_b=total_b;
    assign m_tag=tag_q;

    task automatic multiply(input [TW-1:0] a,b,input [1:0] role);
        begin
            mul_acc<=0;mul_term<={{TW{1'b0}},a};mul_factor<=b;
            mul_step<=0;mul_role<=role;state<=MUL_RUN;
        end
    endtask

    // Collection completes before replay. A synchronous read is consumed in
    // ROW_EVAL on the following edge; no read/write collision is required.
    always @(posedge clk)if(!rst)begin
        if(state==COLLECT && s_valid && s_ready && s_keep && bin_count<MAX_BINS)
            rows[bin_count]<={s_key,s_a,s_b};
        if(state==ROW_READ)row_q<=rows[row_index];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=COLLECT;started<=0;seen_key<=0;order_error<=0;overflow<=0;last_key<=0;
            bin_count<=0;row_index<=0;total_a<=0;total_b<=0;prefix_a<=0;prefix_b<=0;tag_q<=0;
            mul_acc<=0;mul_term<=0;mul_factor<=0;mul_step<=0;mul_role<=0;product<=0;left_product<=0;
            m_num<=0;m_den<=0;m_plus<=0;m_minus<=0;m_witness_key<=0;m_witness_bin<=0;m_direction<=0;m_errors<=0;
        end else case(state)
            COLLECT: if(s_valid && s_ready)begin
                if(!started)begin started<=1;tag_q<=s_tag;end
                if(s_keep)begin
                    if(seen_key && s_key<=last_key)order_error<=1;
                    seen_key<=1;last_key<=s_key;
                    if(bin_count==MAX_BINS)overflow<=1;
                    else begin bin_count<=bin_count+1'b1;total_a<=total_a+input_a;total_b<=total_b+input_b;end
                end
                if(s_last)state<=FINALIZE;
            end
            FINALIZE: begin
                m_errors<=final_errors;m_num<=0;m_den<=0;m_plus<=0;m_minus<=0;
                m_witness_key<=0;m_witness_bin<=0;m_direction<=0;
                if(final_errors!=0)state<=EMIT;
                else begin prefix_a<=0;prefix_b<=0;row_index<=0;multiply(total_a,total_b,DENOMINATOR);end
            end
            MUL_RUN: begin
                if(mul_step==TW-1)begin product<=mul_sum;state<=MUL_DONE;end
                else begin
                    mul_acc<=mul_sum;mul_term<=mul_term<<1;
                    mul_factor<=mul_factor>>1;mul_step<=mul_step+1'b1;
                end
            end
            MUL_DONE: case(mul_role)
                DENOMINATOR: begin m_den<=product;state<=ROW_READ;end
                LEFT: begin left_product<=product;multiply(prefix_b,total_a,RIGHT);end
                RIGHT: begin
                    if(difference>0 && magnitude>{1'b0,m_plus})m_plus<=magnitude[DW-1:0];
                    if(difference<0 && magnitude>{1'b0,m_minus})m_minus<=magnitude[DW-1:0];
                    // Strict improvement keeps the earliest supplied key on
                    // equal absolute extrema, including opposite-sign ties.
                    if(magnitude>{1'b0,m_num})begin
                        m_num<=magnitude[DW-1:0];m_witness_key<=row_key;
                        m_witness_bin<=row_index;m_direction<=difference[DW]?-2'sd1:2'sd1;
                    end
                    if(row_index==bin_count-1'b1)state<=EMIT;
                    else begin row_index<=row_index+1'b1;state<=ROW_READ;end
                end
                default: state<=FINALIZE;
            endcase
            ROW_READ: state<=ROW_EVAL;
            ROW_EVAL: begin
                prefix_a<=next_a;prefix_b<=next_b;
                if(row_index==0)begin m_witness_key<=row_key;m_witness_bin<=0;end
                multiply(next_a,total_b,LEFT);
            end
            EMIT: if(m_ready)begin
                state<=COLLECT;started<=0;seen_key<=0;order_error<=0;overflow<=0;
                bin_count<=0;total_a<=0;total_b<=0;
            end
            default: state<=COLLECT;
        endcase
    end
    generate if(KEY_W<1 || KEY_W>32 || FREQ_W<1 || FREQ_W>16 ||
                 MAX_BINS<1 || MAX_BINS>128 || TAG_W<1 || TAG_W>32)begin: invalid_parameters
        ks_histogram_distance_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
`default_nettype wire
