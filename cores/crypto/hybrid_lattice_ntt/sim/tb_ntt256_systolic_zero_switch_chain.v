`timescale 1ns / 1ps
// End-to-end zero-switch composition test: descriptor sequencer -> descriptor
// bridge -> coefficient-state systolic array.
//
// Both halves are tested on their own already (the sequencer against an II=1
// consumer, the array against a testbench launcher), but nothing has yet shown a
// KEM/DSA NTT/INTT switch travelling from a producer all the way into the array
// without a drain, a reset or a reconfiguration cycle in between.  This bench is
// that evidence, and it measures the claim instead of asserting it:
//
//   * the sequencer issues 17 descriptors in its deterministic order, a 17-term
//     sequence whose 16 adjacent pairs are exactly the 16 ordered KEM/DSA x
//     NTT/INTT transitions.  Every one of them has to be executed back to back.
//   * max_handoff must come out as 1 edge: the array raises done and frees its
//     idle state in the same edge, so an accept on the next edge wastes nothing.
//     dead_cycle_count and underrun_cycles must stay 0.
//   * every completion is checked against the frozen digest of the op the
//     sequencer issued at that position, in order, so a re-ordered, dropped or
//     aliased descriptor cannot pass.
//   * the negative half wires the same bridge to a small model array so each
//     error path is reachable in a handful of cycles instead of three thousand,
//     and each measured quantity is shown to move when the behaviour it measures
//     gets worse.  Without those, "0 dead cycles" would be indistinguishable from
//     a counter that never counts.
module tb_ntt256_systolic_zero_switch_chain;

localparam [2:0] OP_KEM_NTT   = 3'd0;
localparam [2:0] OP_DSA_NTT   = 3'd1;
localparam [2:0] OP_KEM_INTT  = 3'd2;
localparam [2:0] OP_DSA_INTT  = 3'd3;

localparam integer MAXD = 64;

localparam [15:0] ERR_ZERO_COUNT  = 16'h0001;
localparam [15:0] ERR_OVER_PUSH   = 16'h0002;
localparam [15:0] ERR_UNSUPPORTED = 16'h0004;
localparam [15:0] ERR_ARRAY       = 16'h0008;
localparam [15:0] ERR_HANDOFF     = 16'h0010;

localparam [1:0] F_IDLE  = 2'd0;
localparam [1:0] F_RUN   = 2'd1;
localparam [1:0] F_STALL = 2'd2;

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// producer
// ---------------------------------------------------------------------------
reg seq_start = 1'b0;
reg seq_randomized = 1'b0;
reg [31:0] seq_seed = 32'd0;
reg [15:0] seq_count = 16'd0;
wire seq_ready;
wire seq_desc_valid;
wire [2:0] seq_desc_op;
wire seq_desc_ready;
wire seq_busy;
wire seq_done;
wire seq_error;
wire [15:0] seq_issued;
wire [15:0] seq_accepted;
wire [15:0] seq_bubbles;
wire [15:0] seq_transitions;
wire [15:0] seq_mask;
wire [15:0] seq_cause;

// ---------------------------------------------------------------------------
// the bridge in between
// ---------------------------------------------------------------------------
reg bridge_start = 1'b0;
reg [15:0] bridge_count = 16'd0;
wire bridge_desc_ready;
wire bridge_array_start;
wire [2:0] bridge_array_op;
wire [2:0] bridge_running_op;
wire bridge_ready;
wire bridge_busy;
wire bridge_done;
wire bridge_error;
wire [15:0] bridge_cause;
wire [15:0] bridge_pushed;
wire [15:0] bridge_launched;
wire [15:0] bridge_completed;
wire [15:0] bridge_dead;
wire [15:0] bridge_max_handoff;
wire [15:0] bridge_underrun;
wire [7:0] bridge_level;

// ---------------------------------------------------------------------------
// consumer
// ---------------------------------------------------------------------------
wire array_start_ready;
wire array_busy;
wire array_done;
wire array_pass;
wire array_error;
wire array_out_valid;
wire [2:0] array_out_op;
wire [4:0] array_out_index;
wire [22:0] array_out_y0;
wire [22:0] array_out_y1;
wire [15:0] array_issue_count;
wire [15:0] array_output_count;
wire [15:0] array_bubble_count;
wire [15:0] array_bank_check_count;
wire [15:0] array_first_latency;
wire [31:0] array_digest;
wire [31:0] array_signature;

// ---------------------------------------------------------------------------
// negative half: the same bridge wired to a model array
// ---------------------------------------------------------------------------
reg [15:0] neg_count = 16'd0;
reg neg_start = 1'b0;
reg [2:0] neg_desc_op = OP_KEM_NTT;
reg neg_desc_valid = 1'b0;
wire neg_desc_ready;
wire neg_array_start;
wire [2:0] neg_array_op;
wire [2:0] neg_running_op;
wire neg_ready;
wire neg_busy;
wire neg_done;
wire neg_error;
wire [15:0] neg_cause;
wire [15:0] neg_pushed;
wire [15:0] neg_launched;
wire [15:0] neg_completed;
wire [15:0] neg_dead;
wire [15:0] neg_max_handoff;
wire [15:0] neg_underrun;
wire [7:0] neg_level;

// The model array presents the same handshake shape as the real one: ready and
// done both rise in the finishing edge, and done is a level that survives until
// the next accept.  run_len, stall_len and inject_error make each of the
// measured quantities reachable.
reg [1:0] f_state = F_IDLE;
reg [7:0] f_timer = 8'd0;
reg f_done = 1'b0;
reg f_error = 1'b0;
reg [7:0] f_run_len = 8'd4;
reg [7:0] f_stall_len = 8'd0;
reg f_stall_pending = 1'b0;
reg f_inject_error = 1'b0;
wire f_fake_ready = (f_state == F_IDLE);
wire f_fake_done = f_done;
wire f_fake_error = f_error;
wire f_accept = neg_array_start && f_fake_ready;

hybrid_zero_switch_descriptor_sequencer #(.MAX_DESCRIPTORS(MAXD)) seq (
    .clk(clk), .rst_n(rst_n), .start(seq_start),
    .randomized_mode(seq_randomized), .seed(seq_seed),
    .descriptor_count(seq_count), .ready(seq_ready),
    .desc_valid(seq_desc_valid), .desc_op(seq_desc_op),
    .desc_ready(seq_desc_ready), .busy(seq_busy), .done(seq_done),
    .error(seq_error), .issued_count(seq_issued),
    .accepted_count(seq_accepted), .invalid_bubble_count(seq_bubbles),
    .op_transition_count(seq_transitions), .transition_mask(seq_mask),
    .terminal_error_cause(seq_cause));

hybrid_descriptor_bridge #(.DEPTH(MAXD)) bridge (
    .clk(clk), .rst_n(rst_n), .start(bridge_start),
    .descriptor_count(bridge_count),
    .desc_valid(seq_desc_valid), .desc_op(seq_desc_op),
    .desc_ready(bridge_desc_ready),
    .array_start_ready(array_start_ready), .array_done(array_done),
    .array_error(array_error), .array_start(bridge_array_start),
    .array_op(bridge_array_op), .running_op(bridge_running_op),
    .ready(bridge_ready), .busy(bridge_busy), .done(bridge_done),
    .error(bridge_error), .terminal_error_cause(bridge_cause),
    .pushed_count(bridge_pushed), .launched_count(bridge_launched),
    .complete_count(bridge_completed), .dead_cycle_count(bridge_dead),
    .max_handoff(bridge_max_handoff), .underrun_cycles(bridge_underrun),
    .fifo_level(bridge_level));

ntt256_systolic_state_array syst_array (
    .clk(clk), .rst_n(rst_n), .start(bridge_array_start),
    .op(bridge_array_op), .auto_init(1'b1), .check_expected(1'b1),
    .coeff_load_valid(1'b0), .coeff_load_addr(8'd0),
    .coeff_load_data(23'd0), .coeff_load_ready(),
    .start_ready(array_start_ready), .busy(array_busy),
    .done(array_done), .pass(array_pass), .error(array_error),
    .out_valid(array_out_valid), .out_op(array_out_op),
    .out_index(array_out_index), .out_y0(array_out_y0),
    .out_y1(array_out_y1), .issue_count(array_issue_count),
    .output_count(array_output_count), .bubble_count(array_bubble_count),
    .bank_check_count(array_bank_check_count),
    .first_latency(array_first_latency), .digest(array_digest),
    .signature(array_signature));

hybrid_descriptor_bridge #(.DEPTH(8)) neg_bridge (
    .clk(clk), .rst_n(rst_n), .start(neg_start),
    .descriptor_count(neg_count),
    .desc_valid(neg_desc_valid), .desc_op(neg_desc_op),
    .desc_ready(neg_desc_ready),
    .array_start_ready(f_fake_ready), .array_done(f_fake_done),
    .array_error(f_fake_error), .array_start(neg_array_start),
    .array_op(neg_array_op), .running_op(neg_running_op),
    .ready(neg_ready), .busy(neg_busy), .done(neg_done),
    .error(neg_error), .terminal_error_cause(neg_cause),
    .pushed_count(neg_pushed), .launched_count(neg_launched),
    .complete_count(neg_completed), .dead_cycle_count(neg_dead),
    .max_handoff(neg_max_handoff), .underrun_cycles(neg_underrun),
    .fifo_level(neg_level));

assign seq_desc_ready = bridge_desc_ready;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        f_state <= F_IDLE;
        f_timer <= 8'd0;
        f_done  <= 1'b0;
        f_error <= 1'b0;
    end else begin
        if (f_accept) begin
            f_state <= F_RUN;
            f_timer <= 8'd0;
            f_done  <= 1'b0;
            f_error <= 1'b0;
        end else if (f_state == F_RUN) begin
            if (f_timer + 8'd1 >= f_run_len) begin
                f_done  <= 1'b1;
                f_error <= f_inject_error;
                if (f_stall_pending && f_stall_len != 8'd0) begin
                    f_state <= F_STALL;
                    f_timer <= 8'd0;
                end else begin
                    f_state <= F_IDLE;
                end
            end else begin
                f_timer <= f_timer + 8'd1;
            end
        end else if (f_state == F_STALL) begin
            if (f_timer + 8'd1 >= f_stall_len) begin
                f_state <= F_IDLE;
                f_timer <= 8'd0;
            end else begin
                f_timer <= f_timer + 8'd1;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// tracking
// ---------------------------------------------------------------------------
integer failures = 0;
integer t;
reg [2:0] expected_order [0:MAXD-1];
reg [2:0] pushed_order [0:MAXD-1];
reg [2:0] completed_order [0:MAXD-1];
reg [31:0] completed_digest [0:MAXD-1];
reg [15:0] completed_issues [0:MAXD-1];
reg [15:0] completed_outputs [0:MAXD-1];
reg [15:0] completed_bubbles [0:MAXD-1];
reg [15:0] completed_bank [0:MAXD-1];
reg [15:0] completed_latency [0:MAXD-1];
reg completed_pass [0:MAXD-1];
reg [15:0] expected_mask;
integer expected_transitions;
integer push_seen = 0;
integer complete_seen = 0;
reg array_done_prev = 1'b0;

function [31:0] frozen_digest;
    input [2:0] op_value;
    begin
        case (op_value)
            OP_KEM_NTT:  frozen_digest = 32'h1e664367;
            OP_DSA_NTT:  frozen_digest = 32'h7fc8e2fc;
            OP_KEM_INTT: frozen_digest = 32'hb88a6c64;
            default:     frozen_digest = 32'hd23ecef9;
        endcase
    end
endfunction

function [15:0] frozen_issues;
    input [2:0] op_value;
    begin
        frozen_issues = (op_value == OP_KEM_INTT) || (op_value == OP_DSA_INTT)
            ? 16'd1280 : 16'd1024;
    end
endfunction

// The sequencer's deterministic order, from its own case table (index mod 17).
// 17 terms make all 16 ordered adjacent pairs appear.
function [2:0] det_op;
    input [15:0] k;
    begin
        case (k % 16'd17)
            16'd0:  det_op = OP_KEM_NTT;
            16'd1:  det_op = OP_KEM_NTT;
            16'd2:  det_op = OP_DSA_NTT;
            16'd3:  det_op = OP_KEM_NTT;
            16'd4:  det_op = OP_KEM_INTT;
            16'd5:  det_op = OP_KEM_NTT;
            16'd6:  det_op = OP_DSA_INTT;
            16'd7:  det_op = OP_DSA_NTT;
            16'd8:  det_op = OP_DSA_NTT;
            16'd9:  det_op = OP_KEM_INTT;
            16'd10: det_op = OP_DSA_NTT;
            16'd11: det_op = OP_DSA_INTT;
            16'd12: det_op = OP_KEM_INTT;
            16'd13: det_op = OP_KEM_INTT;
            16'd14: det_op = OP_DSA_INTT;
            16'd15: det_op = OP_DSA_INTT;
            default: det_op = OP_KEM_NTT;
        endcase
    end
endfunction

function [31:0] lfsr_step;
    input [31:0] value;
    begin
        lfsr_step = {value[30:0], value[31] ^ value[21] ^ value[1] ^ value[0]};
    end
endfunction

task automatic build_expected;
    input integer total;
    input randomize;
    input [31:0] seed;
    reg [31:0] state;
    begin
        state = randomize ? ((seed == 32'd0) ? 32'h1aceb00c : seed) : 32'd0;
        expected_mask = 16'd0;
        for (t = 0; t < total; t = t + 1) begin
            expected_order[t] = randomize ? {1'b0, state[1:0]} : det_op(t[15:0]);
            if (randomize) begin
                state = lfsr_step(state);
            end
            if (t != 0) begin
                expected_mask[{expected_order[t-1][1:0], expected_order[t][1:0]}] = 1'b1;
            end
        end
        expected_transitions = total - 1;
    end
endtask

task automatic clear_tracking;
    begin
        push_seen = 0;
        complete_seen = 0;
        array_done_prev = 1'b0;
        for (t = 0; t < MAXD; t = t + 1) begin
            pushed_order[t] = 3'd7;
            completed_order[t] = 3'd7;
            completed_digest[t] = 32'd0;
            completed_issues[t] = 16'd0;
            completed_outputs[t] = 16'd0;
            completed_bubbles[t] = 16'd0;
            completed_bank[t] = 16'd0;
            completed_latency[t] = 16'd0;
            completed_pass[t] = 1'b0;
        end
    end
endtask

// Snoops both ends of the bridge.  Sampling on the posedge reads the values the
// bridge and the array acted on at this edge, which is what the array's counters
// and digest hold once its last edge has passed.
always @(posedge clk) begin
    if (rst_n) begin
        if (seq_desc_valid && bridge_desc_ready && (push_seen < MAXD)) begin
            pushed_order[push_seen] = seq_desc_op;
            push_seen = push_seen + 1;
        end
        if (array_done && !array_done_prev) begin
            if (complete_seen < MAXD) begin
                completed_order[complete_seen] = bridge_running_op;
                completed_digest[complete_seen] = array_digest;
                completed_issues[complete_seen] = array_issue_count;
                completed_outputs[complete_seen] = array_output_count;
                completed_bubbles[complete_seen] = array_bubble_count;
                completed_bank[complete_seen] = array_bank_check_count;
                completed_latency[complete_seen] = array_first_latency;
                completed_pass[complete_seen] = array_pass;
            end
            complete_seen = complete_seen + 1;
        end
        array_done_prev = array_done;
    end
end

task automatic expect_eq;
    input [255:0] what;
    input integer got;
    input integer want;
    begin
        if (got !== want) begin
            $display("FAIL %0s got=%0d want=%0d", what, got, want);
            failures = failures + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// positive run: a real burst through sequencer -> bridge -> array
// ---------------------------------------------------------------------------
task automatic run_burst;
    input integer total;
    input randomize;
    input [31:0] seed;
    input integer tag;
    integer bad_order;
    integer seen_ops;
    reg [15:0] seen_mask;
    begin
        build_expected(total, randomize, seed);
        clear_tracking();
        @(negedge clk);
        rst_n = 1'b0;
        seq_start = 1'b0;
        bridge_start = 1'b0;
        neg_start = 1'b0;
        neg_desc_valid = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        seq_count = total[15:0];
        bridge_count = total[15:0];
        seq_randomized = randomize;
        seq_seed = seed;
        seq_start = 1'b1;
        bridge_start = 1'b1;
        @(negedge clk);
        seq_start = 1'b0;
        bridge_start = 1'b0;

        wait (bridge_done);
        #1;

        expect_eq("sequencer error", seq_error, 0);
        expect_eq("sequencer issued", seq_issued, total);
        expect_eq("sequencer accepted", seq_accepted, total);
        expect_eq("sequencer invalid bubbles", seq_bubbles, 0);
        expect_eq("sequencer transitions", seq_transitions, expected_transitions);
        expect_eq("sequencer transition mask", seq_mask, expected_mask);
        expect_eq("sequencer done level", seq_done, 0);

        expect_eq("bridge error", bridge_error, 0);
        expect_eq("bridge pushed", bridge_pushed, total);
        expect_eq("bridge launched", bridge_launched, total);
        expect_eq("bridge completed", bridge_completed, total);
        expect_eq("bridge fifo drained", bridge_level, 0);
        expect_eq("bridge underrun cycles", bridge_underrun, 0);
        // One edge is the whole claim: the array raises done and start_ready in
        // the same edge, so the accept landing on the next edge wastes nothing.
        expect_eq("bridge max handoff edges", bridge_max_handoff, 1);
        expect_eq("bridge dead cycles", bridge_dead, 0);

        expect_eq("array completions", complete_seen, total);
        seen_mask = 16'd0;
        bad_order = 0;
        seen_ops = 0;
        for (t = 0; t < total; t = t + 1) begin
            if (pushed_order[t] !== expected_order[t]) begin
                bad_order = bad_order + 1;
                if (bad_order < 4) begin
                    $display("FAIL tag=%0d push slot=%0d op=%0d expected=%0d: the bridge reordered the descriptor stream", tag, t, pushed_order[t], expected_order[t]);
                end
            end
            if (completed_order[t] !== expected_order[t]) begin
                bad_order = bad_order + 1;
                if (bad_order < 4) begin
                    $display("FAIL tag=%0d complete slot=%0d op=%0d expected=%0d: the array ran an op other than the descriptor named", tag, t, completed_order[t], expected_order[t]);
                end
            end
            if (completed_digest[t] !== frozen_digest(expected_order[t])) begin
                $display("FAIL tag=%0d slot=%0d op=%0d digest=%08x want=%08x", tag, t, completed_order[t], completed_digest[t], frozen_digest(expected_order[t]));
                failures = failures + 1;
            end
            expect_eq("array issues", completed_issues[t], frozen_issues(completed_order[t]));
            expect_eq("array outputs", completed_outputs[t], frozen_issues(completed_order[t]));
            expect_eq("array bubbles", completed_bubbles[t], 0);
            expect_eq("array bank checks", completed_bank[t], 1024);
            expect_eq("array first latency", completed_latency[t], 23);
            expect_eq("array pass", completed_pass[t], 1);
            case (completed_order[t])
                OP_KEM_NTT:  seen_ops = seen_ops | 1;
                OP_DSA_NTT:  seen_ops = seen_ops | 2;
                OP_KEM_INTT: seen_ops = seen_ops | 4;
                default:     seen_ops = seen_ops | 8;
            endcase
            if (t != 0) begin
                seen_mask[{completed_order[t-1][1:0], completed_order[t][1:0]}] = 1'b1;
            end
        end
        if (bad_order != 0) begin
            failures = failures + 1;
        end
        expect_eq("completed pair coverage", seen_mask, expected_mask);
        expect_eq("all four ops executed", seen_ops, 15);
        expect_eq("array error", array_error, 0);
        expect_eq("array busy", array_busy, 0);

        $display("burst tag=%0d descriptors=%0d mask=%04x max_handoff=%0d dead=%0d underrun=%0d seq_bubbles=%0d", tag, total, seq_mask, bridge_max_handoff, bridge_dead, bridge_underrun, seq_bubbles);
    end
endtask

// ---------------------------------------------------------------------------
// negative runs: each one shows a positive check is load-bearing
// ---------------------------------------------------------------------------
task automatic neg_reset;
    begin
        @(negedge clk);
        rst_n = 1'b0;
        neg_start = 1'b0;
        neg_desc_valid = 1'b0;
        seq_start = 1'b0;
        bridge_start = 1'b0;
        f_stall_pending = 1'b0;
        f_stall_len = 8'd0;
        f_inject_error = 1'b0;
        f_run_len = 8'd4;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask

// Arm a burst of `target` descriptors and push `actual` of them, one per cycle,
// the way the sequencer would.  Does not wait for completion.
task automatic neg_arm_and_push;
    input integer target;
    input integer actual;
    integer k;
    begin
        neg_count = target[15:0];
        neg_start = 1'b1;
        @(negedge clk);
        neg_start = 1'b0;
        for (k = 0; k < actual; k = k + 1) begin
            neg_desc_valid = 1'b1;
            neg_desc_op = k % 4;
            @(negedge clk);
        end
        neg_desc_valid = 1'b0;
    end
endtask

task automatic negative_checks;
    begin
        // N1: a zero-length burst must finish with an explicit error, not hang.
        neg_reset();
        neg_count = 16'd0;
        neg_start = 1'b1;
        @(negedge clk);
        neg_start = 1'b0;
        wait (neg_done);
        #1;
        expect_eq("N1 zero-count error", neg_error, 1);
        expect_eq("N1 zero-count cause", neg_cause, ERR_ZERO_COUNT);

        // N2: an unsupported opcode stops the burst instead of reaching the array.
        neg_reset();
        neg_desc_valid = 1'b1;
        neg_desc_op = 3'd4;
        neg_count = 16'd4;
        neg_start = 1'b1;
        @(negedge clk);
        neg_start = 1'b0;
        @(negedge clk);
        neg_desc_valid = 1'b0;
        wait (neg_done);
        #1;
        expect_eq("N2 unsupported cause", neg_cause, ERR_UNSUPPORTED);
        expect_eq("N2 unsupported launched", neg_launched, 0);

        // N3: more descriptors than the burst declared is an error, not a silent
        // extra op.
        neg_reset();
        neg_arm_and_push(2, 3);
        wait (neg_done);
        #1;
        expect_eq("N3 over-push cause", neg_cause, ERR_OVER_PUSH);
        expect_eq("N3 over-push pushed", neg_pushed, 3);

        // N4: a consumer that comes back late must show up as dead cycles.  This
        // is what makes max_handoff==1 in the positive runs meaningful.
        neg_reset();
        f_stall_pending = 1'b1;
        f_stall_len = 8'd3;
        neg_arm_and_push(2, 2);
        wait (neg_done);
        #1;
        expect_eq("N4 stalled handoff", neg_max_handoff, 4);
        expect_eq("N4 stalled dead cycles", neg_dead, 3);
        expect_eq("N4 stalled error", neg_error, 1);
        expect_eq("N4 stalled cause", neg_cause, ERR_HANDOFF);
        expect_eq("N4 stalled ops still ran", neg_completed, 2);

        // N5: the identical burst against a consumer that never stalls is the
        // control for N4 -- the same counters return the zero-switch figures.
        neg_reset();
        neg_arm_and_push(4, 4);
        wait (neg_done);
        #1;
        expect_eq("N5 error-free bridge", neg_error, 0);
        expect_eq("N5 handoff edges", neg_max_handoff, 1);
        expect_eq("N5 dead cycles", neg_dead, 0);
        expect_eq("N5 underrun cycles", neg_underrun, 0);
        expect_eq("N5 launched", neg_launched, 4);
        expect_eq("N5 completed", neg_completed, 4);

        // N6: an array that finishes with error set must not be handed the next
        // descriptor.
        neg_reset();
        f_inject_error = 1'b1;
        neg_arm_and_push(4, 4);
        wait (neg_done);
        #1;
        expect_eq("N6 array-error cause", neg_cause, ERR_ARRAY);
        expect_eq("N6 array-error error", neg_error, 1);
        expect_eq("N6 ops after array error", neg_launched, 1);

        // N7: an underrun is counted when the producer cannot keep up.
        neg_reset();
        f_run_len = 8'd2;
        neg_count = 16'd4;
        neg_start = 1'b1;
        @(negedge clk);
        neg_start = 1'b0;
        for (t = 0; t < 4; t = t + 1) begin
            neg_desc_valid = 1'b1;
            neg_desc_op = t % 4;
            @(negedge clk);
            neg_desc_valid = 1'b0;
            @(negedge clk);
            @(negedge clk);
            @(negedge clk);
        end
        wait (neg_done);
        #1;
        if (neg_underrun == 16'd0) begin
            $display("FAIL N7 underrun counter stayed 0 although the producer was starved");
            failures = failures + 1;
        end
        expect_eq("N7 ops still completed", neg_completed, 4);
        $display("negative N1..N7 done underrun=%0d", neg_underrun);
    end
endtask

initial begin
    run_burst(17, 0, 32'd0, 1);           // deterministic: all 16 ordered op pairs
    run_burst(32, 1, 32'h00001234, 2);    // seeded randomised mixed stream
    negative_checks();

    if (failures == 0) begin
        $display("tb_ntt256_systolic_zero_switch_chain PASS pairs=16 streams=2 max_handoff=1_edge dead_cycles=0 underrun=0 negative=7");
        $finish;
    end
    $display("tb_ntt256_systolic_zero_switch_chain FAIL failures=%0d", failures);
    $fatal(1);
end

initial begin
    repeat (1200000) @(posedge clk);
    $display("tb_ntt256_systolic_zero_switch_chain FAIL timeout");
    $fatal(1);
end

endmodule
