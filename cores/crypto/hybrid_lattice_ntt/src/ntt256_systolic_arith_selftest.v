module ntt256_systolic_arith_selftest (
    input  wire        clk,
    input  wire        rst_n,
    output reg         done,
    output reg         pass,
    output reg         fail,
    output reg  [15:0] bubble_count,
    output reg  [15:0] issue_count,
    output reg  [15:0] pair_mask,
    output reg  [31:0] signature
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam [1:0] S_ISSUE = 2'd0;
localparam [1:0] S_DRAIN = 2'd1;
localparam [1:0] S_DONE  = 2'd2;
localparam [4:0] SEQ_LEN = 5'd17;
localparam [31:0] EXPECTED_SIGNATURE = 32'hef556c7c;

reg [1:0] state;
reg [4:0] issue_index;
reg [4:0] out_count;
reg out_started;
reg [2:0] last_out_op;

wire pipe_valid = (state == S_ISSUE);
wire [2:0] pipe_op = seq_op(issue_index);
wire pipe_ready;
wire pipe_out_valid;
wire [2:0] pipe_out_op;
wire [4:0] pipe_out_index;
wire [22:0] pipe_out_y0;
wire [22:0] pipe_out_y1;
wire [15:0] pipe_accepted_count;

ntt256_systolic_arith_pipe arith_pipe (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(pipe_valid),
    .in_op(pipe_op),
    .in_index(issue_index),
    .in_a(input_a(pipe_op, issue_index)),
    .in_b(input_b(pipe_op, issue_index)),
    .in_twiddle(input_twiddle(pipe_op, issue_index)),
    .in_ready(pipe_ready),
    .out_valid(pipe_out_valid),
    .out_op(pipe_out_op),
    .out_index(pipe_out_index),
    .out_y0(pipe_out_y0),
    .out_y1(pipe_out_y1),
    .accepted_count(pipe_accepted_count)
);

function [2:0] seq_op;
    input [4:0] index;
    begin
        case (index)
            5'd0: seq_op = OP_KEM_NTT;
            5'd1: seq_op = OP_KEM_NTT;
            5'd2: seq_op = OP_DSA_NTT;
            5'd3: seq_op = OP_KEM_NTT;
            5'd4: seq_op = OP_KEM_INTT;
            5'd5: seq_op = OP_KEM_NTT;
            5'd6: seq_op = OP_DSA_INTT;
            5'd7: seq_op = OP_DSA_NTT;
            5'd8: seq_op = OP_DSA_NTT;
            5'd9: seq_op = OP_KEM_INTT;
            5'd10: seq_op = OP_DSA_NTT;
            5'd11: seq_op = OP_DSA_INTT;
            5'd12: seq_op = OP_KEM_INTT;
            5'd13: seq_op = OP_KEM_INTT;
            5'd14: seq_op = OP_DSA_INTT;
            5'd15: seq_op = OP_DSA_INTT;
            default: seq_op = OP_KEM_NTT;
        endcase
    end
endfunction

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

function [22:0] input_a;
    input [2:0] op;
    input [4:0] index;
    reg [31:0] raw;
    begin
        if (is_dsa_op(op)) begin
            raw = 32'd12345 + ({19'd0, index, 8'd0, 8'd0}) + {27'd0, index};
            input_a = raw[22:0];
        end else begin
            input_a = 23'd5 + ({14'd0, index, 4'd0}) + {18'd0, index};
        end
    end
endfunction

function [22:0] input_b;
    input [2:0] op;
    input [4:0] index;
    reg [31:0] raw;
    begin
        if (is_dsa_op(op)) begin
            raw = 32'd54321 + ({15'd0, index, 12'd0}) -
                ({26'd0, index, 1'b0} + {27'd0, index});
            input_b = raw[22:0];
        end else begin
            input_b = 23'd7 + ({13'd0, index, 5'd0}) - {18'd0, index};
        end
    end
endfunction

function [22:0] input_twiddle;
    input [2:0] op;
    input [4:0] index;
    begin
        if (is_dsa_op(op)) begin
            if (is_inverse_op(op)) begin
                case (index[2:0])
                    3'd0: input_twiddle = 23'd5307408;
                    3'd1: input_twiddle = 23'd3572223;
                    3'd2: input_twiddle = 23'd4614810;
                    3'd3: input_twiddle = 23'd4618904;
                    3'd4: input_twiddle = 23'd3201494;
                    3'd5: input_twiddle = 23'd3145678;
                    3'd6: input_twiddle = 23'd2883726;
                    default: input_twiddle = 23'd3201430;
                endcase
            end else begin
                case (index[2:0])
                    3'd0: input_twiddle = 23'd3073009;
                    3'd1: input_twiddle = 23'd4808194;
                    3'd2: input_twiddle = 23'd3765607;
                    3'd3: input_twiddle = 23'd3761513;
                    3'd4: input_twiddle = 23'd5178923;
                    3'd5: input_twiddle = 23'd5234739;
                    3'd6: input_twiddle = 23'd5496691;
                    default: input_twiddle = 23'd5178987;
                endcase
            end
        end else if (is_inverse_op(op)) begin
            case (index[2:0])
                3'd0: input_twiddle = 23'd3312;
                3'd1: input_twiddle = 23'd1600;
                3'd2: input_twiddle = 23'd749;
                3'd3: input_twiddle = 23'd40;
                3'd4: input_twiddle = 23'd687;
                3'd5: input_twiddle = 23'd1432;
                3'd6: input_twiddle = 23'd2699;
                default: input_twiddle = 23'd2481;
            endcase
        end else begin
            case (index[2:0])
                3'd0: input_twiddle = 23'd17;
                3'd1: input_twiddle = 23'd1729;
                3'd2: input_twiddle = 23'd2580;
                3'd3: input_twiddle = 23'd3289;
                3'd4: input_twiddle = 23'd2642;
                3'd5: input_twiddle = 23'd1897;
                3'd6: input_twiddle = 23'd630;
                default: input_twiddle = 23'd848;
            endcase
        end
    end
endfunction

function [22:0] expected_y0;
    input [4:0] index;
    begin
        case (index)
            5'd0: expected_y0 = 23'd124;
            5'd1: expected_y0 = 23'd2473;
            5'd2: expected_y0 = 23'd4548306;
            5'd3: expected_y0 = 23'd2714;
            5'd4: expected_y0 = 23'd204;
            5'd5: expected_y0 = 23'd1136;
            5'd6: expected_y0 = 23'd484446;
            5'd7: expected_y0 = 23'd5498793;
            5'd8: expected_y0 = 23'd7252501;
            5'd9: expected_y0 = 23'd444;
            5'd10: expected_y0 = 23'd5032889;
            5'd11: expected_y0 = 23'd832596;
            5'd12: expected_y0 = 23'd588;
            5'd13: expected_y0 = 23'd636;
            5'd14: expected_y0 = 23'd1041486;
            5'd15: expected_y0 = 23'd1111116;
            default: expected_y0 = 23'd2170;
        endcase
    end
endfunction

function [22:0] expected_y1;
    input [4:0] index;
    begin
        case (index)
            5'd0: expected_y1 = 23'd3215;
            5'd1: expected_y1 = 23'd900;
            5'd2: expected_y1 = 23'd4118949;
            5'd3: expected_y1 = 23'd727;
            5'd4: expected_y1 = 23'd102;
            5'd5: expected_y1 = 23'd2373;
            5'd6: expected_y1 = 23'd2482850;
            5'd7: expected_y1 = 23'd3823832;
            5'd8: expected_y1 = 23'd2201198;
            5'd9: expected_y1 = 23'd1598;
            5'd10: expected_y1 = 23'd4682958;
            5'd11: expected_y1 = 23'd1724955;
            5'd12: expected_y1 = 23'd3054;
            5'd13: expected_y1 = 23'd2832;
            5'd14: expected_y1 = 23'd6512554;
            5'd15: expected_y1 = 23'd7615270;
            default: expected_y1 = 23'd1713;
        endcase
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_ISSUE;
        issue_index <= 5'd0;
        out_count <= 5'd0;
        out_started <= 1'b0;
        last_out_op <= OP_KEM_NTT;
        done <= 1'b0;
        pass <= 1'b0;
        fail <= 1'b0;
        bubble_count <= 16'd0;
        issue_count <= 16'd0;
        pair_mask <= 16'd0;
        signature <= 32'h53595341;
    end else begin
        if (!done && pipe_out_valid) begin
            signature <= rotl5(signature) ^
                {9'd0, pipe_out_y0} ^
                {9'd0, pipe_out_y1} ^
                {29'd0, pipe_out_op} ^
                {27'd0, pipe_out_index};
        end

        if (pipe_out_valid) begin
            out_started <= 1'b1;
            if ((out_count >= SEQ_LEN) ||
                (pipe_out_op != seq_op(out_count)) ||
                (pipe_out_index != out_count) ||
                (pipe_out_y0 != expected_y0(out_count)) ||
                (pipe_out_y1 != expected_y1(out_count))) begin
                fail <= 1'b1;
            end else begin
                if (out_started) begin
                    pair_mask[{last_out_op[1:0], pipe_out_op[1:0]}] <= 1'b1;
                end
                last_out_op <= pipe_out_op;
                out_count <= out_count + 5'd1;
            end
        end else if (out_started && (out_count < SEQ_LEN)) begin
            bubble_count <= bubble_count + 16'd1;
            fail <= 1'b1;
        end

        case (state)
            S_ISSUE: begin
                if (!pipe_ready) begin
                    fail <= 1'b1;
                end else begin
                    issue_count <= issue_count + 16'd1;
                end

                if (issue_index == (SEQ_LEN - 1'b1)) begin
                    state <= S_DRAIN;
                end else begin
                    issue_index <= issue_index + 5'd1;
                end
            end

            S_DRAIN: begin
                if (out_count == SEQ_LEN) begin
                    state <= S_DONE;
                end
            end

            S_DONE: begin
                done <= 1'b1;
                pass <= !fail &&
                    (bubble_count == 16'd0) &&
                    (issue_count == {11'd0, SEQ_LEN}) &&
                    (pipe_accepted_count == {11'd0, SEQ_LEN}) &&
                    (pair_mask == 16'hffff) &&
                    (signature == EXPECTED_SIGNATURE);
            end

            default: state <= S_DONE;
        endcase
    end
end

endmodule
