// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module weighted_isotonic #(
    parameter integer DATA_W=16,WEIGHT_W=8,MAX_LEN=16,TAG_W=8,
    localparam integer GROW=(MAX_LEN<2)?0:$clog2(MAX_LEN),
    localparam integer COUNT_W=(MAX_LEN<2)?1:$clog2(MAX_LEN+1),
    localparam integer SUM_W=DATA_W+WEIGHT_W+1+GROW,
    localparam integer TOTAL_W=WEIGHT_W+GROW
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire signed [DATA_W-1:0] s_value,
    input wire [WEIGHT_W-1:0] s_weight,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire m_keep,
    output reg m_last,
    output reg signed [SUM_W-1:0] m_numerator,
    output reg [TOTAL_W-1:0] m_denominator,
    output reg [COUNT_W-1:0] m_start,m_length,
    output wire [COUNT_W-1:0] m_count,m_block_count,m_block_index,
    output wire [TAG_W-1:0] m_tag,
    output reg [2:0] m_errors
);
    localparam integer PW=DATA_W+WEIGHT_W+1;
    localparam integer AW=(MAX_LEN<2)?1:$clog2(MAX_LEN);
    localparam integer NODE_W=SUM_W+TOTAL_W+COUNT_W;
    localparam integer CROSS_W=SUM_W+TOTAL_W;
    localparam integer BIT_W=(TOTAL_W<2)?1:$clog2(TOTAL_W);
    localparam [4:0] COLLECT=0,MULTIPLY=1,PUSH=2,AFTER_PUSH=3,
        READ_LEFT=4,READ_RIGHT=5,PAIR_CHECK=6,CMP_INIT=7,CMP_RUN=8,
        CMP_DECIDE=9,MERGE=10,ORDERED=11,FINALIZE=12,
        OUT_READ=13,OUT_LOAD=14,OUT_HOLD=15,ERROR_HOLD=16;
    reg [4:0] state;
    reg started,over_capacity,zero_weight,tail_q;
    reg [COUNT_W-1:0] count,depth,out_index,emit_start;
    reg [TAG_W-1:0] tag_q;
    reg signed [DATA_W-1:0] value_q;
    reg [WEIGHT_W-1:0] weight_q;
    reg signed [PW-1:0] product_q;
    reg [NODE_W-1:0] stack [0:MAX_LEN-1];
    reg [NODE_W-1:0] ram_q,left_q;
    wire signed [SUM_W-1:0] left_sum=left_q[NODE_W-1:TOTAL_W+COUNT_W];
    wire signed [SUM_W-1:0] right_sum=ram_q[NODE_W-1:TOTAL_W+COUNT_W];
    wire [TOTAL_W-1:0] left_weight=left_q[TOTAL_W+COUNT_W-1:COUNT_W];
    wire [TOTAL_W-1:0] right_weight=ram_q[TOTAL_W+COUNT_W-1:COUNT_W];
    wire [COUNT_W-1:0] left_length=left_q[COUNT_W-1:0];
    wire [COUNT_W-1:0] right_length=ram_q[COUNT_W-1:0];
    wire [SUM_W-1:0] left_magnitude=left_sum[SUM_W-1]?(~left_sum+1'b1):left_sum;
    wire [SUM_W-1:0] right_magnitude=right_sum[SUM_W-1]?(~right_sum+1'b1):right_sum;
    reg second_product;
    reg [BIT_W-1:0] bit_count;
    reg [CROSS_W-1:0] product_acc,shifted,left_cross,right_cross;
    reg [TOTAL_W-1:0] multiplier;
    // A conventional full-width serial multiplication adder is reused for
    // the two magnitude cross products. Both products are kept exact.
    wire [CROSS_W-1:0] product_next=product_acc+
        (multiplier[0]?shifted:{CROSS_W{1'b0}});
    wire [2:0] final_errors={zero_weight,over_capacity,count==0};
    reg mem_read,mem_write;
    reg [AW-1:0] read_address,write_address;
    reg [NODE_W-1:0] write_data;
    always @* begin
        mem_read=0;mem_write=0;read_address=0;write_address=0;write_data=0;
        case (state)
            PUSH: begin
                mem_write=1;write_address=AW'(depth);
                write_data={{{GROW{product_q[PW-1]}},product_q},
                    {{GROW{1'b0}},weight_q},{{(COUNT_W-1){1'b0}},1'b1}};
            end
            READ_LEFT: begin mem_read=1;read_address=AW'(depth-2);end
            READ_RIGHT: begin mem_read=1;read_address=AW'(depth-1);end
            MERGE: begin
                mem_write=1;write_address=AW'(depth-2);
                write_data={left_sum+right_sum,left_weight+right_weight,left_length+right_length};
            end
            OUT_READ: begin mem_read=1;read_address=AW'(out_index);end
            default: begin end
        endcase
    end
    always @(posedge clk) begin
        if (!rst) begin
            if (mem_write) stack[write_address]<=write_data;
            if (mem_read) ram_q<=stack[read_address];
        end
    end
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && (state==OUT_HOLD || state==ERROR_HOLD);
    assign m_keep=state==OUT_HOLD;
    assign m_count=count;
    assign m_block_count=(m_errors==0)?depth:{COUNT_W{1'b0}};
    assign m_block_index=out_index;
    assign m_tag=tag_q;
    always @(posedge clk) begin
        if (rst) begin
            state<=COLLECT;started<=0;over_capacity<=0;zero_weight<=0;tail_q<=0;
            count<=0;depth<=0;out_index<=0;emit_start<=0;tag_q<=0;
            value_q<=0;weight_q<=0;product_q<=0;second_product<=0;bit_count<=0;
            product_acc<=0;shifted<=0;left_cross<=0;right_cross<=0;multiplier<=0;
            m_last<=0;m_numerator<=0;m_denominator<=0;m_start<=0;m_length<=0;m_errors<=0;
        end else begin
            case (state)
                COLLECT: if (s_valid && s_ready) begin
                    if (!started) begin started<=1;tag_q<=s_tag;end
                    if (s_last) state<=FINALIZE;
                    if (s_keep && s_weight==0) zero_weight<=1;
                    if (s_keep) begin
                        if (count==MAX_LEN) over_capacity<=1;
                        else begin
                            count<=count+1'b1;
                            if (s_weight!=0 && !zero_weight && !over_capacity) begin
                                value_q<=s_value;weight_q<=s_weight;tail_q<=s_last;
                                state<=MULTIPLY;
                            end
                        end
                    end
                end
                MULTIPLY: begin
                    product_q<=value_q*$signed({1'b0,weight_q});state<=PUSH;
                end
                PUSH: begin depth<=depth+1'b1;state<=AFTER_PUSH;end
                AFTER_PUSH: begin
                    if (depth>=2) state<=READ_LEFT;
                    else state<=tail_q?FINALIZE:COLLECT;
                end
                READ_LEFT: state<=READ_RIGHT;
                READ_RIGHT: begin left_q<=ram_q;state<=PAIR_CHECK;end
                PAIR_CHECK: begin
                    if (left_sum[SUM_W-1]!=right_sum[SUM_W-1])
                        state<=left_sum[SUM_W-1]?ORDERED:MERGE;
                    else state<=CMP_INIT;
                end
                CMP_INIT: begin
                    shifted<={{TOTAL_W{1'b0}},left_magnitude};multiplier<=right_weight;
                    product_acc<=0;bit_count<=0;second_product<=0;state<=CMP_RUN;
                end
                CMP_RUN: begin
                    product_acc<=product_next;shifted<=shifted<<1;multiplier<=multiplier>>1;
                    if (bit_count==TOTAL_W-1) begin
                        if (!second_product) begin
                            left_cross<=product_next;product_acc<=0;
                            shifted<={{TOTAL_W{1'b0}},right_magnitude};multiplier<=left_weight;
                            bit_count<=0;second_product<=1;
                        end else begin right_cross<=product_next;state<=CMP_DECIDE;end
                    end else bit_count<=bit_count+1'b1;
                end
                CMP_DECIDE: begin
                    if (left_sum[SUM_W-1]?(left_cross<=right_cross):(left_cross>=right_cross))
                        state<=MERGE;
                    else state<=ORDERED;
                end
                MERGE: begin depth<=depth-1'b1;state<=AFTER_PUSH;end
                ORDERED: state<=tail_q?FINALIZE:COLLECT;
                FINALIZE: begin
                    m_errors<=final_errors;out_index<=0;emit_start<=0;
                    if (final_errors!=0) begin
                        m_numerator<=0;m_denominator<=0;m_start<=0;m_length<=0;m_last<=1;
                        state<=ERROR_HOLD;
                    end else state<=OUT_READ;
                end
                OUT_READ: state<=OUT_LOAD;
                OUT_LOAD: begin
                    m_numerator<=ram_q[NODE_W-1:TOTAL_W+COUNT_W];
                    m_denominator<=ram_q[TOTAL_W+COUNT_W-1:COUNT_W];
                    m_length<=ram_q[COUNT_W-1:0];m_start<=emit_start;
                    m_last<=out_index==depth-1'b1;state<=OUT_HOLD;
                end
                OUT_HOLD: if (m_ready) begin
                    if (m_last) begin
                        state<=COLLECT;started<=0;over_capacity<=0;zero_weight<=0;
                        count<=0;depth<=0;
                    end else begin
                        emit_start<=emit_start+m_length;out_index<=out_index+1'b1;state<=OUT_READ;
                    end
                end
                ERROR_HOLD: if (m_ready) begin
                    state<=COLLECT;started<=0;over_capacity<=0;zero_weight<=0;count<=0;depth<=0;
                end
                default: state<=COLLECT;
            endcase
        end
    end
    generate if (DATA_W<1 || DATA_W>24 || WEIGHT_W<1 || WEIGHT_W>16 ||
                 MAX_LEN<1 || MAX_LEN>64 || TAG_W<1 || TAG_W>32) begin : invalid_parameters
        weighted_isotonic_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
