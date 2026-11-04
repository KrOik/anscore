// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module label_adjusted_rand #(
    parameter integer WIDTH=64,HEIGHT=64,LABEL_W=4,LABELS=16,TAG_W=8,
    localparam integer PIXELS=WIDTH*HEIGHT,
    localparam integer COUNT_W=$clog2(PIXELS+1),
    localparam [63:0] MAX_PAIRS=(64'd1*PIXELS*(PIXELS-1))/2,
    localparam integer PAIR_W=(MAX_PAIRS<1)?1:$clog2(MAX_PAIRS+1),
    localparam integer NUM_W=2*PAIR_W+2,DEN_W=2*PAIR_W+1
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [LABEL_W-1:0] s_a,s_b,
    input wire s_keep,s_sof,s_eol,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [NUM_W-1:0] m_ari_numerator,
    output reg [DEN_W-1:0] m_ari_denominator,
    output reg [COUNT_W-1:0] m_count,
    output reg [PAIR_W-1:0] m_pairs,m_same_a,m_same_b,m_same_both,
    output reg m_equivalent,m_degenerate,
    output reg [1:0] m_errors,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer TABLE=LABELS*LABELS;
    localparam integer TABLE_AW=(TABLE<2)?1:$clog2(TABLE);
    localparam integer XW=(WIDTH<2)?1:$clog2(WIDTH),YW=(HEIGHT<2)?1:$clog2(HEIGHT);
    localparam integer MW=PAIR_W+1,PRODUCT_W=2*MW;
    localparam integer BIT_W=(MW<2)?1:$clog2(MW);
    localparam [2:0] CLEAR=0,COLLECT=1,UPDATE=2,FINALIZE=3,
        MUL_SETUP=4,MUL_RUN=5,COMMIT=6,EMIT=7;
    reg [2:0] state;
    reg [COUNT_W-1:0] joint[0:TABLE-1],marginal_a[0:LABELS-1],marginal_b[0:LABELS-1];
    reg [COUNT_W-1:0] joint_q,a_q,b_q;
    reg [LABEL_W-1:0] a_q_label,b_q_label;
    reg [TABLE_AW-1:0] clear_address,pending_slot;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg tail_q;
    wire labels_ok=s_a<LABELS && s_b<LABELS;
    wire markers_ok=s_sof==(x==0 && y==0) && s_eol==(x==WIDTH-1);
    wire tail=x==WIDTH-1 && y==HEIGHT-1;
    wire accept=s_valid && s_ready;
    wire process_token=accept && s_keep && labels_ok && markers_ok && m_errors==0;
    function automatic [TABLE_AW-1:0] pair_slot;
        input [LABEL_W-1:0] a,b;
        integer k;
        reg [TABLE_AW-1:0] offset;
        begin
            offset=0;
            for(k=0;k<7;k=k+1)
                if((LABELS>>k)&1) offset=offset+(TABLE_AW'(a)<<k);
            pair_slot=offset+TABLE_AW'(b);
        end
    endfunction
    // Three separate single-port memories. Every read and its incrementing
    // write occur on different clocks; no read-during-write mode is assumed.
    always @(posedge clk) if(!rst) begin
        if(state==CLEAR) begin
            joint[clear_address]<=0;
            if(clear_address<LABELS) begin
                marginal_a[clear_address]<=0;marginal_b[clear_address]<=0;
            end
        end
        if(process_token) begin
            joint_q<=joint[pair_slot(s_a,s_b)];
            a_q<=marginal_a[s_a];b_q<=marginal_b[s_b];
        end
        if(state==UPDATE) begin
            joint[pending_slot]<=joint_q+1'b1;
            marginal_a[a_q_label]<=a_q+1'b1;marginal_b[b_q_label]<=b_q+1'b1;
        end
    end
    reg [1:0] operation;
    reg [BIT_W-1:0] bit_count;
    reg [PRODUCT_W-1:0] mul_acc,mul_shift,pa,bc,pbc_sum;
    reg [MW-1:0] mul_factor;
    wire [MW-1:0] factor_left=(operation==1)?{1'b0,m_same_a}:{1'b0,m_pairs};
    wire [MW-1:0] factor_right=(operation==0)?{1'b0,m_same_both}:
        (operation==1)?{1'b0,m_same_b}:({1'b0,m_same_a}+{1'b0,m_same_b});
    wire [PRODUCT_W-1:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:{PRODUCT_W{1'b0}});
    wire signed [PRODUCT_W:0] difference=$signed({1'b0,pa})-$signed({1'b0,bc});
    wire signed [PRODUCT_W+1:0] numerator_wide=
        $signed({difference[PRODUCT_W],difference})<<<1;
    wire [PRODUCT_W-1:0] denominator_wide=pbc_sum-(bc<<1);
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    always @(posedge clk) begin
        if(rst) begin
            state<=CLEAR;clear_address<=0;pending_slot<=0;x<=0;y<=0;tail_q<=0;
            a_q_label<=0;b_q_label<=0;operation<=0;bit_count<=0;
            mul_acc<=0;mul_shift<=0;mul_factor<=0;pa<=0;bc<=0;pbc_sum<=0;
            m_ari_numerator<=0;m_ari_denominator<=0;m_count<=0;m_pairs<=0;
            m_same_a<=0;m_same_b<=0;m_same_both<=0;m_equivalent<=0;m_degenerate<=0;
            m_errors<=0;m_tag<=0;
        end else case(state)
            CLEAR: begin
                if(clear_address==TABLE-1) state<=COLLECT;
                else clear_address<=clear_address+1'b1;
            end
            COLLECT: if(accept) begin
                if(x==0 && y==0) m_tag<=s_tag;
                if(!markers_ok) m_errors[0]<=1;
                if(s_keep && !labels_ok) m_errors[1]<=1;
                if(x==WIDTH-1) begin x<=0;y<=(y==HEIGHT-1)?0:y+1'b1;end
                else x<=x+1'b1;
                tail_q<=tail;
                if(process_token) begin
                    a_q_label<=s_a;b_q_label<=s_b;pending_slot<=pair_slot(s_a,s_b);
                    state<=UPDATE;
                end else if(tail) state<=FINALIZE;
            end
            UPDATE: begin
                // Adding an existing population counts exactly the new pairs.
                m_pairs<=m_pairs+PAIR_W'(m_count);m_count<=m_count+1'b1;
                m_same_a<=m_same_a+PAIR_W'(a_q);
                m_same_b<=m_same_b+PAIR_W'(b_q);
                m_same_both<=m_same_both+PAIR_W'(joint_q);
                state<=tail_q?FINALIZE:COLLECT;
            end
            FINALIZE: begin
                if(m_errors!=0) begin
                    m_ari_numerator<=0;m_ari_denominator<=0;m_count<=0;m_pairs<=0;
                    m_same_a<=0;m_same_b<=0;m_same_both<=0;m_equivalent<=0;m_degenerate<=0;
                    state<=EMIT;
                end else begin operation<=0;state<=MUL_SETUP;end
            end
            MUL_SETUP: begin
                mul_acc<=0;mul_shift<={{MW{1'b0}},factor_left};
                mul_factor<=factor_right;bit_count<=0;state<=MUL_RUN;
            end
            MUL_RUN: begin
                mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
                if(bit_count==MW-1) begin
                    case(operation)
                        0:pa<=mul_next;
                        1:bc<=mul_next;
                        default:pbc_sum<=mul_next;
                    endcase
                    if(operation==2) state<=COMMIT;
                    else begin operation<=operation+1'b1;state<=MUL_SETUP;end
                end else bit_count<=bit_count+1'b1;
            end
            COMMIT: begin
                m_equivalent<=m_same_a==m_same_both && m_same_b==m_same_both;
                m_degenerate<=denominator_wide==0;
                if(denominator_wide==0) begin m_ari_numerator<=1;m_ari_denominator<=1;end
                else begin
                    // Proven bounds retain the exact signed numerator and
                    // nonnegative denominator; no rounding or clipping.
                    m_ari_numerator<=numerator_wide[NUM_W-1:0];
                    m_ari_denominator<=denominator_wide[DEN_W-1:0];
                end
                state<=EMIT;
            end
            EMIT: if(m_ready) begin
                state<=CLEAR;clear_address<=0;x<=0;y<=0;m_errors<=0;
                m_count<=0;m_pairs<=0;m_same_a<=0;m_same_b<=0;m_same_both<=0;
            end
            default: state<=CLEAR;
        endcase
    end
    generate if(WIDTH<1 || WIDTH>1024 || HEIGHT<1 || HEIGHT>1024 ||
                LABEL_W<1 || LABEL_W>8 || LABELS<1 || LABELS>64 ||
                LABELS>(1<<LABEL_W) || TAG_W<1 || TAG_W>32) begin : invalid_parameters
        label_adjusted_rand_invalid_parameters__see_README invalid_configuration();
    end endgenerate
endmodule
