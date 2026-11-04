// SPDX-License-Identifier: Apache-2.0
module affine_floor_sum #(
    parameter integer W = 8,
    parameter integer TAG_W = 8
) (
    input wire clk,
    input wire rst,
    input wire s_valid,
    output wire s_ready,
    input wire [W-1:0] s_n,
    input wire [W-1:0] s_a,
    input wire [W-1:0] s_b,
    input wire [W-1:0] s_m,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg [3*W-1:0] m_sum,
    output reg m_error,
    output reg [TAG_W-1:0] m_tag
);
    generate
        if (W < 1 || W > 16 || TAG_W < 1 || TAG_W > 32) begin : g_invalid
            affine_floor_sum_invalid_parameters__see_README invalid_parameters();
        end
    endgenerate

    localparam integer MCW = (W < 2) ? 1 : $clog2(W);
    localparam integer DCW = $clog2(2*W);
    localparam [2:0] IDLE=0, TRI_SETUP=1, MUL=2, MUL_RET=3,
                     DIV=4, DIV_RET=5, OUTPUT=6;
    reg [2:0] state;
    reg [W-1:0] n, a, b, m;
    reg [3*W-1:0] mul_a, mul_acc;
    reg [W-1:0] mul_b;
    reg [MCW-1:0] mul_count;
    reg [1:0] mul_job;
    reg [2*W-1:0] div_q;
    reg [W:0] remainder;
    reg [DCW-1:0] div_count;
    reg [1:0] div_job;
    wire [W:0] trial = {remainder[W-1:0], div_q[2*W-1]};
    wire trial_ge = trial >= {1'b0, m};
    wire [2*W-1:0] y = mul_acc[2*W-1:0] + {{W{1'b0}}, b};

    assign s_ready = !rst && state == IDLE;
    assign m_valid = !rst && state == OUTPUT;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            m_sum <= 0;
            m_error <= 0;
            m_tag <= 0;
        end else begin
            case (state)
                IDLE: if (s_valid) begin
                    n <= s_n; a <= s_a; b <= s_b; m <= s_m;
                    m_tag <= s_tag; m_sum <= 0; m_error <= s_m == 0;
                    if (s_m == 0 || s_n == 0) state <= OUTPUT;
                    else state <= TRI_SETUP;
                end
                TRI_SETUP: begin
                    // Halve before multiplying: n(n-1)/2, including W=1.
                    mul_a <= {{2*W{1'b0}}, (n >> 1)};
                    mul_b <= n[0] ? n : n-1'b1;
                    mul_acc <= 0; mul_count <= 0; mul_job <= 0;
                    state <= MUL;
                end
                MUL: begin
                    if (mul_b[0]) mul_acc <= mul_acc + mul_a;
                    mul_a <= mul_a << 1;
                    mul_b <= mul_b >> 1;
                    if (mul_count == W-1) state <= MUL_RET;
                    else mul_count <= mul_count + 1'b1;
                end
                MUL_RET: begin
                    case (mul_job)
                        0: begin
                            // mul_acc retains T throughout the following division.
                            div_q <= {{W{1'b0}}, a}; remainder <= 0;
                            div_count <= 0; div_job <= 0; state <= DIV;
                        end
                        1: begin
                            m_sum <= m_sum + mul_acc;
                            div_q <= {{W{1'b0}}, b}; remainder <= 0;
                            div_count <= 0; div_job <= 1; state <= DIV;
                        end
                        2: begin
                            m_sum <= m_sum + mul_acc;
                            mul_a <= {{2*W{1'b0}}, n}; mul_b <= a;
                            mul_acc <= 0; mul_count <= 0; mul_job <= 3;
                            state <= MUL;
                        end
                        3: begin
                            if (y < {{W{1'b0}}, m}) state <= OUTPUT;
                            else begin
                                div_q <= y; remainder <= 0;
                                div_count <= 0; div_job <= 2; state <= DIV;
                            end
                        end
                    endcase
                end
                DIV: begin
                    remainder <= trial_ge ? trial-{1'b0,m} : trial;
                    div_q <= {div_q[2*W-2:0], trial_ge};
                    if (div_count == 2*W-1) state <= DIV_RET;
                    else div_count <= div_count + 1'b1;
                end
                DIV_RET: begin
                    case (div_job)
                        0: begin
                            a <= remainder[W-1:0];
                            mul_a <= mul_acc; mul_b <= div_q[W-1:0];
                            mul_acc <= 0; mul_count <= 0; mul_job <= 1;
                            state <= MUL;
                        end
                        1: begin
                            b <= remainder[W-1:0];
                            mul_a <= {{2*W{1'b0}}, n}; mul_b <= div_q[W-1:0];
                            mul_acc <= 0; mul_count <= 0; mul_job <= 2;
                            state <= MUL;
                        end
                        2: begin
                            n <= div_q[W-1:0]; b <= remainder[W-1:0];
                            a <= m; m <= a;
                            state <= TRI_SETUP;
                        end
                    endcase
                end
                OUTPUT: if (m_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
