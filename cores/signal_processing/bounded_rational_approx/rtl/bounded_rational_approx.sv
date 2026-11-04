// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Exact nearest rational with a runtime denominator bound. No data *, / or %.
module bounded_rational_approx #(
    parameter integer W = 8,
    parameter integer QW = 4,
    parameter integer TAG_W = 8
) (
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire signed [W-1:0] s_num,
    input wire [W-1:0] s_den,
    input wire [QW-1:0] s_limit,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg signed [W+QW:0] m_num,
    output reg [QW-1:0] m_den,
    output reg signed [W:0] m_error,
    output reg [1:0] m_status,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer MW = W + QW;
    localparam integer DCW = (W <= 2) ? 1 : $clog2(W);
    localparam integer MCW = (QW <= 2) ? 1 : $clog2(QW);
    localparam [2:0] IDLE=0, DIVIDE=1, INIT=2, SEARCH=3,
                     MULTIPLY=4, PRODUCT=5, CHOOSE=6, OUTPUT=7;
    generate if (W < 2 || W > 16 || QW < 1 || QW > 8 ||
                 TAG_W < 1 || TAG_W > 32) begin : bad_parameters
        bounded_rational_approx_invalid_parameter__see_README invalid();
    end endgenerate

    reg [2:0] state;
    reg [TAG_W-1:0] tag;
    reg negative;
    reg [QW-1:0] limit;
    reg [W-1:0] divisor, dividend, div_quotient;
    reg [W:0] div_remainder;
    reg [DCW-1:0] div_count;
    reg [QW-1:0] ln, ld, rn, rd;
    reg [W-1:0] el, er;
    reg [QW-1:0] selected_n, selected_d;
    reg [W-1:0] selected_error;
    reg selected_above;
    reg [MW-1:0] mul_a, mul_acc, mul_result, compare_left;
    reg [QW-1:0] mul_b;
    reg [MCW-1:0] mul_count;
    reg [1:0] mul_op;

    wire [W-1:0] input_magnitude = s_num[W-1] ?
                                   (~s_num[W-1:0] + {{(W-1){1'b0}},1'b1}) : s_num;
    wire [W:0] div_trial = {div_remainder[W-1:0],dividend[W-1]};
    wire div_subtract = div_trial >= {1'b0,divisor};
    wire [W:0] div_next = div_subtract ? div_trial-{1'b0,divisor} : div_trial;
    wire [QW:0] mediant_n = {1'b0,ln}+{1'b0,rn};
    wire [QW:0] mediant_d = {1'b0,ld}+{1'b0,rd};
    wire [MW-1:0] mul_next = mul_acc + (mul_b[0] ? mul_a : {MW{1'b0}});
    wire choose_left = (compare_left < mul_result) ||
                       ((compare_left == mul_result) && (ld <= rd));
    wire [MW-1:0] final_magnitude = mul_result + {{W{1'b0}},selected_n};
    wire signed [MW:0] final_positive = $signed({1'b0,final_magnitude});
    wire signed [W:0] error_positive = $signed({1'b0,selected_error});
    assign s_ready = !rst && (state == IDLE);
    assign m_valid = !rst && (state == OUTPUT);
    assign m_tag = tag;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            tag <= 0;
            m_num <= 0;
            m_den <= 0;
            m_error <= 0;
            m_status <= 0;
        end else begin
            case (state)
            IDLE: if (s_valid) begin
                tag <= s_tag;
                negative <= s_num[W-1];
                limit <= s_limit;
                m_status <= {s_limit == 0,s_den == 0};
                m_num <= 0; m_den <= 0; m_error <= 0;
                if ((s_den == 0) || (s_limit == 0)) state <= OUTPUT;
                else begin
                    divisor <= s_den; dividend <= input_magnitude;
                    div_quotient <= 0; div_remainder <= 0; div_count <= 0;
                    state <= DIVIDE;
                end
            end
            DIVIDE: begin
                dividend <= dividend << 1;
                div_remainder <= div_next;
                div_quotient <= (div_quotient << 1) | {{(W-1){1'b0}},div_subtract};
                if (div_count == W-1) state <= INIT;
                else div_count <= div_count + 1'b1;
            end
            INIT: begin
                if (div_remainder == 0) begin
                    selected_n <= 0; selected_d <= {{(QW-1){1'b0}},1'b1};
                    selected_error <= 0; selected_above <= 0;
                    mul_a <= {{QW{1'b0}},div_quotient};
                    mul_b <= {{(QW-1){1'b0}},1'b1};
                    mul_acc <= 0; mul_count <= 0; mul_op <= 2;
                    state <= MULTIPLY;
                end else begin
                    ln <= 0; ld <= {{(QW-1){1'b0}},1'b1};
                    rn <= {{(QW-1){1'b0}},1'b1}; rd <= {{(QW-1){1'b0}},1'b1};
                    el <= div_remainder[W-1:0];
                    er <= divisor - div_remainder[W-1:0];
                    state <= SEARCH;
                end
            end
            SEARCH: begin
                // Adjacent bounds enclose r/D; signed mediant residual is el-er.
                if (mediant_d > {1'b0,limit}) begin
                    mul_a <= {{QW{1'b0}},el}; mul_b <= rd;
                    mul_acc <= 0; mul_count <= 0; mul_op <= 0;
                    state <= MULTIPLY;
                end else if (el == er) begin
                    selected_n <= mediant_n[QW-1:0];
                    selected_d <= mediant_d[QW-1:0];
                    selected_error <= 0; selected_above <= 0;
                    mul_a <= {{QW{1'b0}},div_quotient};
                    mul_b <= mediant_d[QW-1:0];
                    mul_acc <= 0; mul_count <= 0; mul_op <= 2;
                    state <= MULTIPLY;
                end else if (el > er) begin
                    ln <= mediant_n[QW-1:0]; ld <= mediant_d[QW-1:0];
                    el <= el-er;
                end else begin
                    rn <= mediant_n[QW-1:0]; rd <= mediant_d[QW-1:0];
                    er <= er-el;
                end
            end
            MULTIPLY: begin
                mul_acc <= mul_next;
                mul_a <= mul_a << 1; mul_b <= mul_b >> 1;
                if (mul_count == QW-1) begin
                    mul_result <= mul_next;
                    state <= PRODUCT;
                end else mul_count <= mul_count + 1'b1;
            end
            PRODUCT: begin
                case (mul_op)
                0: begin
                    compare_left <= mul_result;
                    mul_a <= {{QW{1'b0}},er}; mul_b <= ld;
                    mul_acc <= 0; mul_count <= 0; mul_op <= 1;
                    state <= MULTIPLY;
                end
                1: state <= CHOOSE;
                2: begin
                    m_num <= negative ? -final_positive : final_positive;
                    m_den <= selected_d;
                    m_error <= (negative ^ selected_above) ? -error_positive : error_positive;
                    state <= OUTPUT;
                end
                default: state <= IDLE;
                endcase
            end
            CHOOSE: begin
                selected_n <= choose_left ? ln : rn;
                selected_d <= choose_left ? ld : rd;
                selected_error <= choose_left ? el : er;
                selected_above <= !choose_left;
                mul_a <= {{QW{1'b0}},div_quotient};
                mul_b <= choose_left ? ld : rd;
                mul_acc <= 0; mul_count <= 0; mul_op <= 2;
                state <= MULTIPLY;
            end
            OUTPUT: if (m_ready) state <= IDLE;
            default: state <= IDLE;
            endcase
        end
    end
endmodule
