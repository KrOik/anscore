module fused_butterfly #(
    parameter integer WIDTH = 23,
    parameter [WIDTH-1:0] Q_KEM = 23'd3329,
    parameter [WIDTH-1:0] Q_DSA = 23'd8380417
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire             mode_dsa,
    input  wire             inverse_mode,
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire [WIDTH-1:0] twiddle,
    output reg  [WIDTH-1:0] y0,
    output reg  [WIDTH-1:0] y1,
    output reg              busy,
    output reg              done
);

localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_MUL  = 2'd1;
localparam [1:0] S_OUT  = 2'd2;

reg [1:0] state;
reg [5:0] bit_count;

reg [WIDTH:0] q_reg;
reg [WIDTH:0] a_reg;
reg [WIDTH:0] acc;
reg [WIDTH:0] multiplicand;
reg [WIDTH-1:0] multiplier;
reg [WIDTH:0] product_mod;
reg inverse_reg;

wire [WIDTH:0] selected_q = mode_dsa ? {1'b0, Q_DSA} : {1'b0, Q_KEM};
wire [WIDTH:0] start_sum = mod_add({1'b0, a}, {1'b0, b}, selected_q);
wire [WIDTH:0] start_diff = mod_sub({1'b0, a}, {1'b0, b}, selected_q);
wire [WIDTH:0] add_acc = multiplier[0] ? mod_add(acc, multiplicand, q_reg) : acc;
wire [WIDTH:0] double_multiplicand = mod_add(multiplicand, multiplicand, q_reg);
wire [WIDTH:0] y0_next = mod_add(a_reg, product_mod, q_reg);
wire [WIDTH:0] y1_next = mod_sub(a_reg, product_mod, q_reg);

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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        bit_count <= 6'd0;
        q_reg <= {WIDTH+1{1'b0}};
        a_reg <= {WIDTH+1{1'b0}};
        acc <= {WIDTH+1{1'b0}};
        multiplicand <= {WIDTH+1{1'b0}};
        multiplier <= {WIDTH{1'b0}};
        product_mod <= {WIDTH+1{1'b0}};
        inverse_reg <= 1'b0;
        y0 <= {WIDTH{1'b0}};
        y1 <= {WIDTH{1'b0}};
        busy <= 1'b0;
        done <= 1'b0;
    end else begin
        done <= 1'b0;

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    q_reg <= selected_q;
                    inverse_reg <= inverse_mode;
                    a_reg <= inverse_mode ? start_sum : {1'b0, a};
                    acc <= {WIDTH+1{1'b0}};
                    multiplicand <= inverse_mode ? start_diff : {1'b0, b};
                    multiplier <= twiddle;
                    bit_count <= 6'd0;
                    busy <= 1'b1;
                    state <= S_MUL;
                end
            end

            S_MUL: begin
                busy <= 1'b1;
                if (bit_count == WIDTH - 1) begin
                    product_mod <= add_acc;
                    state <= S_OUT;
                end else begin
                    acc <= add_acc;
                    multiplicand <= double_multiplicand;
                    multiplier <= {1'b0, multiplier[WIDTH-1:1]};
                    bit_count <= bit_count + 6'd1;
                end
            end

            S_OUT: begin
                y0 <= inverse_reg ? a_reg[WIDTH-1:0] : y0_next[WIDTH-1:0];
                y1 <= inverse_reg ? product_mod[WIDTH-1:0] : y1_next[WIDTH-1:0];
                busy <= 1'b0;
                done <= 1'b1;
                state <= S_IDLE;
            end

            default: begin
                busy <= 1'b0;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
