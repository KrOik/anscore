// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Framed signed-integer ordinary least-squares y = slope*x + intercept.
module stream_linear_fit #(
    parameter integer DATA_W=8,
    parameter integer COUNT_W=6,
    parameter integer FRAC=16,
    parameter integer RESULT_W=32,
    parameter integer TAG_W=8
) (
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire signed [DATA_W-1:0] s_x, s_y,
    input wire s_keep, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire signed [RESULT_W-1:0] m_slope, m_intercept,
    output wire [COUNT_W-1:0] m_count,
    output wire m_degenerate, m_overflow,
    output wire [1:0] m_saturated,
    output wire [2*(2*DATA_W+COUNT_W+1):0] m_spread,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer STAT_W=2*DATA_W+COUNT_W+1;
    localparam [2:0] COLLECT=0, SQUARE=1, CROSS=2, OFFER=3, RESULT=4;
    generate if(DATA_W<2 || DATA_W>10 || COUNT_W<1 || COUNT_W>12 ||
                STAT_W>24 || FRAC<0 || FRAC>24 || RESULT_W<2 ||
                RESULT_W>64 || TAG_W<1 || TAG_W>32) begin : g_invalid
        stream_linear_fit_invalid_parameter__see_README invalid_configuration();
    end endgenerate

    reg [2:0] state;
    reg first_beat, pending_last, overflow;
    reg signed [DATA_W-1:0] pair_x,pair_y;
    reg [COUNT_W-1:0] count;
    reg [TAG_W-1:0] frame_tag;
    reg signed [STAT_W-1:0] sum_x,sum_y,sum_x2,sum_xy;
    // One source-level multiplier, selected across two processing clocks.
    wire signed [DATA_W-1:0] mul_rhs=(state==SQUARE)?pair_x:pair_y;
    wire signed [2*DATA_W-1:0] product=pair_x*mul_rhs;
    wire signed [STAT_W-1:0] product_ext={{(STAT_W-2*DATA_W){product[2*DATA_W-1]}},product};
    wire signed [STAT_W-1:0] x_ext={{(STAT_W-DATA_W){pair_x[DATA_W-1]}},pair_x};
    wire signed [STAT_W-1:0] y_ext={{(STAT_W-DATA_W){pair_y[DATA_W-1]}},pair_y};
    wire signed [STAT_W-1:0] count_ext={{(STAT_W-COUNT_W){1'b0}},count};
    wire fit_ready,fit_valid,fit_singular;
    wire signed [2*STAT_W:0] fit_determinant;

    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==RESULT && fit_valid;
    assign m_count=count;
    assign m_overflow=overflow;
    assign m_degenerate=fit_singular;
    // For integer normal equations this determinant is always nonnegative.
    assign m_spread=$unsigned(fit_determinant);

    linear_solve2x2 #(.W(STAT_W),.FRAC(FRAC),.RESULT_W(RESULT_W),.TAG_W(TAG_W)) fit (
        .clk(clk),.rst(rst),.s_valid(state==OFFER && !rst),.s_ready(fit_ready),
        .s_a00(sum_x2),.s_a01(sum_x),.s_a10(sum_x),.s_a11(count_ext),
        .s_b0(sum_xy),.s_b1(sum_y),.s_tag(frame_tag),
        .m_valid(fit_valid),.m_ready(state==RESULT && m_ready && !rst),
        .m_x(m_slope),.m_y(m_intercept),.m_determinant(fit_determinant),
        .m_singular(fit_singular),.m_saturated(m_saturated),.m_tag(m_tag)
    );

    always @(posedge clk) begin
        if(rst) begin
            state<=COLLECT;
            first_beat<=1'b1;
            pending_last<=1'b0;
            overflow<=1'b0;
            count<=0;
            frame_tag<=0;
            sum_x<=0;sum_y<=0;sum_x2<=0;sum_xy<=0;
        end else begin
            case(state)
                COLLECT: if(s_valid) begin
                    if(first_beat) begin frame_tag<=s_tag;first_beat<=1'b0;end
                    if(s_keep && !(&count)) begin
                        pair_x<=s_x;pair_y<=s_y;pending_last<=s_last;
                        state<=SQUARE;
                    end else begin
                        if(s_keep) overflow<=1'b1;
                        if(s_last) state<=OFFER;
                    end
                end
                SQUARE: begin
                    sum_x2<=sum_x2+product_ext;
                    state<=CROSS;
                end
                CROSS: begin
                    sum_xy<=sum_xy+product_ext;
                    sum_x<=sum_x+x_ext;
                    sum_y<=sum_y+y_ext;
                    count<=count+1'b1;
                    state<=pending_last?OFFER:COLLECT;
                end
                OFFER: if(fit_ready) state<=RESULT;
                RESULT: if(fit_valid && m_ready) begin
                    state<=COLLECT;
                    first_beat<=1'b1;
                    overflow<=1'b0;
                    count<=0;
                    sum_x<=0;sum_y<=0;sum_x2<=0;sum_xy<=0;
                end
                default: state<=COLLECT;
            endcase
        end
    end
endmodule
