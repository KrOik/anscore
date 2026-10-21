module ntt256_systolic_arith_pipe #(
    parameter integer WIDTH = 23
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             in_valid,
    input  wire [2:0]       in_op,
    input  wire [4:0]       in_index,
    input  wire [WIDTH-1:0] in_a,
    input  wire [WIDTH-1:0] in_b,
    input  wire [WIDTH-1:0] in_twiddle,
    output wire             in_ready,
    output reg              out_valid,
    output reg  [2:0]       out_op,
    output reg  [4:0]       out_index,
    output reg  [WIDTH-1:0] out_y0,
    output reg  [WIDTH-1:0] out_y1,
    output reg  [15:0]      accepted_count
);

localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

reg valid_pipe [0:WIDTH-1];
reg [2:0] op_pipe [0:WIDTH-1];
reg [4:0] index_pipe [0:WIDTH-1];
reg inverse_pipe [0:WIDTH-1];
reg [WIDTH:0] q_pipe [0:WIDTH-1];
reg [WIDTH:0] a_pipe [0:WIDTH-1];
reg [WIDTH:0] acc_pipe [0:WIDTH-1];
reg [WIDTH:0] multiplicand_pipe [0:WIDTH-1];
reg [WIDTH-1:0] multiplier_pipe [0:WIDTH-1];

integer i;

assign in_ready = 1'b1;

function is_dsa_op;
    input [2:0] op;
    begin
        is_dsa_op = (op == OP_DSA_NTT) || (op == OP_DSA_INTT);
    end
endfunction

function is_inverse_op;
    input [2:0] op;
    begin
        is_inverse_op = (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

function [WIDTH:0] q_value;
    input [2:0] op;
    begin
        q_value = is_dsa_op(op) ? {1'b0, 23'd8380417} : {1'b0, 23'd3329};
    end
endfunction

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

wire [WIDTH:0] in_q = q_value(in_op);
wire [WIDTH:0] in_a_ext = {1'b0, in_a};
wire [WIDTH:0] in_b_ext = {1'b0, in_b};
wire [WIDTH:0] in_sum = mod_add(in_a_ext, in_b_ext, in_q);
wire [WIDTH:0] in_diff = mod_sub(in_a_ext, in_b_ext, in_q);
wire in_inverse = is_inverse_op(in_op);
wire [WIDTH:0] in_a_pass = in_inverse ? in_sum : in_a_ext;
wire [WIDTH:0] in_multiplicand = in_inverse ? in_diff : in_b_ext;
wire [WIDTH:0] in_acc = in_twiddle[0] ? in_multiplicand : {WIDTH+1{1'b0}};
wire [WIDTH:0] in_multiplicand_next = mod_add(in_multiplicand, in_multiplicand, in_q);
wire [WIDTH:0] out_forward_y0 = mod_add(a_pipe[WIDTH-1], acc_pipe[WIDTH-1], q_pipe[WIDTH-1]);
wire [WIDTH:0] out_forward_y1 = mod_sub(a_pipe[WIDTH-1], acc_pipe[WIDTH-1], q_pipe[WIDTH-1]);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_valid <= 1'b0;
        out_op <= 3'd0;
        out_index <= 5'd0;
        out_y0 <= {WIDTH{1'b0}};
        out_y1 <= {WIDTH{1'b0}};
        accepted_count <= 16'd0;
        for (i = 0; i < WIDTH; i = i + 1) begin
            valid_pipe[i] <= 1'b0;
            op_pipe[i] <= 3'd0;
            index_pipe[i] <= 5'd0;
            inverse_pipe[i] <= 1'b0;
            q_pipe[i] <= {WIDTH+1{1'b0}};
            a_pipe[i] <= {WIDTH+1{1'b0}};
            acc_pipe[i] <= {WIDTH+1{1'b0}};
            multiplicand_pipe[i] <= {WIDTH+1{1'b0}};
            multiplier_pipe[i] <= {WIDTH{1'b0}};
        end
    end else begin
        out_valid <= valid_pipe[WIDTH-1];
        out_op <= op_pipe[WIDTH-1];
        out_index <= index_pipe[WIDTH-1];
        out_y0 <= inverse_pipe[WIDTH-1] ? a_pipe[WIDTH-1][WIDTH-1:0] : out_forward_y0[WIDTH-1:0];
        out_y1 <= inverse_pipe[WIDTH-1] ? acc_pipe[WIDTH-1][WIDTH-1:0] : out_forward_y1[WIDTH-1:0];

        valid_pipe[0] <= in_valid && in_ready;
        op_pipe[0] <= in_op;
        index_pipe[0] <= in_index;
        inverse_pipe[0] <= in_inverse;
        q_pipe[0] <= in_q;
        a_pipe[0] <= in_a_pass;
        acc_pipe[0] <= in_acc;
        multiplicand_pipe[0] <= in_multiplicand_next;
        multiplier_pipe[0] <= {1'b0, in_twiddle[WIDTH-1:1]};

        for (i = 1; i < WIDTH; i = i + 1) begin
            valid_pipe[i] <= valid_pipe[i - 1];
            op_pipe[i] <= op_pipe[i - 1];
            index_pipe[i] <= index_pipe[i - 1];
            inverse_pipe[i] <= inverse_pipe[i - 1];
            q_pipe[i] <= q_pipe[i - 1];
            a_pipe[i] <= a_pipe[i - 1];
            acc_pipe[i] <= multiplier_pipe[i - 1][0]
                ? mod_add(acc_pipe[i - 1], multiplicand_pipe[i - 1], q_pipe[i - 1])
                : acc_pipe[i - 1];
            multiplicand_pipe[i] <= mod_add(
                multiplicand_pipe[i - 1],
                multiplicand_pipe[i - 1],
                q_pipe[i - 1]
            );
            multiplier_pipe[i] <= {1'b0, multiplier_pipe[i - 1][WIDTH-1:1]};
        end

        if (in_valid && in_ready) begin
            accepted_count <= accepted_count + 16'd1;
        end
    end
end

endmodule
