// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Exact floor-quantized eigenvalues of [ a b ; b d ].
module symmetric_eigen2x2 #(
    parameter integer W=16,
    parameter integer FRAC=12,
    parameter integer RESULT_W=32,
    parameter integer TAG_W=8
) (
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [W-1:0] s_a,s_b,s_d,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg signed [RESULT_W-1:0] m_min,m_max,
    output reg [1:0] m_saturated,
    output reg m_psd,m_repeated,
    output reg signed [W:0] m_trace,
    output reg [2*W:0] m_discriminant,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer D=2*W+1;
    localparam integer N=W+FRAC+1;
    localparam integer EW=N+2;
    localparam integer QW=(EW>RESULT_W)?EW:RESULT_W;
    localparam integer CW=$clog2(N+1);
    localparam [2:0] IDLE=0,MUL_SETUP=1,MUL_RUN=2,SQRT_OFFER=3,
        SQRT_WAIT=4,EIGEN=5,EMIT=6;
    generate if(W<2 || W>24 || FRAC<0 || FRAC>24 || RESULT_W<2 ||
                RESULT_W>64 || TAG_W<1 || TAG_W>32) begin : g_invalid
        symmetric_eigen2x2_invalid_parameter__see_README invalid_configuration();
    end endgenerate

    reg [2:0] state;
    reg [1:0] operation;
    reg [W:0] difference_abs;
    reg [W-1:0] b_abs;
    reg [D-1:0] difference_square;
    wire signed [W:0] difference=$signed({s_a[W-1],s_a})-$signed({s_d[W-1],s_d});
    reg [N-1:0] sqrt_candidate;
    reg root_exact;
    reg [N:0] root_floor,root_ceil;
    wire [N-1:0] selected_factor=(operation==0) ? {{(N-W-1){1'b0}},difference_abs} :
        (operation==1) ? {{(N-W){1'b0}},b_abs} : sqrt_candidate;
    reg [2*N-1:0] mul_shift,mul_acc;
    reg [N-1:0] mul_factor;
    reg [CW-1:0] mul_step;
    wire [2*N-1:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:{(2*N){1'b0}});
    wire [D-1:0] discriminant_next=difference_square+(mul_next[D-1:0]<<2);
    wire [2*N-1:0] radicand_scaled={1'b0,m_discriminant,{(2*FRAC){1'b0}}};
    // RNE sqrt differs from floor by at most one. The full candidate square
    // identifies that direction without a second square-root implementation.
    wire [N:0] corrected_floor={1'b0,sqrt_candidate}-
        {{N{1'b0}},(mul_next>radicand_scaled)};

    wire sqrt_ready,sqrt_valid;
    wire [N:0] sqrt_data;
    wire [1:0] sqrt_user;
    fp_sqrt_iter #(.IN_W(D),.FB(FRAC)) sqrt_engine (
        .clk(clk),.rst_n(!rst),.s_tdata(m_discriminant),
        .s_tvalid(!rst && state==SQRT_OFFER),.s_tready(sqrt_ready),
        .m_tdata(sqrt_data),.m_tuser(sqrt_user),.m_tvalid(sqrt_valid),
        .m_tready(!rst && state==SQRT_WAIT)
    );

    wire signed [EW-1:0] trace_extended={{(EW-W-1){m_trace[W]}},m_trace};
    wire signed [EW-1:0] trace_scaled=trace_extended<<<FRAC;
    wire signed [EW-1:0] floor_extended=$signed({1'b0,root_floor});
    wire signed [EW-1:0] ceil_extended=$signed({1'b0,root_ceil});
    wire signed [EW-1:0] raw_min=(trace_scaled-ceil_extended)>>>1;
    wire signed [EW-1:0] raw_max=(trace_scaled+floor_extended)>>>1;
    wire signed [QW-1:0] min_extended={{(QW-EW){raw_min[EW-1]}},raw_min};
    wire signed [QW-1:0] max_extended={{(QW-EW){raw_max[EW-1]}},raw_max};
    wire signed [QW-1:0] low_limit={{(QW-RESULT_W){1'b1}},1'b1,{(RESULT_W-1){1'b0}}};
    wire signed [QW-1:0] high_limit={{(QW-RESULT_W){1'b0}},1'b0,{(RESULT_W-1){1'b1}}};
    wire min_clipped=(min_extended<low_limit || min_extended>high_limit);
    wire max_clipped=(max_extended<low_limit || max_extended>high_limit);
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==EMIT;

    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;operation<=0;
            m_min<=0;m_max<=0;m_saturated<=0;m_psd<=0;m_repeated<=0;
            m_trace<=0;m_discriminant<=0;m_tag<=0;
        end else begin
            case(state)
                IDLE: if(s_valid) begin
                    difference_abs<=difference[W] ? -$unsigned(difference) : $unsigned(difference);
                    b_abs<=s_b[W-1] ? -$unsigned(s_b) : $unsigned(s_b);
                    m_trace<=$signed({s_a[W-1],s_a})+$signed({s_d[W-1],s_d});
                    m_tag<=s_tag;operation<=0;state<=MUL_SETUP;
                end
                MUL_SETUP: begin
                    mul_shift<=selected_factor;mul_factor<=selected_factor;
                    mul_acc<=0;mul_step<=0;state<=MUL_RUN;
                end
                MUL_RUN: begin
                    mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
                    if(mul_step==N-1) begin
                        case(operation)
                            0: begin
                                difference_square<=mul_next[D-1:0];
                                operation<=1;state<=MUL_SETUP;
                            end
                            1: begin m_discriminant<=discriminant_next;state<=SQRT_OFFER;end
                            default: begin
                                root_floor<=corrected_floor;
                                root_ceil<=corrected_floor+{{N{1'b0}},!root_exact};
                                state<=EIGEN;
                            end
                        endcase
                    end else mul_step<=mul_step+1'b1;
                end
                SQRT_OFFER: if(sqrt_ready) state<=SQRT_WAIT;
                SQRT_WAIT: if(sqrt_valid) begin
                    // Matrix-domain bound makes the dependency's top carry bit
                    // zero: sqrt(discriminant)*2^FRAC < 2^(N-1/2).
                    sqrt_candidate<=sqrt_data[N-1:0];root_exact<=sqrt_user[1];
                    operation<=2;state<=MUL_SETUP;
                end
                EIGEN: begin
                    m_min<=min_extended<low_limit ? {1'b1,{(RESULT_W-1){1'b0}}} :
                        min_extended>high_limit ? {1'b0,{(RESULT_W-1){1'b1}}} : min_extended[RESULT_W-1:0];
                    m_max<=max_extended<low_limit ? {1'b1,{(RESULT_W-1){1'b0}}} :
                        max_extended>high_limit ? {1'b0,{(RESULT_W-1){1'b1}}} : max_extended[RESULT_W-1:0];
                    m_saturated<={max_clipped,min_clipped};
                    m_psd<=(raw_min>=0);m_repeated<=(m_discriminant==0);state<=EMIT;
                end
                EMIT: if(m_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
