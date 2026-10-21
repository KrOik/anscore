`timescale 1ns / 1ps

module tb_hybrid_zero_switch_descriptor_sequencer;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg randomized_mode = 1'b0;
reg [31:0] seed = 32'd0;
reg [15:0] descriptor_count = 16'd0;
wire ready;
wire desc_valid;
wire [2:0] desc_op;
wire desc_ready;
wire busy;
wire done;
wire error;
wire [15:0] issued_count;
wire [15:0] accepted_count;
wire [15:0] invalid_bubble_count;
wire [15:0] op_transition_count;
wire [15:0] transition_mask;
wire [15:0] terminal_error_cause;

wire [7:0] stage_valid;
wire [7:0] stage_mode_dsa;
wire [7:0] stage_inverse;
wire [183:0] stage_q_flat;
wire [183:0] stage_root_flat;
wire [183:0] stage_n_inv_flat;
wire pipe_out_valid;
wire [2:0] pipe_out_op;
wire [31:0] pipe_out_signature;
wire [15:0] pipe_accepted_count;

reg replay_start = 1'b0;
wire replay_ready_a;
wire replay_valid_a;
wire [2:0] replay_op_a;
wire replay_busy_a;
wire replay_done_a;
wire replay_error_a;
wire [15:0] replay_issued_a;
wire [15:0] replay_accepted_a;
wire [15:0] replay_bubbles_a;
wire [15:0] replay_transitions_a;
wire [15:0] replay_mask_a;
wire [15:0] replay_error_cause_a;
wire replay_ready_b;
wire replay_valid_b;
wire [2:0] replay_op_b;
wire replay_busy_b;
wire replay_done_b;
wire replay_error_b;
wire [15:0] replay_issued_b;
wire [15:0] replay_accepted_b;
wire [15:0] replay_bubbles_b;
wire [15:0] replay_transitions_b;
wire [15:0] replay_mask_b;
wire [15:0] replay_error_cause_b;

integer failures = 0;
integer wait_cycles;
integer out_count;
integer first_output_seen;
integer pipe_bubbles;
integer invalid_seen;
integer replay_digest_a;
integer replay_digest_b;
reg [2:0] last_pipe_op;
reg [15:0] pipe_transition_mask;

always #5 clk = ~clk;

hybrid_zero_switch_descriptor_sequencer dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .randomized_mode(randomized_mode),
    .seed(seed),
    .descriptor_count(descriptor_count),
    .ready(ready),
    .desc_valid(desc_valid),
    .desc_op(desc_op),
    .desc_ready(desc_ready),
    .busy(busy),
    .done(done),
    .error(error),
    .issued_count(issued_count),
    .accepted_count(accepted_count),
    .invalid_bubble_count(invalid_bubble_count),
    .op_transition_count(op_transition_count),
    .transition_mask(transition_mask),
    .terminal_error_cause(terminal_error_cause)
);

ntt256_systolic_issue_pipe pipe (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(desc_valid),
    .in_op(desc_op),
    .in_ready(desc_ready),
    .stage_valid(stage_valid),
    .stage_mode_dsa(stage_mode_dsa),
    .stage_inverse(stage_inverse),
    .stage_q_flat(stage_q_flat),
    .stage_root_flat(stage_root_flat),
    .stage_n_inv_flat(stage_n_inv_flat),
    .out_valid(pipe_out_valid),
    .out_op(pipe_out_op),
    .out_signature(pipe_out_signature),
    .accepted_count(pipe_accepted_count)
);

hybrid_zero_switch_descriptor_sequencer replay_a (
    .clk(clk),
    .rst_n(rst_n),
    .start(replay_start),
    .randomized_mode(1'b1),
    .seed(32'h1234_5678),
    .descriptor_count(16'd64),
    .ready(replay_ready_a),
    .desc_valid(replay_valid_a),
    .desc_op(replay_op_a),
    .desc_ready(1'b1),
    .busy(replay_busy_a),
    .done(replay_done_a),
    .error(replay_error_a),
    .issued_count(replay_issued_a),
    .accepted_count(replay_accepted_a),
    .invalid_bubble_count(replay_bubbles_a),
    .op_transition_count(replay_transitions_a),
    .transition_mask(replay_mask_a),
    .terminal_error_cause(replay_error_cause_a)
);

hybrid_zero_switch_descriptor_sequencer replay_b (
    .clk(clk),
    .rst_n(rst_n),
    .start(replay_start),
    .randomized_mode(1'b1),
    .seed(32'h1234_5678),
    .descriptor_count(16'd64),
    .ready(replay_ready_b),
    .desc_valid(replay_valid_b),
    .desc_op(replay_op_b),
    .desc_ready(1'b1),
    .busy(replay_busy_b),
    .done(replay_done_b),
    .error(replay_error_b),
    .issued_count(replay_issued_b),
    .accepted_count(replay_accepted_b),
    .invalid_bubble_count(replay_bubbles_b),
    .op_transition_count(replay_transitions_b),
    .transition_mask(replay_mask_b),
    .terminal_error_cause(replay_error_cause_b)
);

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

function is_supported_op;
    input [2:0] op;
    begin
        is_supported_op = (op == OP_KEM_NTT) || (op == OP_DSA_NTT) ||
            (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

task automatic reset_all;
    begin
        rst_n = 1'b0;
        start = 1'b0;
        replay_start = 1'b0;
        randomized_mode = 1'b0;
        seed = 32'd0;
        descriptor_count = 16'd0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    end
endtask

task automatic launch_main;
    input random_i;
    input [31:0] seed_i;
    input [15:0] count_i;
    begin
        wait (ready);
        @(negedge clk);
        randomized_mode = random_i;
        seed = seed_i;
        descriptor_count = count_i;
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;
    end
endtask

task automatic launch_main_sample_done;
    input random_i;
    input [31:0] seed_i;
    input [15:0] count_i;
    output done_seen;
    begin
        wait (ready);
        @(negedge clk);
        randomized_mode = random_i;
        seed = seed_i;
        descriptor_count = count_i;
        start = 1'b1;
        @(posedge clk);
        #1;
        done_seen = done;
        @(negedge clk);
        start = 1'b0;
    end
endtask

task automatic run_pipe_stream;
    input [80*8-1:0] name;
    input random_i;
    input [31:0] seed_i;
    input [15:0] count_i;
    input [15:0] expected_mask_i;
    begin
        reset_all();
        launch_main(random_i, seed_i, count_i);
        out_count = 0;
        first_output_seen = 0;
        pipe_bubbles = 0;
        invalid_seen = 0;
        last_pipe_op = OP_KEM_NTT;
        pipe_transition_mask = 16'd0;
        wait_cycles = 0;

        while ((out_count < count_i) && (wait_cycles < 1000)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;

            if (desc_valid && !is_supported_op(desc_op)) begin
                invalid_seen = invalid_seen + 1;
            end

            if (pipe_out_valid) begin
                if (first_output_seen) begin
                    pipe_transition_mask[{last_pipe_op[1:0], pipe_out_op[1:0]}] =
                        1'b1;
                end
                first_output_seen = 1;
                last_pipe_op = pipe_out_op;
                out_count = out_count + 1;
            end else if (first_output_seen && (out_count < count_i)) begin
                pipe_bubbles = pipe_bubbles + 1;
            end
        end

        if (out_count != count_i) begin
            $display("FAIL %0s out_count=%0d expected=%0d", name, out_count, count_i);
            failures = failures + 1;
        end
        if (pipe_bubbles != 0) begin
            $display("FAIL %0s pipe_bubbles=%0d", name, pipe_bubbles);
            failures = failures + 1;
        end
        if (invalid_seen != 0) begin
            $display("FAIL %0s invalid_seen=%0d", name, invalid_seen);
            failures = failures + 1;
        end
        if (issued_count != count_i || accepted_count != count_i ||
            pipe_accepted_count != count_i) begin
            $display("FAIL %0s counts issued=%0d accepted=%0d pipe=%0d expected=%0d",
                     name, issued_count, accepted_count, pipe_accepted_count, count_i);
            failures = failures + 1;
        end
        if (invalid_bubble_count != 16'd0 || terminal_error_cause != 16'd0 ||
            error) begin
            $display("FAIL %0s error=%0d bubbles=%0d cause=%04x",
                     name, error, invalid_bubble_count, terminal_error_cause);
            failures = failures + 1;
        end
        if ((transition_mask & expected_mask_i) != expected_mask_i ||
            (pipe_transition_mask & expected_mask_i) != expected_mask_i) begin
            $display("FAIL %0s transition sequencer=%04x pipe=%04x expected=%04x",
                     name, transition_mask, pipe_transition_mask, expected_mask_i);
            failures = failures + 1;
        end
    end
endtask

reg zero_done_seen;

initial begin
    reset_all();

    run_pipe_stream("deterministic all ordered adjacent pairs",
                    1'b0, 32'd0, 16'd17, 16'hffff);
    run_pipe_stream("seeded randomized long mixed stream",
                    1'b1, 32'hc001_cafe, 16'd128, 16'h0000);

    reset_all();
    replay_digest_a = 32'h5250_4c41;
    replay_digest_b = 32'h5250_4c41;
    @(negedge clk);
    replay_start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    replay_start = 1'b0;

    wait_cycles = 0;
    while ((!replay_done_a || !replay_done_b) && (wait_cycles < 200)) begin
        @(posedge clk);
        #1;
        wait_cycles = wait_cycles + 1;
        if (replay_valid_a !== replay_valid_b || replay_op_a !== replay_op_b) begin
            $display("FAIL replay mismatch valid=%0d/%0d op=%0d/%0d",
                     replay_valid_a, replay_valid_b, replay_op_a, replay_op_b);
            failures = failures + 1;
        end
        if (replay_valid_a) begin
            replay_digest_a = rotl5(replay_digest_a) ^ {29'd0, replay_op_a};
        end
        if (replay_valid_b) begin
            replay_digest_b = rotl5(replay_digest_b) ^ {29'd0, replay_op_b};
        end
    end

    if (replay_digest_a != replay_digest_b || replay_accepted_a != 16'd64 ||
        replay_accepted_b != 16'd64 || replay_error_a || replay_error_b) begin
        $display("FAIL replay digest/count/error a=%08x b=%08x acc=%0d/%0d err=%0d/%0d",
                 replay_digest_a, replay_digest_b, replay_accepted_a,
                 replay_accepted_b, replay_error_a, replay_error_b);
        failures = failures + 1;
    end

    reset_all();
    launch_main_sample_done(1'b0, 32'd0, 16'd0, zero_done_seen);
    if (!zero_done_seen || !error || terminal_error_cause != 16'h0001) begin
        $display("FAIL zero descriptor error done=%0d error=%0d cause=%04x",
                 zero_done_seen, error, terminal_error_cause);
        failures = failures + 1;
    end

    if (failures == 0) begin
        $display("tb_hybrid_zero_switch_descriptor_sequencer PASS ordered_pairs=16 long_stream=128 replay=64");
        $finish;
    end else begin
        $display("tb_hybrid_zero_switch_descriptor_sequencer FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (4000) @(posedge clk);
    $display("tb_hybrid_zero_switch_descriptor_sequencer FAIL timeout");
    $fatal(1);
end

endmodule
