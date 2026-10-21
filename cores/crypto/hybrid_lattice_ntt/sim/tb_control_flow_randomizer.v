`timescale 1ns / 1ps

module tb_control_flow_randomizer;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;
localparam [2:0] OP_KEM_FLOW = 3'd4;

localparam integer SEQ_LEN = 24;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg seed_valid = 1'b0;
reg [31:0] seed = 32'h0000_0001;
reg enable = 1'b0;
reg in_valid = 1'b0;
reg [2:0] in_op = OP_KEM_NTT;
reg out_ready = 1'b1;

wire in_ready_dummy;
wire out_valid_dummy;
wire [2:0] out_op_dummy;
wire dummy_slot_dummy;
wire error_dummy;
wire [2:0] error_cause_dummy;
wire [31:0] lfsr_state_dummy;
wire [15:0] input_accepted_count_dummy;
wire [15:0] output_issued_count_dummy;
wire [15:0] dummy_slot_count_dummy;
wire [15:0] invalid_opcode_count_dummy;
wire [15:0] transition_count_dummy;

wire in_ready_fast;
wire out_valid_fast;
wire [2:0] out_op_fast;
wire dummy_slot_fast;
wire error_fast;
wire [2:0] error_cause_fast;
wire [31:0] lfsr_state_fast;
wire [15:0] input_accepted_count_fast;
wire [15:0] output_issued_count_fast;
wire [15:0] dummy_slot_count_fast;
wire [15:0] invalid_opcode_count_fast;
wire [15:0] transition_count_fast;

integer failures;
integer issue_index;
integer drain_cycles;
integer output_index_dummy;
integer output_index_fast;
integer dummy_seen_run1;
integer first_dummy_cycle_run1;
integer dummy_seen_run2;
integer first_dummy_cycle_run2;
integer cycle_index;
integer opcode_i;
integer issue_this_cycle;
reg [31:0] digest_in;
reg [31:0] digest_out_dummy;
reg [31:0] digest_out_fast;
reg [31:0] replay_state_after_run1;

always #5 clk = ~clk;

control_flow_randomizer #(
    .ENABLE_DUMMY_SLOTS(1)
) dut_dummy (
    .clk(clk),
    .rst_n(rst_n),
    .seed_valid(seed_valid),
    .seed(seed),
    .enable(enable),
    .in_valid(in_valid),
    .in_op(in_op),
    .in_ready(in_ready_dummy),
    .out_valid(out_valid_dummy),
    .out_op(out_op_dummy),
    .out_ready(out_ready),
    .dummy_slot(dummy_slot_dummy),
    .error(error_dummy),
    .error_cause(error_cause_dummy),
    .lfsr_state(lfsr_state_dummy),
    .input_accepted_count(input_accepted_count_dummy),
    .output_issued_count(output_issued_count_dummy),
    .dummy_slot_count(dummy_slot_count_dummy),
    .invalid_opcode_count(invalid_opcode_count_dummy),
    .transition_count(transition_count_dummy)
);

control_flow_randomizer #(
    .ENABLE_DUMMY_SLOTS(0)
) dut_fast (
    .clk(clk),
    .rst_n(rst_n),
    .seed_valid(seed_valid),
    .seed(seed),
    .enable(enable),
    .in_valid(in_valid),
    .in_op(in_op),
    .in_ready(in_ready_fast),
    .out_valid(out_valid_fast),
    .out_op(out_op_fast),
    .out_ready(out_ready),
    .dummy_slot(dummy_slot_fast),
    .error(error_fast),
    .error_cause(error_cause_fast),
    .lfsr_state(lfsr_state_fast),
    .input_accepted_count(input_accepted_count_fast),
    .output_issued_count(output_issued_count_fast),
    .dummy_slot_count(dummy_slot_count_fast),
    .invalid_opcode_count(invalid_opcode_count_fast),
    .transition_count(transition_count_fast)
);

function [2:0] seq_op;
    input integer index;
    begin
        case (index)
            0:  seq_op = OP_KEM_NTT;
            1:  seq_op = OP_DSA_NTT;
            2:  seq_op = OP_KEM_INTT;
            3:  seq_op = OP_DSA_INTT;
            4:  seq_op = OP_KEM_NTT;
            5:  seq_op = OP_KEM_INTT;
            6:  seq_op = OP_DSA_NTT;
            7:  seq_op = OP_DSA_INTT;
            8:  seq_op = OP_DSA_INTT;
            9:  seq_op = OP_KEM_NTT;
            10: seq_op = OP_DSA_NTT;
            11: seq_op = OP_KEM_INTT;
            12: seq_op = OP_KEM_NTT;
            13: seq_op = OP_DSA_NTT;
            14: seq_op = OP_KEM_INTT;
            15: seq_op = OP_DSA_INTT;
            16: seq_op = OP_KEM_NTT;
            17: seq_op = OP_KEM_NTT;
            18: seq_op = OP_DSA_NTT;
            19: seq_op = OP_DSA_INTT;
            20: seq_op = OP_KEM_INTT;
            21: seq_op = OP_DSA_NTT;
            22: seq_op = OP_KEM_INTT;
            default: seq_op = OP_DSA_INTT;
        endcase
    end
endfunction

function is_valid_scheduler_op;
    input [2:0] op;
    begin
        is_valid_scheduler_op = (op == OP_KEM_NTT) || (op == OP_DSA_NTT) ||
                                (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

function [31:0] digest_step;
    input [31:0] value;
    input [2:0] op;
    begin
        digest_step = rotl5(value) ^ {29'd0, op} ^
            (op[1] ? 32'h494e_5454 : 32'h004e_5454) ^
            (op[0] ? 32'h4453_4100 : 32'h4b45_4d00);
    end
endfunction

function [15:0] expected_transition_count;
    integer i;
    begin
        expected_transition_count = 16'd0;
        for (i = 1; i < SEQ_LEN; i = i + 1) begin
            if (seq_op(i) != seq_op(i - 1)) begin
                expected_transition_count = expected_transition_count + 16'd1;
            end
        end
    end
endfunction

task automatic reset_with_seed;
    input [31:0] requested_seed;
    begin
        rst_n = 1'b0;
        seed_valid = 1'b0;
        seed = requested_seed;
        enable = 1'b0;
        in_valid = 1'b0;
        in_op = OP_KEM_NTT;
        out_ready = 1'b1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        seed = requested_seed;
        seed_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        seed_valid = 1'b0;
    end
endtask

task automatic check_error_low;
    begin
        if (error_dummy || error_fast) begin
            $display("FAIL unexpected error dummy=%0d/%0d fast=%0d/%0d",
                     error_dummy, error_cause_dummy, error_fast, error_cause_fast);
            failures = failures + 1;
        end
    end
endtask

task automatic run_valid_stream;
    output integer dummy_seen;
    output integer first_dummy_cycle;
    output [31:0] dummy_digest;
    output [31:0] fast_digest;
    begin
        digest_in = 32'h4346_5258;
        digest_out_dummy = 32'h4346_5258;
        digest_out_fast = 32'h4346_5258;
        issue_index = 0;
        drain_cycles = 0;
        output_index_dummy = 0;
        output_index_fast = 0;
        dummy_seen = 0;
        first_dummy_cycle = -1;
        cycle_index = 0;

        while ((output_index_dummy < SEQ_LEN) || (output_index_fast < SEQ_LEN)) begin
            @(negedge clk);
            enable = 1'b1;
            #1;
            if ((issue_index < SEQ_LEN) && in_ready_dummy && in_ready_fast) begin
                in_valid = 1'b1;
                in_op = seq_op(issue_index);
                digest_in = digest_step(digest_in, seq_op(issue_index));
                issue_this_cycle = 1;
            end else begin
                in_valid = 1'b0;
                in_op = OP_KEM_NTT;
                issue_this_cycle = 0;
            end

            @(posedge clk);
            #1;
            check_error_low();

            if (issue_this_cycle) begin
                issue_index = issue_index + 1;
            end

            if (dummy_slot_dummy) begin
                dummy_seen = dummy_seen + 1;
                if (first_dummy_cycle < 0) begin
                    first_dummy_cycle = cycle_index;
                end
            end
            if (dummy_slot_fast) begin
                $display("FAIL fast instance emitted dummy slot");
                failures = failures + 1;
            end

            if (out_valid_dummy) begin
                if (!is_valid_scheduler_op(out_op_dummy)) begin
                    $display("FAIL dummy instance emitted invalid op=%0d", out_op_dummy);
                    failures = failures + 1;
                end
                if (out_op_dummy != seq_op(output_index_dummy)) begin
                    $display("FAIL dummy out[%0d]=%0d expected=%0d",
                             output_index_dummy, out_op_dummy, seq_op(output_index_dummy));
                    failures = failures + 1;
                end
                digest_out_dummy = digest_step(digest_out_dummy, out_op_dummy);
                output_index_dummy = output_index_dummy + 1;
            end
            if (out_valid_fast) begin
                if (!is_valid_scheduler_op(out_op_fast)) begin
                    $display("FAIL fast instance emitted invalid op=%0d", out_op_fast);
                    failures = failures + 1;
                end
                if (out_op_fast != seq_op(output_index_fast)) begin
                    $display("FAIL fast out[%0d]=%0d expected=%0d",
                             output_index_fast, out_op_fast, seq_op(output_index_fast));
                    failures = failures + 1;
                end
                digest_out_fast = digest_step(digest_out_fast, out_op_fast);
                output_index_fast = output_index_fast + 1;
            end

            if (issue_index >= SEQ_LEN) begin
                drain_cycles = drain_cycles + 1;
            end
            if (drain_cycles > 80) begin
                $display("FAIL valid stream timeout issued=%0d dummy_out=%0d fast_out=%0d",
                         issue_index, output_index_dummy, output_index_fast);
                failures = failures + 1;
                disable run_valid_stream;
            end
            cycle_index = cycle_index + 1;
        end

        @(negedge clk);
        enable = 1'b0;
        in_valid = 1'b0;
        in_op = OP_KEM_NTT;
        @(posedge clk);
        #1;

        dummy_digest = digest_out_dummy;
        fast_digest = digest_out_fast;
        if (digest_in != digest_out_dummy) begin
            $display("FAIL dummy digest=%08x expected=%08x", digest_out_dummy, digest_in);
            failures = failures + 1;
        end
        if (digest_in != digest_out_fast) begin
            $display("FAIL fast digest=%08x expected=%08x", digest_out_fast, digest_in);
            failures = failures + 1;
        end
        if (input_accepted_count_dummy != SEQ_LEN) begin
            $display("FAIL dummy accepted=%0d expected=%0d",
                     input_accepted_count_dummy, SEQ_LEN);
            failures = failures + 1;
        end
        if (output_issued_count_dummy != SEQ_LEN) begin
            $display("FAIL dummy issued=%0d expected=%0d",
                     output_issued_count_dummy, SEQ_LEN);
            failures = failures + 1;
        end
        if (input_accepted_count_fast != SEQ_LEN) begin
            $display("FAIL fast accepted=%0d expected=%0d",
                     input_accepted_count_fast, SEQ_LEN);
            failures = failures + 1;
        end
        if (output_issued_count_fast != SEQ_LEN) begin
            $display("FAIL fast issued=%0d expected=%0d",
                     output_issued_count_fast, SEQ_LEN);
            failures = failures + 1;
        end
        if (transition_count_dummy != expected_transition_count()) begin
            $display("FAIL dummy transitions=%0d expected=%0d",
                     transition_count_dummy, expected_transition_count());
            failures = failures + 1;
        end
        if (transition_count_fast != expected_transition_count()) begin
            $display("FAIL fast transitions=%0d expected=%0d",
                     transition_count_fast, expected_transition_count());
            failures = failures + 1;
        end
        if (invalid_opcode_count_dummy != 16'd0 || invalid_opcode_count_fast != 16'd0) begin
            $display("FAIL invalid counters nonzero dummy=%0d fast=%0d",
                     invalid_opcode_count_dummy, invalid_opcode_count_fast);
            failures = failures + 1;
        end
        if (dummy_slot_count_dummy != dummy_seen) begin
            $display("FAIL dummy counter=%0d observed=%0d",
                     dummy_slot_count_dummy, dummy_seen);
            failures = failures + 1;
        end
        if (dummy_slot_count_fast != 16'd0) begin
            $display("FAIL fast dummy counter=%0d", dummy_slot_count_fast);
            failures = failures + 1;
        end
    end
endtask

task automatic run_invalid_opcode_check;
    begin
        @(negedge clk);
        in_valid = 1'b1;
        in_op = OP_KEM_FLOW;
        @(posedge clk);
        #1;
        if (in_ready_dummy) begin
            if (!error_dummy || (error_cause_dummy != 3'd1)) begin
                $display("FAIL dummy invalid opcode did not raise error cause");
                failures = failures + 1;
            end
            if (out_valid_dummy) begin
                $display("FAIL dummy emitted invalid opcode as valid output");
                failures = failures + 1;
            end
        end
        if (in_ready_fast) begin
            if (!error_fast || (error_cause_fast != 3'd1)) begin
                $display("FAIL fast invalid opcode did not raise error cause");
                failures = failures + 1;
            end
            if (out_valid_fast) begin
                $display("FAIL fast emitted invalid opcode as valid output");
                failures = failures + 1;
            end
        end

        @(negedge clk);
        in_valid = 1'b0;
        in_op = OP_KEM_NTT;
        @(posedge clk);
        #1;

        if (invalid_opcode_count_fast != 16'd1) begin
            $display("FAIL fast invalid count=%0d expected=1", invalid_opcode_count_fast);
            failures = failures + 1;
        end
    end
endtask

task automatic run_backpressure_check;
    begin
        enable = 1'b0;

        @(negedge clk);
        #1;
        if (!in_ready_dummy || !in_ready_fast) begin
            $display("FAIL backpressure setup ready dummy=%0d fast=%0d",
                     in_ready_dummy, in_ready_fast);
            failures = failures + 1;
        end
        in_valid = 1'b1;
        in_op = OP_DSA_NTT;
        @(posedge clk);
        #1;
        if (!out_valid_dummy || (out_op_dummy != OP_DSA_NTT) ||
            !out_valid_fast || (out_op_fast != OP_DSA_NTT)) begin
            $display("FAIL backpressure first output dummy=%0d/%0d fast=%0d/%0d",
                     out_valid_dummy, out_op_dummy, out_valid_fast, out_op_fast);
            failures = failures + 1;
        end

        @(negedge clk);
        out_ready = 1'b0;
        in_valid = 1'b1;
        in_op = OP_KEM_INTT;
        #1;
        if (in_ready_dummy || in_ready_fast) begin
            $display("FAIL backpressure did not deassert ready dummy=%0d fast=%0d",
                     in_ready_dummy, in_ready_fast);
            failures = failures + 1;
        end
        @(posedge clk);
        #1;
        if (!out_valid_dummy || (out_op_dummy != OP_DSA_NTT) ||
            !out_valid_fast || (out_op_fast != OP_DSA_NTT)) begin
            $display("FAIL backpressure did not hold output dummy=%0d/%0d fast=%0d/%0d",
                     out_valid_dummy, out_op_dummy, out_valid_fast, out_op_fast);
            failures = failures + 1;
        end
        if ((input_accepted_count_dummy != 16'd1) ||
            (input_accepted_count_fast != 16'd1)) begin
            $display("FAIL backpressure accepted hidden input dummy=%0d fast=%0d",
                     input_accepted_count_dummy, input_accepted_count_fast);
            failures = failures + 1;
        end

        @(negedge clk);
        out_ready = 1'b1;
        in_valid = 1'b1;
        in_op = OP_KEM_INTT;
        #1;
        if (!in_ready_dummy || !in_ready_fast) begin
            $display("FAIL backpressure release ready dummy=%0d fast=%0d",
                     in_ready_dummy, in_ready_fast);
            failures = failures + 1;
        end
        @(posedge clk);
        #1;
        if (!out_valid_dummy || (out_op_dummy != OP_KEM_INTT) ||
            !out_valid_fast || (out_op_fast != OP_KEM_INTT)) begin
            $display("FAIL backpressure release output dummy=%0d/%0d fast=%0d/%0d",
                     out_valid_dummy, out_op_dummy, out_valid_fast, out_op_fast);
            failures = failures + 1;
        end
        if ((input_accepted_count_dummy != 16'd2) ||
            (input_accepted_count_fast != 16'd2) ||
            (output_issued_count_dummy != 16'd2) ||
            (output_issued_count_fast != 16'd2)) begin
            $display("FAIL backpressure final counts da=%0d fa=%0d di=%0d fi=%0d",
                     input_accepted_count_dummy, input_accepted_count_fast,
                     output_issued_count_dummy, output_issued_count_fast);
            failures = failures + 1;
        end
        if ((transition_count_dummy != 16'd1) || (transition_count_fast != 16'd1)) begin
            $display("FAIL backpressure transition counts dummy=%0d fast=%0d",
                     transition_count_dummy, transition_count_fast);
            failures = failures + 1;
        end

        @(negedge clk);
        in_valid = 1'b0;
        in_op = OP_KEM_NTT;
        @(posedge clk);
        #1;
    end
endtask

initial begin
    failures = 0;
    cycle_index = 0;

    reset_with_seed(32'h0000_0001);
    run_valid_stream(dummy_seen_run1, first_dummy_cycle_run1, digest_out_dummy, digest_out_fast);
    replay_state_after_run1 = lfsr_state_dummy;
    if (dummy_seen_run1 <= 0) begin
        $display("FAIL no dummy slots observed with enabled seeded mode");
        failures = failures + 1;
    end

    reset_with_seed(32'h0000_0001);
    run_valid_stream(dummy_seen_run2, first_dummy_cycle_run2, digest_out_dummy, digest_out_fast);
    if (dummy_seen_run1 != dummy_seen_run2) begin
        $display("FAIL deterministic dummy count mismatch %0d != %0d",
                 dummy_seen_run1, dummy_seen_run2);
        failures = failures + 1;
    end
    if (first_dummy_cycle_run1 != first_dummy_cycle_run2) begin
        $display("FAIL deterministic first dummy mismatch %0d != %0d",
                 first_dummy_cycle_run1, first_dummy_cycle_run2);
        failures = failures + 1;
    end
    if (replay_state_after_run1 != lfsr_state_dummy) begin
        $display("FAIL deterministic lfsr mismatch %08x != %08x",
                 replay_state_after_run1, lfsr_state_dummy);
        failures = failures + 1;
    end

    reset_with_seed(32'h2222_0001);
    run_backpressure_check();

    reset_with_seed(32'h3333_0001);
    run_invalid_opcode_check();

    for (opcode_i = 0; opcode_i < 4; opcode_i = opcode_i + 1) begin
        if (!is_valid_scheduler_op(opcode_i[2:0])) begin
            $display("FAIL valid opcode function rejected %0d", opcode_i);
            failures = failures + 1;
        end
    end

    if (failures == 0) begin
        $display("tb_control_flow_randomizer PASS replay dummy_count=%0d first_dummy=%0d digest=%08x fast_digest=%08x",
                 dummy_seen_run1, first_dummy_cycle_run1, digest_out_dummy, digest_out_fast);
        $finish;
    end else begin
        $display("tb_control_flow_randomizer FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (2000) @(posedge clk);
    $display("tb_control_flow_randomizer FAIL timeout");
    $fatal(1);
end

endmodule
