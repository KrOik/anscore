// Prototype/test-gated second-order masked butterfly boundary.
// This module proves a three-share interface and fresh-randomness accounting,
// but it is not a side-channel-proven replacement for fused_butterfly.
module fused_butterfly_masked2 #(
    parameter integer WIDTH = 23,
    parameter [WIDTH-1:0] Q_KEM = 23'd3329,
    parameter [WIDTH-1:0] Q_DSA = 23'd8380417
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire             mode_dsa,
    input  wire             inverse_mode,
    input  wire [WIDTH-1:0] a_share0,
    input  wire [WIDTH-1:0] a_share1,
    input  wire [WIDTH-1:0] a_share2,
    input  wire [WIDTH-1:0] b_share0,
    input  wire [WIDTH-1:0] b_share1,
    input  wire [WIDTH-1:0] b_share2,
    input  wire [WIDTH-1:0] twiddle_share0,
    input  wire [WIDTH-1:0] twiddle_share1,
    input  wire [WIDTH-1:0] twiddle_share2,
    input  wire             random_valid,
    output wire             random_ready,
    input  wire [WIDTH-1:0] random_y0_share1,
    input  wire [WIDTH-1:0] random_y0_share2,
    input  wire [WIDTH-1:0] random_y1_share1,
    input  wire [WIDTH-1:0] random_y1_share2,
    output reg  [WIDTH-1:0] y0_share0,
    output reg  [WIDTH-1:0] y0_share1,
    output reg  [WIDTH-1:0] y0_share2,
    output reg  [WIDTH-1:0] y1_share0,
    output reg  [WIDTH-1:0] y1_share1,
    output reg  [WIDTH-1:0] y1_share2,
    output reg              busy,
    output reg              done,
    output reg              error,
    output reg              random_missing_error,
    output reg  [15:0]      random_accept_count
);

localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_WAIT = 2'd1;
localparam [1:0] S_OUT  = 2'd2;

reg [1:0] state;
reg core_start;
reg core_mode_dsa;
reg core_inverse_mode;
reg [WIDTH-1:0] core_a;
reg [WIDTH-1:0] core_b;
reg [WIDTH-1:0] core_twiddle;
wire [WIDTH-1:0] core_y0;
wire [WIDTH-1:0] core_y1;
wire core_busy;
wire core_done;
reg [WIDTH-1:0] y0_r1;
reg [WIDTH-1:0] y0_r2;
reg [WIDTH-1:0] y1_r1;
reg [WIDTH-1:0] y1_r2;

wire [WIDTH:0] selected_q = mode_dsa ? {1'b0, Q_DSA} : {1'b0, Q_KEM};
wire [WIDTH:0] q_reg_for_out = core_mode_dsa ? {1'b0, Q_DSA} : {1'b0, Q_KEM};

assign random_ready = (state == S_IDLE) && !busy;

fused_butterfly #(
    .WIDTH(WIDTH),
    .Q_KEM(Q_KEM),
    .Q_DSA(Q_DSA)
) core (
    .clk(clk),
    .rst_n(rst_n),
    .start(core_start),
    .mode_dsa(core_mode_dsa),
    .inverse_mode(core_inverse_mode),
    .a(core_a),
    .b(core_b),
    .twiddle(core_twiddle),
    .y0(core_y0),
    .y1(core_y1),
    .busy(core_busy),
    .done(core_done)
);

function [WIDTH:0] mod_add;
    input [WIDTH:0] x;
    input [WIDTH:0] y;
    input [WIDTH:0] q;
    reg [WIDTH+1:0] sum;
    begin
        sum = {1'b0, x} + {1'b0, y};
        if (sum >= {1'b0, q}) begin
            sum = sum - {1'b0, q};
        end
        mod_add = sum[WIDTH:0];
    end
endfunction

function [WIDTH:0] mod_sub;
    input [WIDTH:0] x;
    input [WIDTH:0] y;
    input [WIDTH:0] q;
    begin
        if (x >= y) begin
            mod_sub = x - y;
        end else begin
            mod_sub = x + q - y;
        end
    end
endfunction

function [WIDTH-1:0] recombine3;
    input [WIDTH-1:0] s0;
    input [WIDTH-1:0] s1;
    input [WIDTH-1:0] s2;
    input [WIDTH:0] q;
    reg [WIDTH:0] partial;
    begin
        partial = mod_add({1'b0, s0}, {1'b0, s1}, q);
        recombine3 = mod_add(partial, {1'b0, s2}, q);
    end
endfunction

function [WIDTH-1:0] remask_share0;
    input [WIDTH-1:0] value;
    input [WIDTH-1:0] r1;
    input [WIDTH-1:0] r2;
    input [WIDTH:0] q;
    reg [WIDTH:0] partial;
    begin
        partial = mod_sub({1'b0, value}, {1'b0, r1}, q);
        remask_share0 = mod_sub(partial, {1'b0, r2}, q);
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        core_start <= 1'b0;
        core_mode_dsa <= 1'b0;
        core_inverse_mode <= 1'b0;
        core_a <= {WIDTH{1'b0}};
        core_b <= {WIDTH{1'b0}};
        core_twiddle <= {WIDTH{1'b0}};
        y0_r1 <= {WIDTH{1'b0}};
        y0_r2 <= {WIDTH{1'b0}};
        y1_r1 <= {WIDTH{1'b0}};
        y1_r2 <= {WIDTH{1'b0}};
        y0_share0 <= {WIDTH{1'b0}};
        y0_share1 <= {WIDTH{1'b0}};
        y0_share2 <= {WIDTH{1'b0}};
        y1_share0 <= {WIDTH{1'b0}};
        y1_share1 <= {WIDTH{1'b0}};
        y1_share2 <= {WIDTH{1'b0}};
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
        random_missing_error <= 1'b0;
        random_accept_count <= 16'd0;
    end else begin
        core_start <= 1'b0;
        done <= 1'b0;

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    error <= 1'b0;
                    random_missing_error <= 1'b0;
                    if (!random_valid) begin
                        error <= 1'b1;
                        random_missing_error <= 1'b1;
                        done <= 1'b1;
                    end else begin
                        core_mode_dsa <= mode_dsa;
                        core_inverse_mode <= inverse_mode;
                        core_a <= recombine3(a_share0, a_share1, a_share2,
                                             selected_q);
                        core_b <= recombine3(b_share0, b_share1, b_share2,
                                             selected_q);
                        core_twiddle <= recombine3(twiddle_share0,
                                                   twiddle_share1,
                                                   twiddle_share2,
                                                   selected_q);
                        y0_r1 <= random_y0_share1;
                        y0_r2 <= random_y0_share2;
                        y1_r1 <= random_y1_share1;
                        y1_r2 <= random_y1_share2;
                        random_accept_count <= random_accept_count + 16'd1;
                        core_start <= 1'b1;
                        busy <= 1'b1;
                        state <= S_WAIT;
                    end
                end
            end

            S_WAIT: begin
                busy <= 1'b1;
                if (core_done) begin
                    state <= S_OUT;
                end
            end

            S_OUT: begin
                y0_share0 <= remask_share0(core_y0, y0_r1, y0_r2,
                                           q_reg_for_out);
                y0_share1 <= y0_r1;
                y0_share2 <= y0_r2;
                y1_share0 <= remask_share0(core_y1, y1_r1, y1_r2,
                                           q_reg_for_out);
                y1_share1 <= y1_r1;
                y1_share2 <= y1_r2;
                busy <= 1'b0;
                done <= 1'b1;
                state <= S_IDLE;
            end

            default: begin
                busy <= 1'b0;
                error <= 1'b1;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
