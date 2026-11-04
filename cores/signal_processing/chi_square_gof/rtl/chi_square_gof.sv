// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module chi_square_gof #(
    parameter integer DATA_W=16,
    parameter integer MAX_BINS=16,
    parameter integer FRAC=16,
    parameter integer TAG_W=8,
    localparam integer GROW=(MAX_BINS<2)?0:$clog2(MAX_BINS),
    localparam integer COUNT_W=(MAX_BINS<2)?1:$clog2(MAX_BINS+1),
    localparam integer MASS_W=DATA_W+GROW,
    localparam integer STAT_W=2*DATA_W+FRAC+GROW
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire [DATA_W-1:0] s_observed,s_expected,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg [STAT_W-1:0] m_statistic,
    output wire [COUNT_W-1:0] m_count,m_active,m_df,
    output wire [MASS_W-1:0] m_sum_observed,m_sum_expected,
    output wire [TAG_W-1:0] m_tag,
    output reg [4:0] m_errors
);
    localparam integer AW=2*DATA_W+1,BW=DATA_W+1;
    localparam integer TERM_W=2*DATA_W+FRAC+1;
    localparam [2:0] COLLECT=0,MULTIPLY=1,DIV_SEND=2,DIV_WAIT=3,
        FINALIZE=4,EMIT=5;
    reg [2:0] state;
    reg started,over_capacity,zero_expected,tail_q;
    reg [COUNT_W-1:0] count,active;
    reg [MASS_W-1:0] sum_observed,sum_expected;
    reg [TAG_W-1:0] tag_q;
    reg [DATA_W-1:0] difference_q,expected_q;
    reg [2*DATA_W-1:0] square_q;
    reg [STAT_W-1:0] statistic;
    wire div_ready,div_valid;
    wire [TERM_W-1:0] div_result;
    wire [1:0] div_flags;
    wire [4:0] final_errors={active<2,sum_observed!=sum_expected,
        zero_expected,over_capacity,count==0};
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    assign m_count=count;
    assign m_active=active;
    assign m_df=(active>=2)?active-1'b1:{COUNT_W{1'b0}};
    assign m_sum_observed=sum_observed;
    assign m_sum_expected=sum_expected;
    assign m_tag=tag_q;

    // Both signed operands have an explicit positive sign bit. No legal
    // transaction reaches division with expected_q=0 or needs saturation.
    fp_div_iter #(.AW(AW),.BW(BW),.FB(FRAC),.OUT_W(TERM_W)) divider(
        .clk(clk),.rst_n(!rst),
        .s_tdata({1'b0,expected_q,1'b0,square_q}),
        .s_tvalid(state==DIV_SEND && !rst),.s_tready(div_ready),
        .m_tdata(div_result),.m_tuser(div_flags),.m_tvalid(div_valid),
        .m_tready(state==DIV_WAIT && !rst)
    );

    always @(posedge clk) begin
        if (rst) begin
            state<=COLLECT;started<=0;over_capacity<=0;zero_expected<=0;
            tail_q<=0;count<=0;active<=0;sum_observed<=0;sum_expected<=0;
            tag_q<=0;difference_q<=0;expected_q<=0;square_q<=0;
            statistic<=0;m_statistic<=0;m_errors<=0;
        end else begin
            case (state)
                COLLECT: if (s_valid && s_ready) begin
                    if (!started) begin started<=1;tag_q<=s_tag;end
                    if (s_last) state<=FINALIZE;
                    // This domain predicate is still checked on excess bins.
                    if (s_keep && s_expected==0 && s_observed!=0)
                        zero_expected<=1;
                    if (s_keep) begin
                        if (count==MAX_BINS) over_capacity<=1;
                        else begin
                            count<=count+1'b1;
                            sum_observed<=sum_observed+{{GROW{1'b0}},s_observed};
                            sum_expected<=sum_expected+{{GROW{1'b0}},s_expected};
                            if (s_expected!=0) begin
                                active<=active+1'b1;
                                if (!over_capacity && !zero_expected) begin
                                    difference_q<=(s_observed>=s_expected)?
                                        s_observed-s_expected:s_expected-s_observed;
                                    expected_q<=s_expected;tail_q<=s_last;
                                    state<=MULTIPLY;
                                end
                            end
                        end
                    end
                end
                MULTIPLY: begin
                    square_q<=difference_q*difference_q;
                    state<=DIV_SEND;
                end
                DIV_SEND: if (div_ready) state<=DIV_WAIT;
                DIV_WAIT: if (div_valid) begin
                    statistic<=statistic+STAT_W'(div_result);
                    state<=tail_q?FINALIZE:COLLECT;
                end
                FINALIZE: begin
                    m_errors<=final_errors;
                    m_statistic<=(final_errors==0)?statistic:{STAT_W{1'b0}};
                    state<=EMIT;
                end
                EMIT: if (m_ready) begin
                    state<=COLLECT;started<=0;over_capacity<=0;zero_expected<=0;
                    count<=0;active<=0;sum_observed<=0;sum_expected<=0;statistic<=0;
                end
                default: state<=COLLECT;
            endcase
        end
    end
    generate if (DATA_W<1 || DATA_W>24 || MAX_BINS<1 || MAX_BINS>256 ||
                 FRAC<0 || FRAC>24 || TAG_W<1 || TAG_W>32) begin : invalid_parameters
        chi_square_gof_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
