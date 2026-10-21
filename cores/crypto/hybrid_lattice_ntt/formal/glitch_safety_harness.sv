`default_nettype none

`ifdef GLITCH_ABSTRACT_BUTTERFLY
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
    (* anyseq *) reg [WIDTH-1:0] y0_seq;
    (* anyseq *) reg [WIDTH-1:0] y1_seq;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y0 <= {WIDTH{1'b0}};
            y1 <= {WIDTH{1'b0}};
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= busy;
            busy <= start;
            if (busy) begin
                y0 <= y0_seq;
                y1 <= y1_seq;
            end
        end
    end
endmodule
`endif

module glitch_safety_harness (
    input wire clk
);
    localparam integer WIDTH = 23;
    localparam integer MAX_LATENCY = WIDTH + 4;

    reg rst_n;
    reg past_valid;

    (* anyseq *) reg start_seq;
    (* anyseq *) reg mode_dsa_seq;
    (* anyseq *) reg inverse_mode_seq;
    (* anyseq *) reg [WIDTH-1:0] a_left_seq;
    (* anyseq *) reg [WIDTH-1:0] b_left_seq;
    (* anyseq *) reg [WIDTH-1:0] twiddle_left_seq;
    (* anyseq *) reg [WIDTH-1:0] a_right_seq;
    (* anyseq *) reg [WIDTH-1:0] b_right_seq;
    (* anyseq *) reg [WIDTH-1:0] twiddle_right_seq;

    reg start;
    reg mode_dsa;
    reg inverse_mode;
    reg [WIDTH-1:0] a_left;
    reg [WIDTH-1:0] b_left;
    reg [WIDTH-1:0] twiddle_left;
    reg [WIDTH-1:0] a_right;
    reg [WIDTH-1:0] b_right;
    reg [WIDTH-1:0] twiddle_right;

    wire [WIDTH-1:0] y0_left;
    wire [WIDTH-1:0] y1_left;
    wire busy_left;
    wire done_left;
    wire [WIDTH-1:0] y0_right;
    wire [WIDTH-1:0] y1_right;
    wire busy_right;
    wire done_right;

    reg [7:0] active_age;

    initial begin
        rst_n = 1'b0;
        past_valid = 1'b0;
        start = 1'b0;
        mode_dsa = 1'b0;
        inverse_mode = 1'b0;
        a_left = {WIDTH{1'b0}};
        b_left = {WIDTH{1'b0}};
        twiddle_left = {{(WIDTH-1){1'b0}}, 1'b1};
        a_right = {WIDTH{1'b0}};
        b_right = {WIDTH{1'b0}};
        twiddle_right = {{(WIDTH-1){1'b0}}, 1'b1};
        active_age = 8'd0;
    end

    fused_butterfly #(
        .WIDTH(WIDTH)
    ) dut_left (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .mode_dsa(mode_dsa),
        .inverse_mode(inverse_mode),
        .a(a_left),
        .b(b_left),
        .twiddle(twiddle_left),
        .y0(y0_left),
        .y1(y1_left),
        .busy(busy_left),
        .done(done_left)
    );

    fused_butterfly #(
        .WIDTH(WIDTH)
    ) dut_right (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .mode_dsa(mode_dsa),
        .inverse_mode(inverse_mode),
        .a(a_right),
        .b(b_right),
        .twiddle(twiddle_right),
        .y0(y0_right),
        .y1(y1_right),
        .busy(busy_right),
        .done(done_right)
    );

    always @(posedge clk) begin
        past_valid <= 1'b1;
        rst_n <= 1'b1;

        if (!past_valid) begin
            assume(!rst_n);
            assume(!start);
        end else begin
            assume(rst_n);
        end

        if (!rst_n) begin
            start <= 1'b0;
            mode_dsa <= 1'b0;
            inverse_mode <= 1'b0;
            a_left <= {WIDTH{1'b0}};
            b_left <= {WIDTH{1'b0}};
            twiddle_left <= {{(WIDTH-1){1'b0}}, 1'b1};
            a_right <= {WIDTH{1'b0}};
            b_right <= {WIDTH{1'b0}};
            twiddle_right <= {{(WIDTH-1){1'b0}}, 1'b1};
            active_age <= 8'd0;
        end else begin
            start <= start_seq && !busy_left && !busy_right && !done_left && !done_right;
            mode_dsa <= mode_dsa_seq;
            inverse_mode <= inverse_mode_seq;
            a_left <= a_left_seq;
            b_left <= b_left_seq;
            twiddle_left <= twiddle_left_seq;
            a_right <= a_right_seq;
            b_right <= b_right_seq;
            twiddle_right <= twiddle_right_seq;

            if (start && !busy_left && !busy_right) begin
                active_age <= 8'd1;
            end else if (done_left && done_right) begin
                active_age <= 8'd0;
            end else if (active_age != 8'd0) begin
                active_age <= active_age + 8'd1;
            end
        end

        if (past_valid && $past(rst_n)) begin
            if ($past(start)) begin
                assert(busy_left);
                assert(busy_right);
            end

            if ($past(done_left)) begin
                assert(!done_left);
            end

            if ($past(done_right)) begin
                assert(!done_right);
            end

            if ($past(busy_left && !done_left && !done_right)) begin
                assert(busy_left || done_left);
            end

            if ($past(busy_right && !done_left && !done_right)) begin
                assert(busy_right || done_right);
            end

            if (busy_left || busy_right) begin
                assume(!start);
            end

            if (busy_left || busy_right || done_left || done_right) begin
                assume($stable(mode_dsa));
                assume($stable(inverse_mode));
            end
        end

        if (rst_n) begin
            assert(busy_left == busy_right);
            assert(done_left == done_right);

            if (done_left || done_right) begin
                assert(!busy_left);
                assert(!busy_right);
            end

            if (active_age != 8'd0) begin
                assert(active_age <= MAX_LATENCY[7:0]);
            end
        end

        cover(rst_n && start);
        cover(rst_n && done_left && done_right);
        cover(rst_n && mode_dsa && inverse_mode && done_left && done_right);
    end
endmodule

module glitch_masked2_harness (
    input wire clk
);
    localparam integer WIDTH = 23;
    localparam integer MAX_LATENCY = 8;

    reg rst_n;
    reg past_valid;

    (* anyseq *) reg start_seq;
    (* anyseq *) reg mode_dsa_seq;
    (* anyseq *) reg inverse_mode_seq;
    (* anyseq *) reg random_valid_seq;
    (* anyseq *) reg [WIDTH-1:0] a_left_share0_seq;
    (* anyseq *) reg [WIDTH-1:0] a_left_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] a_left_share2_seq;
    (* anyseq *) reg [WIDTH-1:0] b_left_share0_seq;
    (* anyseq *) reg [WIDTH-1:0] b_left_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] b_left_share2_seq;
    (* anyseq *) reg [WIDTH-1:0] tw_left_share0_seq;
    (* anyseq *) reg [WIDTH-1:0] tw_left_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] tw_left_share2_seq;
    (* anyseq *) reg [WIDTH-1:0] a_right_share0_seq;
    (* anyseq *) reg [WIDTH-1:0] a_right_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] a_right_share2_seq;
    (* anyseq *) reg [WIDTH-1:0] b_right_share0_seq;
    (* anyseq *) reg [WIDTH-1:0] b_right_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] b_right_share2_seq;
    (* anyseq *) reg [WIDTH-1:0] tw_right_share0_seq;
    (* anyseq *) reg [WIDTH-1:0] tw_right_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] tw_right_share2_seq;
    (* anyseq *) reg [WIDTH-1:0] random_y0_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] random_y0_share2_seq;
    (* anyseq *) reg [WIDTH-1:0] random_y1_share1_seq;
    (* anyseq *) reg [WIDTH-1:0] random_y1_share2_seq;

    reg start;
    reg mode_dsa;
    reg inverse_mode;
    reg random_valid;
    reg [WIDTH-1:0] a_left_share0;
    reg [WIDTH-1:0] a_left_share1;
    reg [WIDTH-1:0] a_left_share2;
    reg [WIDTH-1:0] b_left_share0;
    reg [WIDTH-1:0] b_left_share1;
    reg [WIDTH-1:0] b_left_share2;
    reg [WIDTH-1:0] tw_left_share0;
    reg [WIDTH-1:0] tw_left_share1;
    reg [WIDTH-1:0] tw_left_share2;
    reg [WIDTH-1:0] a_right_share0;
    reg [WIDTH-1:0] a_right_share1;
    reg [WIDTH-1:0] a_right_share2;
    reg [WIDTH-1:0] b_right_share0;
    reg [WIDTH-1:0] b_right_share1;
    reg [WIDTH-1:0] b_right_share2;
    reg [WIDTH-1:0] tw_right_share0;
    reg [WIDTH-1:0] tw_right_share1;
    reg [WIDTH-1:0] tw_right_share2;
    reg [WIDTH-1:0] random_y0_share1;
    reg [WIDTH-1:0] random_y0_share2;
    reg [WIDTH-1:0] random_y1_share1;
    reg [WIDTH-1:0] random_y1_share2;

    wire [WIDTH-1:0] y0_left_share0;
    wire [WIDTH-1:0] y0_left_share1;
    wire [WIDTH-1:0] y0_left_share2;
    wire [WIDTH-1:0] y1_left_share0;
    wire [WIDTH-1:0] y1_left_share1;
    wire [WIDTH-1:0] y1_left_share2;
    wire [WIDTH-1:0] y0_right_share0;
    wire [WIDTH-1:0] y0_right_share1;
    wire [WIDTH-1:0] y0_right_share2;
    wire [WIDTH-1:0] y1_right_share0;
    wire [WIDTH-1:0] y1_right_share1;
    wire [WIDTH-1:0] y1_right_share2;
    wire random_ready_left;
    wire random_ready_right;
    wire busy_left;
    wire busy_right;
    wire done_left;
    wire done_right;
    wire error_left;
    wire error_right;
    wire random_missing_error_left;
    wire random_missing_error_right;
    wire [15:0] random_accept_count_left;
    wire [15:0] random_accept_count_right;

    reg [3:0] active_age;
    reg [WIDTH-1:0] accepted_y0_share1;
    reg [WIDTH-1:0] accepted_y0_share2;
    reg [WIDTH-1:0] accepted_y1_share1;
    reg [WIDTH-1:0] accepted_y1_share2;

    initial begin
        rst_n = 1'b0;
        past_valid = 1'b0;
        start = 1'b0;
        mode_dsa = 1'b0;
        inverse_mode = 1'b0;
        random_valid = 1'b0;
        a_left_share0 = {WIDTH{1'b0}};
        a_left_share1 = {WIDTH{1'b0}};
        a_left_share2 = {WIDTH{1'b0}};
        b_left_share0 = {WIDTH{1'b0}};
        b_left_share1 = {WIDTH{1'b0}};
        b_left_share2 = {WIDTH{1'b0}};
        tw_left_share0 = {{(WIDTH-1){1'b0}}, 1'b1};
        tw_left_share1 = {WIDTH{1'b0}};
        tw_left_share2 = {WIDTH{1'b0}};
        a_right_share0 = {WIDTH{1'b0}};
        a_right_share1 = {WIDTH{1'b0}};
        a_right_share2 = {WIDTH{1'b0}};
        b_right_share0 = {WIDTH{1'b0}};
        b_right_share1 = {WIDTH{1'b0}};
        b_right_share2 = {WIDTH{1'b0}};
        tw_right_share0 = {{(WIDTH-1){1'b0}}, 1'b1};
        tw_right_share1 = {WIDTH{1'b0}};
        tw_right_share2 = {WIDTH{1'b0}};
        random_y0_share1 = {WIDTH{1'b0}};
        random_y0_share2 = {WIDTH{1'b0}};
        random_y1_share1 = {WIDTH{1'b0}};
        random_y1_share2 = {WIDTH{1'b0}};
        active_age = 4'd0;
        accepted_y0_share1 = {WIDTH{1'b0}};
        accepted_y0_share2 = {WIDTH{1'b0}};
        accepted_y1_share1 = {WIDTH{1'b0}};
        accepted_y1_share2 = {WIDTH{1'b0}};
    end

    fused_butterfly_masked2 #(
        .WIDTH(WIDTH)
    ) dut_left (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .mode_dsa(mode_dsa),
        .inverse_mode(inverse_mode),
        .a_share0(a_left_share0),
        .a_share1(a_left_share1),
        .a_share2(a_left_share2),
        .b_share0(b_left_share0),
        .b_share1(b_left_share1),
        .b_share2(b_left_share2),
        .twiddle_share0(tw_left_share0),
        .twiddle_share1(tw_left_share1),
        .twiddle_share2(tw_left_share2),
        .random_valid(random_valid),
        .random_ready(random_ready_left),
        .random_y0_share1(random_y0_share1),
        .random_y0_share2(random_y0_share2),
        .random_y1_share1(random_y1_share1),
        .random_y1_share2(random_y1_share2),
        .y0_share0(y0_left_share0),
        .y0_share1(y0_left_share1),
        .y0_share2(y0_left_share2),
        .y1_share0(y1_left_share0),
        .y1_share1(y1_left_share1),
        .y1_share2(y1_left_share2),
        .busy(busy_left),
        .done(done_left),
        .error(error_left),
        .random_missing_error(random_missing_error_left),
        .random_accept_count(random_accept_count_left)
    );

    fused_butterfly_masked2 #(
        .WIDTH(WIDTH)
    ) dut_right (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .mode_dsa(mode_dsa),
        .inverse_mode(inverse_mode),
        .a_share0(a_right_share0),
        .a_share1(a_right_share1),
        .a_share2(a_right_share2),
        .b_share0(b_right_share0),
        .b_share1(b_right_share1),
        .b_share2(b_right_share2),
        .twiddle_share0(tw_right_share0),
        .twiddle_share1(tw_right_share1),
        .twiddle_share2(tw_right_share2),
        .random_valid(random_valid),
        .random_ready(random_ready_right),
        .random_y0_share1(random_y0_share1),
        .random_y0_share2(random_y0_share2),
        .random_y1_share1(random_y1_share1),
        .random_y1_share2(random_y1_share2),
        .y0_share0(y0_right_share0),
        .y0_share1(y0_right_share1),
        .y0_share2(y0_right_share2),
        .y1_share0(y1_right_share0),
        .y1_share1(y1_right_share1),
        .y1_share2(y1_right_share2),
        .busy(busy_right),
        .done(done_right),
        .error(error_right),
        .random_missing_error(random_missing_error_right),
        .random_accept_count(random_accept_count_right)
    );

    glitch_randomness_boundary_checker #(
        .RANDOM_WIDTH(4 * WIDTH)
    ) randomness_checker (
        .clk(clk),
        .rst_n(rst_n),
        .accept_op(start && random_ready_left),
        .randomness_valid(random_valid),
        .randomness({
            random_y0_share1,
            random_y0_share2,
            random_y1_share1,
            random_y1_share2
        }),
        .error_missing_randomness(random_missing_error_left)
    );

    always @(posedge clk) begin
        past_valid <= 1'b1;
        rst_n <= 1'b1;

        if (!past_valid) begin
            assume(!rst_n);
            assume(!start);
        end else begin
            assume(rst_n);
        end

        if (!rst_n) begin
            start <= 1'b0;
            mode_dsa <= 1'b0;
            inverse_mode <= 1'b0;
            random_valid <= 1'b0;
            active_age <= 4'd0;
            accepted_y0_share1 <= {WIDTH{1'b0}};
            accepted_y0_share2 <= {WIDTH{1'b0}};
            accepted_y1_share1 <= {WIDTH{1'b0}};
            accepted_y1_share2 <= {WIDTH{1'b0}};
        end else begin
            start <= start_seq && random_ready_left && random_ready_right;
            mode_dsa <= mode_dsa_seq;
            inverse_mode <= inverse_mode_seq;
            random_valid <= random_valid_seq;
            a_left_share0 <= a_left_share0_seq;
            a_left_share1 <= a_left_share1_seq;
            a_left_share2 <= a_left_share2_seq;
            b_left_share0 <= b_left_share0_seq;
            b_left_share1 <= b_left_share1_seq;
            b_left_share2 <= b_left_share2_seq;
            tw_left_share0 <= tw_left_share0_seq;
            tw_left_share1 <= tw_left_share1_seq;
            tw_left_share2 <= tw_left_share2_seq;
            a_right_share0 <= a_right_share0_seq;
            a_right_share1 <= a_right_share1_seq;
            a_right_share2 <= a_right_share2_seq;
            b_right_share0 <= b_right_share0_seq;
            b_right_share1 <= b_right_share1_seq;
            b_right_share2 <= b_right_share2_seq;
            tw_right_share0 <= tw_right_share0_seq;
            tw_right_share1 <= tw_right_share1_seq;
            tw_right_share2 <= tw_right_share2_seq;
            random_y0_share1 <= random_y0_share1_seq;
            random_y0_share2 <= random_y0_share2_seq;
            random_y1_share1 <= random_y1_share1_seq;
            random_y1_share2 <= random_y1_share2_seq;

            if (start && random_valid && random_ready_left) begin
                active_age <= 4'd1;
                accepted_y0_share1 <= random_y0_share1;
                accepted_y0_share2 <= random_y0_share2;
                accepted_y1_share1 <= random_y1_share1;
                accepted_y1_share2 <= random_y1_share2;
            end else if (done_left && done_right) begin
                active_age <= 4'd0;
            end else if (active_age != 4'd0) begin
                active_age <= active_age + 4'd1;
            end
        end

        if (past_valid && $past(rst_n)) begin
            if ($past(start && random_ready_left && !random_valid)) begin
                assert(done_left);
                assert(done_right);
                assert(!busy_left);
                assert(!busy_right);
                assert(error_left);
                assert(error_right);
                assert(random_missing_error_left);
                assert(random_missing_error_right);
            end

            if ($past(start && random_ready_left && random_valid)) begin
                assert(busy_left);
                assert(busy_right);
            end
        end

        if (rst_n) begin
            assert(random_ready_left == random_ready_right);
            assert(busy_left == busy_right);
            assert(done_left == done_right);
            assert(error_left == error_right);
            assert(random_missing_error_left == random_missing_error_right);
            assert(random_accept_count_left == random_accept_count_right);

            if (active_age != 4'd0) begin
                assert(active_age <= MAX_LATENCY[3:0]);
            end

            if (done_left && !error_left) begin
                assert(y0_left_share1 == accepted_y0_share1);
                assert(y0_left_share2 == accepted_y0_share2);
                assert(y1_left_share1 == accepted_y1_share1);
                assert(y1_left_share2 == accepted_y1_share2);
            end
        end

        cover(rst_n && start && random_valid);
        cover(rst_n && done_left && !error_left);
        cover(rst_n && done_left && random_missing_error_left);
    end
endmodule

module glitch_randomizer_harness (
    input wire clk
);
    localparam [2:0] OP_KEM_NTT  = 3'd0;
    localparam [2:0] OP_DSA_NTT  = 3'd1;
    localparam [2:0] OP_KEM_INTT = 3'd2;
    localparam [2:0] OP_DSA_INTT = 3'd3;

    reg rst_n;
    reg past_valid;

    (* anyseq *) reg seed_valid_seq;
    (* anyseq *) reg [31:0] seed_seq;
    (* anyseq *) reg enable_seq;
    (* anyseq *) reg in_valid_seq;
    (* anyseq *) reg [2:0] in_op_seq;
    (* anyseq *) reg out_ready_seq;

    reg seed_valid;
    reg [31:0] seed;
    reg enable;
    reg in_valid;
    reg [2:0] in_op;
    reg out_ready;

    wire in_ready;
    wire out_valid;
    wire [2:0] out_op;
    wire dummy_slot;
    wire error;
    wire [2:0] error_cause;
    wire [31:0] lfsr_state;
    wire [15:0] input_accepted_count;
    wire [15:0] output_issued_count;
    wire [15:0] dummy_slot_count;
    wire [15:0] invalid_opcode_count;
    wire [15:0] transition_count;

    wire in_supported =
        (in_op == OP_KEM_NTT) ||
        (in_op == OP_DSA_NTT) ||
        (in_op == OP_KEM_INTT) ||
        (in_op == OP_DSA_INTT);

    initial begin
        rst_n = 1'b0;
        past_valid = 1'b0;
        seed_valid = 1'b0;
        seed = 32'd0;
        enable = 1'b0;
        in_valid = 1'b0;
        in_op = OP_KEM_NTT;
        out_ready = 1'b1;
    end

    control_flow_randomizer #(
        .ENABLE_DUMMY_SLOTS(1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .seed_valid(seed_valid),
        .seed(seed),
        .enable(enable),
        .in_valid(in_valid),
        .in_op(in_op),
        .in_ready(in_ready),
        .out_valid(out_valid),
        .out_op(out_op),
        .out_ready(out_ready),
        .dummy_slot(dummy_slot),
        .error(error),
        .error_cause(error_cause),
        .lfsr_state(lfsr_state),
        .input_accepted_count(input_accepted_count),
        .output_issued_count(output_issued_count),
        .dummy_slot_count(dummy_slot_count),
        .invalid_opcode_count(invalid_opcode_count),
        .transition_count(transition_count)
    );

    glitch_valid_ready_boundary_checker in_boundary (
        .clk(clk),
        .rst_n(rst_n),
        .valid_i(in_valid),
        .ready_i(in_ready),
        .valid_o(out_valid),
        .ready_o(out_ready)
    );

    glitch_opcode_boundary_checker opcode_boundary (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(out_valid),
        .issue_opcode(out_op),
        .issue_dummy(dummy_slot),
        .issue_error(error)
    );

    always @(posedge clk) begin
        past_valid <= 1'b1;
        rst_n <= 1'b1;

        if (!past_valid) begin
            assume(!rst_n);
            assume(!in_valid);
            assume(!seed_valid);
        end else begin
            assume(rst_n);
        end

        if (!rst_n) begin
            seed_valid <= 1'b0;
            seed <= 32'd0;
            enable <= 1'b0;
            in_valid <= 1'b0;
            in_op <= OP_KEM_NTT;
            out_ready <= 1'b1;
        end else begin
            seed_valid <= seed_valid_seq;
            seed <= seed_seq;
            enable <= enable_seq;
            in_valid <= in_valid_seq;
            in_op <= in_op_seq;
            out_ready <= out_ready_seq;
        end

        if (past_valid && $past(rst_n)) begin
            if ($past(in_valid && !in_ready)) begin
                assume(in_valid);
                assume(in_op == $past(in_op));
            end

            if ($past(out_valid && !out_ready)) begin
                assert(out_valid);
                assert(out_op == $past(out_op));
                assert(dummy_slot == $past(dummy_slot));
            end

            if ($past(in_valid && in_ready && !in_supported)) begin
                assert(error || dummy_slot);
                assert(!out_valid);
            end
        end

        if (rst_n) begin
            if (out_valid) begin
                assert(!dummy_slot);
            end
        end

        cover(rst_n && in_valid && in_ready && in_supported && out_valid);
        cover(rst_n && in_valid && in_ready && !in_supported && error);
        cover(rst_n && dummy_slot);
    end
endmodule

module glitch_valid_ready_boundary_checker (
    input wire clk,
    input wire rst_n,
    input wire valid_i,
    input wire ready_i,
    input wire valid_o,
    input wire ready_o
);
    reg past_valid;

    initial begin
        past_valid = 1'b0;
    end

    always @(posedge clk) begin
        past_valid <= 1'b1;

        if (past_valid && rst_n && $past(rst_n)) begin
            if ($past(valid_i && !ready_i)) begin
                assume(valid_i);
            end

            if ($past(valid_o && !ready_o)) begin
                assert(valid_o);
            end
        end
    end
endmodule

module glitch_randomness_boundary_checker #(
    parameter integer RANDOM_WIDTH = 69
) (
    input wire clk,
    input wire rst_n,
    input wire accept_op,
    input wire randomness_valid,
    input wire [RANDOM_WIDTH-1:0] randomness,
    input wire error_missing_randomness
);
    reg past_valid;
    reg [RANDOM_WIDTH-1:0] accepted_randomness;

    initial begin
        past_valid = 1'b0;
        accepted_randomness = {RANDOM_WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        past_valid <= 1'b1;

        if (!rst_n) begin
            accepted_randomness <= {RANDOM_WIDTH{1'b0}};
        end else if (accept_op && randomness_valid) begin
            accepted_randomness <= randomness;
        end

        if (past_valid && rst_n && $past(rst_n)) begin
            if ($past(accept_op && !randomness_valid)) begin
                assert(error_missing_randomness);
            end

            if (!$past(accept_op && randomness_valid)) begin
                assert(accepted_randomness == $past(accepted_randomness));
            end
        end
    end
endmodule

module glitch_opcode_boundary_checker #(
    parameter integer OPCODE_WIDTH = 3,
    parameter [OPCODE_WIDTH-1:0] OP_KEM_NTT = 3'd0,
    parameter [OPCODE_WIDTH-1:0] OP_DSA_NTT = 3'd1,
    parameter [OPCODE_WIDTH-1:0] OP_KEM_INTT = 3'd2,
    parameter [OPCODE_WIDTH-1:0] OP_DSA_INTT = 3'd3
) (
    input wire clk,
    input wire rst_n,
    input wire issue_valid,
    input wire [OPCODE_WIDTH-1:0] issue_opcode,
    input wire issue_dummy,
    input wire issue_error
);
    wire supported_opcode =
        (issue_opcode == OP_KEM_NTT) ||
        (issue_opcode == OP_DSA_NTT) ||
        (issue_opcode == OP_KEM_INTT) ||
        (issue_opcode == OP_DSA_INTT);

    always @(posedge clk) begin
        if (rst_n && issue_valid && !issue_dummy) begin
            assert(supported_opcode || issue_error);
        end
    end
endmodule

`default_nettype wire
