module ntt256_systolic_full_stream_selftest (
    input  wire        clk,
    input  wire        rst_n,
    output reg         done,
    output reg         pass,
    output reg         fail,
    output reg  [15:0] bubble_count,
    output reg  [15:0] issue_count,
    output reg  [15:0] output_count,
    output reg  [15:0] bank_check_count,
    output reg  [15:0] first_latency,
    output reg  [15:0] transition_mask,
    output reg  [15:0] fail_code,
    output reg  [31:0] signature
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam [1:0] S_ISSUE = 2'd0;
localparam [1:0] S_DRAIN = 2'd1;
localparam [1:0] S_DONE  = 2'd2;

localparam integer LATENCY = 23;
localparam integer META_LATENCY = 24;
localparam [15:0] TOTAL_SLOTS = 16'd3072;
localparam [15:0] SLOTS_PER_OP = 16'd1024;
localparam [15:0] EXPECTED_LATENCY = 16'd23;
localparam [15:0] EXPECTED_TRANSITIONS = 16'hc409;

reg [1:0] state;
reg [15:0] elapsed_cycles;
reg [1:0] issue_op_num;
reg [2:0] issue_stage;
reg [6:0] issue_bfly;
reg [1:0] expect_op_num;
reg [2:0] expect_stage;
reg [6:0] expect_bfly;
reg out_started;
reg [2:0] last_out_op;
reg [15:0] op0_output_count;
reg [15:0] op1_output_count;
reg [15:0] op2_output_count;

reg valid_meta [0:META_LATENCY-1];
reg [1:0] op_num_meta [0:META_LATENCY-1];
reg [2:0] op_meta [0:META_LATENCY-1];
reg [2:0] stage_meta [0:META_LATENCY-1];
reg [6:0] bfly_meta [0:META_LATENCY-1];
reg [7:0] addr_a_meta [0:META_LATENCY-1];
reg [7:0] addr_b_meta [0:META_LATENCY-1];
reg [1:0] bank_a_meta [0:META_LATENCY-1];
reg [1:0] bank_b_meta [0:META_LATENCY-1];
reg [22:0] input_a_meta [0:META_LATENCY-1];
reg [22:0] input_b_meta [0:META_LATENCY-1];
reg [22:0] twiddle_meta [0:META_LATENCY-1];

integer i;

wire pipe_valid = (state == S_ISSUE);
wire [2:0] pipe_op = seq_op(issue_op_num);
wire pipe_inverse = is_inverse_op(pipe_op);
wire [7:0] map_addr_a;
wire [7:0] map_addr_b;
wire [1:0] map_bank_a;
wire [1:0] map_bank_b;
wire map_conflict;
wire [22:0] pipe_a = input_a(pipe_op, issue_stage, map_addr_a);
wire [22:0] pipe_b = input_b(pipe_op, issue_stage, map_addr_b);
wire [22:0] pipe_twiddle = twiddle_for_slot(pipe_op, issue_stage, issue_bfly);
wire pipe_ready;
wire pipe_out_valid;
wire [2:0] pipe_out_op;
wire [4:0] pipe_out_index;
wire [22:0] pipe_out_y0;
wire [22:0] pipe_out_y1;
wire [15:0] pipe_accepted_count;

wire out_meta_inverse = is_inverse_op(op_meta[META_LATENCY-1]);
wire [7:0] out_map_addr_a;
wire [7:0] out_map_addr_b;
wire [1:0] out_map_bank_a;
wire [1:0] out_map_bank_b;
wire out_map_conflict;
wire [22:0] expected_out_y0 =
    expected_y0(op_meta[META_LATENCY-1], input_a_meta[META_LATENCY-1],
                input_b_meta[META_LATENCY-1], twiddle_meta[META_LATENCY-1]);
wire [22:0] expected_out_y1 =
    expected_y1(op_meta[META_LATENCY-1], input_a_meta[META_LATENCY-1],
                input_b_meta[META_LATENCY-1], twiddle_meta[META_LATENCY-1]);

ntt256_systolic_bank_mapper issue_mapper (
    .inverse(pipe_inverse),
    .stage(issue_stage),
    .butterfly_index(issue_bfly),
    .addr_a(map_addr_a),
    .addr_b(map_addr_b),
    .bank_a(map_bank_a),
    .bank_b(map_bank_b),
    .conflict(map_conflict)
);

ntt256_systolic_bank_mapper out_mapper (
    .inverse(out_meta_inverse),
    .stage(stage_meta[META_LATENCY-1]),
    .butterfly_index(bfly_meta[META_LATENCY-1]),
    .addr_a(out_map_addr_a),
    .addr_b(out_map_addr_b),
    .bank_a(out_map_bank_a),
    .bank_b(out_map_bank_b),
    .conflict(out_map_conflict)
);

ntt256_systolic_arith_pipe arith_pipe (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(pipe_valid),
    .in_op(pipe_op),
    .in_index(issue_bfly[4:0]),
    .in_a(pipe_a),
    .in_b(pipe_b),
    .in_twiddle(pipe_twiddle),
    .in_ready(pipe_ready),
    .out_valid(pipe_out_valid),
    .out_op(pipe_out_op),
    .out_index(pipe_out_index),
    .out_y0(pipe_out_y0),
    .out_y1(pipe_out_y1),
    .accepted_count(pipe_accepted_count)
);

function [2:0] seq_op;
    input [1:0] op_num;
    begin
        case (op_num)
            2'd0: seq_op = OP_KEM_NTT;
            2'd1: seq_op = OP_DSA_INTT;
            default: seq_op = OP_KEM_INTT;
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

function [22:0] q_value;
    input [2:0] op;
    begin
        q_value = is_dsa_op(op) ? 23'd8380417 : 23'd3329;
    end
endfunction

function [22:0] root_value;
    input [2:0] op;
    begin
        root_value = is_dsa_op(op) ? 23'd3073009 : 23'd17;
    end
endfunction

function [22:0] reduce_once_or_twice;
    input [31:0] raw_in;
    input [22:0] q;
    reg [31:0] raw;
    begin
        raw = raw_in;
        if (raw >= {9'd0, q}) begin
            raw = raw - {9'd0, q};
        end
        if (raw >= {9'd0, q}) begin
            raw = raw - {9'd0, q};
        end
        reduce_once_or_twice = raw[22:0];
    end
endfunction

function [22:0] input_a;
    input [2:0] op;
    input [2:0] stage;
    input [7:0] addr;
    reg [31:0] raw;
    begin
        if (is_dsa_op(op)) begin
            raw = 32'd12345 + ({24'd0, addr} << 14) +
                ({24'd0, addr} << 4) + ({29'd0, stage} << 8) +
                {29'd0, op};
        end else begin
            raw = 32'd5 + ({24'd0, addr} << 4) + {24'd0, addr} +
                ({29'd0, stage} << 5) + {29'd0, op};
        end
        input_a = reduce_once_or_twice(raw, q_value(op));
    end
endfunction

function [22:0] input_b;
    input [2:0] op;
    input [2:0] stage;
    input [7:0] addr;
    reg [31:0] raw;
    begin
        if (is_dsa_op(op)) begin
            raw = 32'd54321 + ({24'd0, addr} << 13) +
                ({24'd0, addr} << 5) + ({29'd0, stage} << 7) +
                ({29'd0, op} << 1);
        end else begin
            raw = 32'd7 + ({24'd0, addr} << 5) - {24'd0, addr} +
                ({29'd0, stage} << 4) + ({29'd0, op} << 1);
        end
        input_b = reduce_once_or_twice(raw, q_value(op));
    end
endfunction

function [7:0] slot_exponent;
    input [2:0] op;
    input [2:0] stage;
    input [6:0] bfly;
    reg [2:0] gap_log;
    reg [7:0] low_mask;
    reg [7:0] j_value;
    reg [3:0] shift_value;
    begin
        gap_log = is_inverse_op(op) ? (3'd7 - stage) : stage;
        low_mask = (8'd1 << gap_log) - 8'd1;
        j_value = {1'b0, bfly} & low_mask;
        shift_value = 4'd7 - {1'b0, gap_log};
        slot_exponent = j_value << shift_value;
    end
endfunction

function [22:0] modmul_ref;
    input [22:0] x;
    input [22:0] y;
    input [22:0] q;
    reg [63:0] product;
    begin
        product = {41'd0, x} * {41'd0, y};
        modmul_ref = product % {41'd0, q};
    end
endfunction

function [22:0] pow_mod_ref;
    input [22:0] base;
    input [7:0] exponent;
    input [22:0] q;
    reg [22:0] acc;
    integer pow_i;
    begin
        acc = 23'd1;
        for (pow_i = 0; pow_i < 255; pow_i = pow_i + 1) begin
            if (pow_i < exponent) begin
                acc = modmul_ref(acc, base, q);
            end
        end
        pow_mod_ref = acc;
    end
endfunction

function [22:0] twiddle_for_slot;
    input [2:0] op;
    input [2:0] stage;
    input [6:0] bfly;
    reg [7:0] exponent;
    reg [7:0] pow_exponent;
    begin
        exponent = slot_exponent(op, stage, bfly);
        pow_exponent = (is_inverse_op(op) && (exponent != 8'd0))
            ? (8'd0 - exponent)
            : exponent;
        twiddle_for_slot = pow_mod_ref(root_value(op), pow_exponent, q_value(op));
    end
endfunction

function [22:0] mod_add_ref;
    input [22:0] x;
    input [22:0] y;
    input [22:0] q;
    reg [23:0] sum;
    begin
        sum = {1'b0, x} + {1'b0, y};
        if (sum >= {1'b0, q}) begin
            sum = sum - {1'b0, q};
        end
        mod_add_ref = sum[22:0];
    end
endfunction

function [22:0] mod_sub_ref;
    input [22:0] x;
    input [22:0] y;
    input [22:0] q;
    begin
        if (x >= y) begin
            mod_sub_ref = x - y;
        end else begin
            mod_sub_ref = x + q - y;
        end
    end
endfunction

function [22:0] expected_y0;
    input [2:0] op;
    input [22:0] a;
    input [22:0] b;
    input [22:0] twiddle;
    reg [22:0] q;
    reg [22:0] product;
    begin
        q = q_value(op);
        if (is_inverse_op(op)) begin
            expected_y0 = mod_add_ref(a, b, q);
        end else begin
            product = modmul_ref(b, twiddle, q);
            expected_y0 = mod_add_ref(a, product, q);
        end
    end
endfunction

function [22:0] expected_y1;
    input [2:0] op;
    input [22:0] a;
    input [22:0] b;
    input [22:0] twiddle;
    reg [22:0] q;
    reg [22:0] product;
    begin
        q = q_value(op);
        if (is_inverse_op(op)) begin
            product = modmul_ref(mod_sub_ref(a, b, q), twiddle, q);
            expected_y1 = product;
        end else begin
            product = modmul_ref(b, twiddle, q);
            expected_y1 = mod_sub_ref(a, product, q);
        end
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

task advance_expected_output;
    begin
        if (expect_bfly == 7'd127) begin
            expect_bfly <= 7'd0;
            if (expect_stage == 3'd7) begin
                expect_stage <= 3'd0;
                if (expect_op_num != 2'd2) begin
                    expect_op_num <= expect_op_num + 2'd1;
                end
            end else begin
                expect_stage <= expect_stage + 3'd1;
            end
        end else begin
            expect_bfly <= expect_bfly + 7'd1;
        end
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_ISSUE;
        elapsed_cycles <= 16'd0;
        issue_op_num <= 2'd0;
        issue_stage <= 3'd0;
        issue_bfly <= 7'd0;
        expect_op_num <= 2'd0;
        expect_stage <= 3'd0;
        expect_bfly <= 7'd0;
        out_started <= 1'b0;
        last_out_op <= OP_KEM_NTT;
        op0_output_count <= 16'd0;
        op1_output_count <= 16'd0;
        op2_output_count <= 16'd0;
        done <= 1'b0;
        pass <= 1'b0;
        fail <= 1'b0;
        bubble_count <= 16'd0;
        issue_count <= 16'd0;
        output_count <= 16'd0;
        bank_check_count <= 16'd0;
        first_latency <= 16'hffff;
        transition_mask <= 16'd0;
        fail_code <= 16'd0;
        signature <= 32'h46554c4c;
        for (i = 0; i < META_LATENCY; i = i + 1) begin
            valid_meta[i] <= 1'b0;
            op_num_meta[i] <= 2'd0;
            op_meta[i] <= OP_KEM_NTT;
            stage_meta[i] <= 3'd0;
            bfly_meta[i] <= 7'd0;
            addr_a_meta[i] <= 8'd0;
            addr_b_meta[i] <= 8'd0;
            bank_a_meta[i] <= 2'd0;
            bank_b_meta[i] <= 2'd0;
            input_a_meta[i] <= 23'd0;
            input_b_meta[i] <= 23'd0;
            twiddle_meta[i] <= 23'd0;
        end
    end else begin
        if (!done) begin
            elapsed_cycles <= elapsed_cycles + 16'd1;
        end

        valid_meta[0] <= pipe_valid && pipe_ready;
        op_num_meta[0] <= issue_op_num;
        op_meta[0] <= pipe_op;
        stage_meta[0] <= issue_stage;
        bfly_meta[0] <= issue_bfly;
        addr_a_meta[0] <= map_addr_a;
        addr_b_meta[0] <= map_addr_b;
        bank_a_meta[0] <= map_bank_a;
        bank_b_meta[0] <= map_bank_b;
        input_a_meta[0] <= pipe_a;
        input_b_meta[0] <= pipe_b;
        twiddle_meta[0] <= pipe_twiddle;
        for (i = 1; i < META_LATENCY; i = i + 1) begin
            valid_meta[i] <= valid_meta[i - 1];
            op_num_meta[i] <= op_num_meta[i - 1];
            op_meta[i] <= op_meta[i - 1];
            stage_meta[i] <= stage_meta[i - 1];
            bfly_meta[i] <= bfly_meta[i - 1];
            addr_a_meta[i] <= addr_a_meta[i - 1];
            addr_b_meta[i] <= addr_b_meta[i - 1];
            bank_a_meta[i] <= bank_a_meta[i - 1];
            bank_b_meta[i] <= bank_b_meta[i - 1];
            input_a_meta[i] <= input_a_meta[i - 1];
            input_b_meta[i] <= input_b_meta[i - 1];
            twiddle_meta[i] <= twiddle_meta[i - 1];
        end

        if (pipe_out_valid) begin
            out_started <= 1'b1;
            if (!out_started) begin
                first_latency <= elapsed_cycles - 16'd1;
            end else begin
                transition_mask[{last_out_op[1:0], pipe_out_op[1:0]}] <= 1'b1;
            end
            last_out_op <= pipe_out_op;
            output_count <= output_count + 16'd1;
            signature <= rotl5(signature) ^
                {9'd0, pipe_out_y0} ^
                {9'd0, pipe_out_y1} ^
                {24'd0, addr_a_meta[META_LATENCY-1]} ^
                {24'd0, addr_b_meta[META_LATENCY-1]} ^
                {20'd0, op_num_meta[META_LATENCY-1], stage_meta[META_LATENCY-1], bfly_meta[META_LATENCY-1]} ^
                {9'd0, twiddle_meta[META_LATENCY-1]};

            case (op_num_meta[META_LATENCY-1])
                2'd0: op0_output_count <= op0_output_count + 16'd1;
                2'd1: op1_output_count <= op1_output_count + 16'd1;
                default: op2_output_count <= op2_output_count + 16'd1;
            endcase

            if (output_count >= TOTAL_SLOTS) begin
                fail <= 1'b1;
                fail_code <= fail_code | 16'h0001;
            end
            if (!valid_meta[META_LATENCY-1]) begin
                fail <= 1'b1;
                fail_code <= fail_code | 16'h0002;
            end
            if (pipe_out_op != op_meta[META_LATENCY-1]) begin
                fail <= 1'b1;
                fail_code <= fail_code | 16'h0004;
            end
            if (pipe_out_index != bfly_meta[META_LATENCY-1][4:0]) begin
                fail <= 1'b1;
                fail_code <= fail_code | 16'h0008;
            end
            if ((op_num_meta[META_LATENCY-1] != expect_op_num) ||
                (stage_meta[META_LATENCY-1] != expect_stage) ||
                (bfly_meta[META_LATENCY-1] != expect_bfly)) begin
                fail <= 1'b1;
                fail_code <= fail_code | 16'h0010;
            end
            if ((out_map_addr_a != addr_a_meta[META_LATENCY-1]) ||
                (out_map_addr_b != addr_b_meta[META_LATENCY-1]) ||
                (out_map_bank_a != bank_a_meta[META_LATENCY-1]) ||
                (out_map_bank_b != bank_b_meta[META_LATENCY-1]) ||
                out_map_conflict) begin
                fail <= 1'b1;
                fail_code <= fail_code | 16'h0020;
            end
            if ((pipe_out_y0 != expected_out_y0) ||
                (pipe_out_y1 != expected_out_y1)) begin
                fail <= 1'b1;
                fail_code <= fail_code | 16'h0040;
            end

            advance_expected_output();
        end else if (out_started && (output_count < TOTAL_SLOTS)) begin
            bubble_count <= bubble_count + 16'd1;
            fail <= 1'b1;
            fail_code <= fail_code | 16'h0080;
        end

        case (state)
            S_ISSUE: begin
                if (!pipe_ready) begin
                    fail <= 1'b1;
                    fail_code <= fail_code | 16'h0100;
                end else begin
                    issue_count <= issue_count + 16'd1;
                    bank_check_count <= bank_check_count + 16'd1;
                    if (map_conflict || (map_bank_a == map_bank_b) ||
                        (map_addr_b <= map_addr_a)) begin
                        fail <= 1'b1;
                        fail_code <= fail_code | 16'h0200;
                    end

                    if (issue_bfly == 7'd127) begin
                        issue_bfly <= 7'd0;
                        if (issue_stage == 3'd7) begin
                            issue_stage <= 3'd0;
                            if (issue_op_num == 2'd2) begin
                                state <= S_DRAIN;
                            end else begin
                                issue_op_num <= issue_op_num + 2'd1;
                            end
                        end else begin
                            issue_stage <= issue_stage + 3'd1;
                        end
                    end else begin
                        issue_bfly <= issue_bfly + 7'd1;
                    end
                end
            end

            S_DRAIN: begin
                if (output_count == TOTAL_SLOTS) begin
                    state <= S_DONE;
                end
            end

            S_DONE: begin
                done <= 1'b1;
                pass <= !fail &&
                    (bubble_count == 16'd0) &&
                    (issue_count == TOTAL_SLOTS) &&
                    (output_count == TOTAL_SLOTS) &&
                    (bank_check_count == TOTAL_SLOTS) &&
                    (pipe_accepted_count == TOTAL_SLOTS) &&
                    (first_latency == EXPECTED_LATENCY) &&
                    (op0_output_count == SLOTS_PER_OP) &&
                    (op1_output_count == SLOTS_PER_OP) &&
                    (op2_output_count == SLOTS_PER_OP) &&
                    ((transition_mask & EXPECTED_TRANSITIONS) == EXPECTED_TRANSITIONS);
            end

            default: state <= S_DONE;
        endcase
    end
end

endmodule
