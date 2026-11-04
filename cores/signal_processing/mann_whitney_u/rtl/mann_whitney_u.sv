// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module mann_whitney_u #(
    parameter integer DATA_W=16,MAX_LEN=32,FRAC=16,TAG_W=8,
    localparam integer COUNT_W=(MAX_LEN<2)?1:$clog2(MAX_LEN+1),
    localparam integer PAIR_W=($clog2(2*((MAX_LEN*MAX_LEN)/4)+1)<1)?1:
        $clog2(2*((MAX_LEN*MAX_LEN)/4)+1)
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire signed [DATA_W-1:0] s_value,
    input wire s_group, // 0=A, 1=B; significant on each kept member
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [COUNT_W-1:0] m_count,m_count_a,m_count_b,
    output wire [PAIR_W-1:0] m_pairs,m_wins,m_losses,m_ties,m_u2,
    output reg signed [FRAC+1:0] m_rank_biserial,
    output wire [TAG_W-1:0] m_tag,
    output reg [2:0] m_errors
);
    localparam integer IW=(MAX_LEN<2)?1:$clog2(MAX_LEN);
    localparam integer AW=PAIR_W+1,OUT_W=FRAC+2;
    localparam [2:0] COLLECT=0,SCAN_READ=1,SCAN_CHECK=2,FINISH_SAMPLE=3,
        FINALIZE=4,DIV_SEND=5,DIV_WAIT=6,EMIT=7;
    reg [2:0] state;
    reg started,over_capacity,group_q,tail_q;
    reg signed [DATA_W-1:0] value_q;
    reg [COUNT_W-1:0] count,count_a,count_b,prior_count;
    reg [IW-1:0] scan_index;
    reg [PAIR_W-1:0] pairs,wins,losses,ties;
    reg [TAG_W-1:0] tag_q;
    reg [DATA_W:0] samples[0:MAX_LEN-1];
    reg [DATA_W:0] sample_q;
    wire signed [DATA_W-1:0] old_value=sample_q[DATA_W-1:0];
    wire same_value=value_q==old_value;
    wire new_less=value_q<old_value;
    wire a_wins=group_q?new_less:(!new_less && !same_value);
    wire [2:0] final_errors={over_capacity,count_b==0,count_a==0};
    reg signed [AW-1:0] numerator_q;
    reg [AW-1:0] denominator_q;
    wire signed [AW-1:0] contrast=$signed({1'b0,wins})-$signed({1'b0,losses});
    wire [PAIR_W-1:0] doubled_u=(wins<<1)+ties;
    wire div_ready,div_valid;
    wire [OUT_W-1:0] div_result;
    wire [1:0] div_flags;
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;
    assign m_count_a=count_a;
    assign m_count_b=count_b;
    assign m_pairs=(m_errors==0)?pairs:{PAIR_W{1'b0}};
    assign m_wins=(m_errors==0)?wins:{PAIR_W{1'b0}};
    assign m_losses=(m_errors==0)?losses:{PAIR_W{1'b0}};
    assign m_ties=(m_errors==0)?ties:{PAIR_W{1'b0}};
    assign m_u2=(m_errors==0)?doubled_u:{PAIR_W{1'b0}};
    assign m_tag=tag_q;
    fp_div_iter #(.AW(AW),.BW(AW),.FB(FRAC),.OUT_W(OUT_W)) divider(
        .clk(clk),.rst_n(!rst),.s_tdata({denominator_q,numerator_q}),
        .s_tvalid(state==DIV_SEND && !rst),.s_tready(div_ready),
        .m_tdata(div_result),.m_tuser(div_flags),.m_tvalid(div_valid),
        .m_tready(state==DIV_WAIT && !rst)
    );
    // Each sample is written once before any later sample can scan it. The
    // current sample's index is excluded from its scan, so no RAM collision.
    always @(posedge clk) if (!rst) begin
        if (state==COLLECT && s_valid && s_ready && s_keep && count<MAX_LEN && !over_capacity)
            samples[IW'(count)]<={s_group,s_value};
        if (state==SCAN_READ) sample_q<=samples[scan_index];
    end
    always @(posedge clk) begin
        if (rst) begin
            state<=COLLECT;started<=0;over_capacity<=0;group_q<=0;tail_q<=0;
            value_q<=0;count<=0;count_a<=0;count_b<=0;prior_count<=0;scan_index<=0;
            pairs<=0;wins<=0;losses<=0;ties<=0;tag_q<=0;
            numerator_q<=0;denominator_q<=0;m_rank_biserial<=0;m_errors<=0;
        end else begin
            case (state)
                COLLECT: if (s_valid && s_ready) begin
                    if (!started) begin started<=1;tag_q<=s_tag;end
                    if (s_last) state<=FINALIZE;
                    if (s_keep) begin
                        if (count==MAX_LEN) over_capacity<=1;
                        else begin
                            count<=count+1'b1;
                            if (s_group) count_b<=count_b+1'b1;
                            else count_a<=count_a+1'b1;
                            value_q<=s_value;group_q<=s_group;tail_q<=s_last;
                            prior_count<=count;scan_index<=0;
                            state<=(count==0)?FINISH_SAMPLE:SCAN_READ;
                        end
                    end
                end
                SCAN_READ: state<=SCAN_CHECK;
                SCAN_CHECK: begin
                    if (sample_q[DATA_W]!=group_q) begin
                        pairs<=pairs+1'b1;
                        if (same_value) ties<=ties+1'b1;
                        else if (a_wins) wins<=wins+1'b1;
                        else losses<=losses+1'b1;
                    end
                    if (scan_index==prior_count-1'b1) state<=FINISH_SAMPLE;
                    else begin scan_index<=scan_index+1'b1;state<=SCAN_READ;end
                end
                FINISH_SAMPLE: state<=tail_q?FINALIZE:COLLECT;
                FINALIZE: begin
                    m_errors<=final_errors;
                    if (final_errors!=0) begin m_rank_biserial<=0;state<=EMIT;end
                    else begin
                        numerator_q<=contrast;denominator_q<={1'b0,pairs};state<=DIV_SEND;
                    end
                end
                DIV_SEND: if (div_ready) state<=DIV_WAIT;
                DIV_WAIT: if (div_valid) begin m_rank_biserial<=div_result;state<=EMIT;end
                EMIT: if (m_ready) begin
                    state<=COLLECT;started<=0;over_capacity<=0;
                    count<=0;count_a<=0;count_b<=0;pairs<=0;wins<=0;losses<=0;ties<=0;
                end
                default: state<=COLLECT;
            endcase
        end
    end
    generate if (DATA_W<1 || DATA_W>32 || MAX_LEN<1 || MAX_LEN>128 ||
                 FRAC<0 || FRAC>24 || TAG_W<1 || TAG_W>32) begin : invalid_parameters
        mann_whitney_u_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
