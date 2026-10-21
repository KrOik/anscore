module rsa_modexp #(
    parameter integer WIDTH = 256,
    parameter [WIDTH-1:0] MODULUS =
        256'hB7F4820717DF346B5EF24C7D132DE33AA96A477B3EDD40ACE2A4A982C4BE1EC7
) (
    input clk,
    input rst_n,
    input start,
    input [WIDTH-1:0] message,
    output reg busy,
    output reg done,
    output reg error,
    output reg [15:0] cycles,
    output reg [WIDTH-1:0] ciphertext
);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_START_SQUARE = 3'd1;
    localparam [2:0] ST_WAIT_SQUARE = 3'd2;
    localparam [2:0] ST_START_FINAL = 3'd3;
    localparam [2:0] ST_WAIT_FINAL = 3'd4;

    reg [2:0] state;
    reg [4:0] square_count;
    reg [WIDTH-1:0] saved_message;
    reg [WIDTH-1:0] work_value;

    reg mul_start;
    reg [WIDTH-1:0] mul_a;
    reg [WIDTH-1:0] mul_b;
    wire mul_busy;
    wire mul_done;
    wire [WIDTH-1:0] mul_result;

    rsa_modmul #(
        .WIDTH(WIDTH),
        .MODULUS(MODULUS)
    ) mul_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(mul_start),
        .a(mul_a),
        .b(mul_b),
        .busy(mul_busy),
        .done(mul_done),
        .result(mul_result)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            square_count <= 5'd0;
            saved_message <= {WIDTH{1'b0}};
            work_value <= {WIDTH{1'b0}};
            mul_start <= 1'b0;
            mul_a <= {WIDTH{1'b0}};
            mul_b <= {WIDTH{1'b0}};
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            cycles <= 16'd0;
            ciphertext <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;
            mul_start <= 1'b0;

            if (busy && cycles != 16'hFFFF) begin
                cycles <= cycles + 16'd1;
            end

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        cycles <= 16'd0;
                        ciphertext <= {WIDTH{1'b0}};
                        if (message >= MODULUS) begin
                            error <= 1'b1;
                            done <= 1'b1;
                        end else begin
                            error <= 1'b0;
                            busy <= 1'b1;
                            saved_message <= message;
                            work_value <= message;
                            square_count <= 5'd0;
                            state <= ST_START_SQUARE;
                        end
                    end
                end

                ST_START_SQUARE: begin
                    mul_a <= work_value;
                    mul_b <= work_value;
                    mul_start <= 1'b1;
                    state <= ST_WAIT_SQUARE;
                end

                ST_WAIT_SQUARE: begin
                    if (mul_done) begin
                        work_value <= mul_result;
                        if (square_count == 5'd15) begin
                            state <= ST_START_FINAL;
                        end else begin
                            square_count <= square_count + 5'd1;
                            state <= ST_START_SQUARE;
                        end
                    end
                end

                ST_START_FINAL: begin
                    mul_a <= work_value;
                    mul_b <= saved_message;
                    mul_start <= 1'b1;
                    state <= ST_WAIT_FINAL;
                end

                ST_WAIT_FINAL: begin
                    if (mul_done) begin
                        ciphertext <= mul_result;
                        busy <= 1'b0;
                        done <= 1'b1;
                        error <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    busy <= 1'b0;
                    error <= 1'b1;
                    done <= 1'b1;
                end
            endcase
        end
    end

endmodule
