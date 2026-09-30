module rsa_modmul #(
    parameter integer WIDTH = 256,
    parameter [WIDTH-1:0] MODULUS = {WIDTH{1'b1}}
) (
    input clk,
    input rst_n,
    input start,
    input [WIDTH-1:0] a,
    input [WIDTH-1:0] b,
    output reg busy,
    output reg done,
    output reg [WIDTH-1:0] result
);

    reg [WIDTH-1:0] acc;
    reg [WIDTH-1:0] a_reg;
    reg [WIDTH-1:0] b_reg;
    reg [15:0] bit_count;

    function [WIDTH-1:0] mod_add;
        input [WIDTH-1:0] x;
        input [WIDTH-1:0] y;
        reg [WIDTH:0] sum;
        reg [WIDTH:0] reduced;
        begin
            sum = {1'b0, x} + {1'b0, y};
            if (sum >= {1'b0, MODULUS}) begin
                reduced = sum - {1'b0, MODULUS};
                mod_add = reduced[WIDTH-1:0];
            end else begin
                mod_add = sum[WIDTH-1:0];
            end
        end
    endfunction

    wire [WIDTH-1:0] acc_with_a = mod_add(acc, a_reg);
    wire [WIDTH-1:0] next_acc = b_reg[0] ? acc_with_a : acc;
    wire [WIDTH-1:0] next_a = mod_add(a_reg, a_reg);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= {WIDTH{1'b0}};
            a_reg <= {WIDTH{1'b0}};
            b_reg <= {WIDTH{1'b0}};
            bit_count <= 16'd0;
            busy <= 1'b0;
            done <= 1'b0;
            result <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                acc <= {WIDTH{1'b0}};
                a_reg <= a;
                b_reg <= b;
                bit_count <= 16'd0;
                busy <= 1'b1;
            end else if (busy) begin
                acc <= next_acc;
                a_reg <= next_a;
                b_reg <= {1'b0, b_reg[WIDTH-1:1]};
                bit_count <= bit_count + 16'd1;

                if (bit_count == WIDTH[15:0] - 16'd1) begin
                    result <= next_acc;
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

endmodule
