`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Uniform gradient-block structure tensor and exact floor Shi-Tomasi score.
module block_shi_tomasi #(
    parameter integer GRAD_W=9,MAX_SAMPLES=64,FRAC=8,SCORE_W=32,TAG_W=8,
    localparam integer COUNT_W=(MAX_SAMPLES>0)?$clog2(MAX_SAMPLES+1):1,
    localparam integer GROW=(MAX_SAMPLES<2)?0:$clog2(MAX_SAMPLES),
    localparam integer STAT_W=2*GRAD_W+GROW
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [GRAD_W-1:0] s_gx,s_gy,
    input wire s_keep,s_last,
    input wire [SCORE_W-2:0] s_threshold,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [SCORE_W-1:0] m_score,m_max_score,
    output reg [1:0] m_saturated,m_status,
    output reg m_corner,m_isotropic,
    output reg [COUNT_W-1:0] m_count,
    output reg [STAT_W:0] m_energy,
    output reg [TAG_W-1:0] m_tag
);
    localparam [2:0] COLLECT=0,X_SQUARE=1,Y_SQUARE=2,CROSS=3,
        PREPARE=4,EIGEN_OFFER=5,EIGEN_WAIT=6,EMIT=7;
    localparam [1:0] OK=0,EMPTY=1,OVERFLOW=2;
    generate if(GRAD_W<2 || GRAD_W>11 || MAX_SAMPLES<1 || MAX_SAMPLES>1024 ||
                STAT_W>24 || FRAC<0 || FRAC>24 || SCORE_W<2 || SCORE_W>64 ||
                TAG_W<1 || TAG_W>32) begin : g_invalid
        block_shi_tomasi_invalid_parameter__see_README invalid_configuration();
    end endgenerate
    reg [2:0] state;
    reg first,overflow,pending_last;
    reg signed [GRAD_W-1:0] gx,gy;
    reg [COUNT_W-1:0] count;
    reg [SCORE_W-2:0] threshold;
    reg [TAG_W-1:0] block_tag;
    reg signed [STAT_W-1:0] xx,xy,yy;
    wire signed [GRAD_W-1:0] mul_a=(state==Y_SQUARE)?gy:gx;
    wire signed [GRAD_W-1:0] mul_b=(state==X_SQUARE)?gx:gy;
    wire signed [2*GRAD_W-1:0] product=mul_a*mul_b;
    wire signed [STAT_W-1:0] product_extended=
        {{(STAT_W-2*GRAD_W){product[2*GRAD_W-1]}},product};
    wire eigen_ready,eigen_valid,eigen_psd,eigen_repeated;
    wire signed [SCORE_W-1:0] eigen_min,eigen_max;
    wire [1:0] eigen_saturated;
    wire signed [STAT_W:0] eigen_trace;
    wire [2*STAT_W:0] eigen_discriminant;
    wire [TAG_W-1:0] eigen_tag;
    symmetric_eigen2x2 #(.W(STAT_W),.FRAC(FRAC),.RESULT_W(SCORE_W),.TAG_W(TAG_W)) eigensolver(
        .clk(clk),.rst(rst),.s_valid(!rst && state==EIGEN_OFFER),.s_ready(eigen_ready),
        .s_a(xx),.s_b(xy),.s_d(yy),.s_tag(block_tag),
        .m_valid(eigen_valid),.m_ready(!rst && state==EIGEN_WAIT),
        .m_min(eigen_min),.m_max(eigen_max),.m_saturated(eigen_saturated),
        .m_psd(eigen_psd),.m_repeated(eigen_repeated),.m_trace(eigen_trace),
        .m_discriminant(eigen_discriminant),.m_tag(eigen_tag)
    );
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==EMIT;
    always @(posedge clk) begin
        if(rst) begin
            state<=COLLECT;first<=1;overflow<=0;pending_last<=0;
            gx<=0;gy<=0;count<=0;threshold<=0;block_tag<=0;xx<=0;xy<=0;yy<=0;
            m_score<=0;m_max_score<=0;m_saturated<=0;m_status<=OK;
            m_corner<=0;m_isotropic<=0;m_count<=0;m_energy<=0;m_tag<=0;
        end else case(state)
            COLLECT: if(s_valid) begin
                if(first) begin threshold<=s_threshold;block_tag<=s_tag;first<=0;end
                if(s_keep && count<MAX_SAMPLES) begin
                    gx<=s_gx;gy<=s_gy;pending_last<=s_last;state<=X_SQUARE;
                end else begin
                    if(s_keep) overflow<=1;
                    if(s_last) state<=PREPARE;
                end
            end
            X_SQUARE: begin xx<=xx+product_extended;state<=Y_SQUARE;end
            Y_SQUARE: begin yy<=yy+product_extended;state<=CROSS;end
            CROSS: begin
                xy<=xy+product_extended;count<=count+1'b1;
                state<=pending_last?PREPARE:COLLECT;
            end
            PREPARE: begin
                m_tag<=block_tag;
                if(overflow || count==0) begin
                    m_status<=overflow?OVERFLOW:EMPTY;m_score<=0;m_max_score<=0;
                    m_saturated<=0;m_corner<=0;m_isotropic<=0;m_count<=0;m_energy<=0;
                    state<=EMIT;
                end else begin m_status<=OK;m_count<=count;state<=EIGEN_OFFER;end
            end
            EIGEN_OFFER: if(eigen_ready) state<=EIGEN_WAIT;
            EIGEN_WAIT: if(eigen_valid) begin
                m_score<=eigen_min;m_max_score<=eigen_max;m_saturated<=eigen_saturated;
                // A structure tensor is PSD: minimum saturation is positive.
                // Thus its true floor score exceeds every representable threshold.
                m_corner<=eigen_saturated[0] || eigen_min>$signed({1'b0,threshold});
                m_isotropic<=eigen_repeated;m_energy<=$unsigned(eigen_trace);m_tag<=eigen_tag;
                state<=EMIT;
            end
            EMIT: if(m_ready) begin
                state<=COLLECT;first<=1;overflow<=0;count<=0;xx<=0;xy<=0;yy<=0;
            end
            default: state<=COLLECT;
        endcase
    end
endmodule
