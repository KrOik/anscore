`timescale 1ns / 1ps
// Chained-mode test for ntt256_systolic_state_array.
//
// tb_ntt256_systolic_state_array runs every op with auto_init asserted, so each
// op rewrites all 256 coefficients from its own canned ramp and the array never
// carries data from one op into the next.  That leaves the delivery claim
// untested: that a KEM/DSA or NTT/INTT op change costs no drain, reset or
// reconfiguration cycle -- in the data sense, not only at the handshake.
//
// Here auto_init is low throughout and real state is pushed through the array:
//   * the coefficient vector arrives through the external coeff_load port, so
//     the datapath consumes host-supplied data rather than a self-generated ramp;
//   * a forward op runs, then the matching inverse op is accepted at the very
//     next clock edge after its done, with no reset and no reload, then a second
//     forward op is accepted the same way -- a three-op chain that also hands the
//     coefficient bank over after an odd number of ping-pong toggles;
//   * the inverse op's digest must equal the digest of the vector that was
//     loaded, because INTT(NTT(x)) = x for both moduli.  That fold is recomputed
//     here from the testbench's own load data, so the round-trip verdict does not
//     depend on the array; models/ntt256_systolic_golden.py proves the property
//     independently and supplies the forward digests, which closes the loophole
//     that a compensating pair of stage errors could still round-trip.
//
// Two cycle measurements turn "no reconfiguration cycle" into a number:
//   * handoff: clock edges from the previous op's last edge to this op's accept
//     edge.  The array leaves S_DIGEST_RUN and enters S_IDLE in one edge, so the
//     earliest edge that can honour start is the next one: handoff 1 is zero dead
//     cycles, handoff 2 would mean one wasted cycle.
//   * duration: accept-to-done edges for one op, compared against the same op
//     launched with auto_init=1.  A chained op must cost exactly S_INIT's 256
//     cycles less, i.e. the self-init pass is the only thing removed.
//
// done is a level, not a pulse: S_IDLE only clears it when it accepts a start.
// So the accounting below keys off the first cycle the testbench can observe done
// (the NBA region of the edge that raised it), never off "done is high now".
module tb_ntt256_systolic_chained_roundtrip;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam integer INIT_CYCLES = 256;   // the S_INIT pass chained mode skips

// Forward-op digests of the four loaded vectors, from models/ntt256_systolic_golden.py
localparam [31:0] KEM_V1_FWD = 32'h59139f3c;
localparam [31:0] KEM_V2_FWD = 32'h4e05fca5;
localparam [31:0] DSA_V1_FWD = 32'had4d03c3;
localparam [31:0] DSA_V2_FWD = 32'h36b3babb;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg [2:0] op = OP_KEM_NTT;
reg auto_init = 1'b1;
reg check_expected = 1'b0;
reg coeff_load_valid = 1'b0;
reg [7:0] coeff_load_addr = 8'd0;
reg [22:0] coeff_load_data = 23'd0;

wire coeff_load_ready;
wire start_ready;
wire busy;
wire done;
wire pass;
wire error;
wire out_valid;
wire [2:0] out_op;
wire [4:0] out_index;
wire [22:0] out_y0;
wire [22:0] out_y1;
wire [15:0] issue_count;
wire [15:0] output_count;
wire [15:0] bubble_count;
wire [15:0] bank_check_count;
wire [15:0] first_latency;
wire [31:0] digest;
wire [31:0] signature;

ntt256_systolic_state_array dut (
    .clk(clk), .rst_n(rst_n), .start(start), .op(op),
    .auto_init(auto_init), .check_expected(check_expected),
    .coeff_load_valid(coeff_load_valid), .coeff_load_addr(coeff_load_addr),
    .coeff_load_data(coeff_load_data), .coeff_load_ready(coeff_load_ready),
    .start_ready(start_ready), .busy(busy), .done(done), .pass(pass),
    .error(error), .out_valid(out_valid), .out_op(out_op),
    .out_index(out_index), .out_y0(out_y0), .out_y1(out_y1),
    .issue_count(issue_count), .output_count(output_count),
    .bubble_count(bubble_count), .bank_check_count(bank_check_count),
    .first_latency(first_latency), .digest(digest), .signature(signature));

integer failures = 0;
integer index;
reg [22:0] vector [0:255];
reg [31:0] load_fold;

// ---------------------------------------------------------------------------
// Cycle accounting, read only off the ports.  This block sees the values the DUT
// itself acted on at this edge, so cycle N here names the edge that consumed
// them: an accept is recorded on the edge that grants it.
// ---------------------------------------------------------------------------
integer cycle = 0;
integer last_accept_cycle = -1;
integer last_complete_cycle = -1;
integer accept_pulses = 0;
integer load_beats = 0;
integer load_unready = 0;

integer base_cycles [0:3];       // per-op duration with auto_init=1
integer last_duration [0:3];     // duration of the most recent launch, per op

always #5 clk = ~clk;

always @(posedge clk) begin
    cycle = cycle + 1;
    if (rst_n) begin
        if (start && start_ready) begin
            accept_pulses = accept_pulses + 1;
            last_accept_cycle = cycle;
        end
        if (coeff_load_valid && coeff_load_ready)
            load_beats = load_beats + 1;
        if (coeff_load_valid && !coeff_load_ready)
            load_unready = load_unready + 1;
    end
end

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

// The digest each op produces from its own auto_init ramp.  A chained op that
// ignored coeff_load would fall back to one of these, so they are the values the
// chain must NOT produce.
function [31:0] selfinit_digest;
    input [2:0] op_value;
    begin
        case (op_value)
            OP_KEM_NTT:  selfinit_digest = 32'h1e664367;
            OP_DSA_NTT:  selfinit_digest = 32'h7fc8e2fc;
            OP_KEM_INTT: selfinit_digest = 32'hb88a6c64;
            default:     selfinit_digest = 32'hd23ecef9;
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// Stimulus is driven strictly between edges (the caller is always a few ns past
// an edge, and every assignment here is followed by a delay) so a start pulse
// spans exactly one posedge: no zero-width pulse the DUT could miss, and no
// multi-cycle pulse that would be counted as two requests.
// ---------------------------------------------------------------------------
task automatic set_vector;
    input integer mult;
    input integer add;
    input integer mod;
    begin
        for (index = 0; index < 256; index = index + 1) begin
            vector[index] = ((index * mult) + add) % mod;
        end
    end
endtask

task automatic compute_load_fold;
    begin
        load_fold = 32'h4e545432;
        for (index = 0; index < 256; index = index + 1) begin
            load_fold = rotl5(load_fold) ^ {9'd0, vector[index]}
                        ^ {24'd0, index[7:0]};
        end
    end
endtask

task automatic load_vector;
    begin
        @(negedge clk);
        for (index = 0; index < 256; index = index + 1) begin
            coeff_load_valid = 1'b1;
            coeff_load_addr = index[7:0];
            coeff_load_data = vector[index];
            @(negedge clk);
        end
        coeff_load_valid = 1'b0;
    end
endtask

// Assert start for exactly one cycle, wait for that op's last edge, and check its
// bookkeeping.  The start must be accepted exactly once: a dropped start silently
// re-runs the previous op, a double accept launches an op nobody asked for.
// expect_handoff < 0 skips the handoff check, expect_duration < 0 skips the timing one.
task automatic launch;
    input [2:0] op_value;
    input integer expect_issues;
    input integer expect_handoff;
    input integer expect_duration;
    integer accepts0, loads0, complete, duration, handoff;
    begin
        accepts0 = accept_pulses;
        loads0 = load_beats;
        #1;
        if (!start_ready) begin
            $display("FAIL op=%0d start driven while start_ready=%0d busy=%0d, the array was not free to take it", op_value, start_ready, busy);
            failures = failures + 1;
        end
        op = op_value;
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        if (accept_pulses != accepts0 + 1) begin
            $display("FAIL op=%0d accepted %0d starts, expected exactly 1", op_value, accept_pulses - accepts0);
            failures = failures + 1;
        end
        if (done) begin
            $display("FAIL op=%0d accept left done high, so this start was swallowed by the previous op", op_value);
            failures = failures + 1;
        end
        // Earliest observation of this op's last edge: done is written by NBA at
        // that edge, so the wait releases in the same timestep, before any further
        // edge has been counted.  cycle therefore names the completing edge.
        wait (done);
        complete = cycle;
        #1;
        duration = complete - last_accept_cycle;
        handoff = (last_complete_cycle < 0) ? -1 : last_accept_cycle - last_complete_cycle;
        last_complete_cycle = complete;
        if (accept_pulses == accepts0 + 1) begin
            if (expect_handoff >= 0 && handoff != expect_handoff) begin
                $display("FAIL op=%0d handoff took %0d edges after the previous last edge, expected %0d (1 = the very next edge, no dead cycle)", op_value, handoff, expect_handoff);
                failures = failures + 1;
            end
            if (expect_duration >= 0 && duration != expect_duration) begin
                $display("FAIL op=%0d cost %0d edges accept-to-done, expected %0d", op_value, duration, expect_duration);
                failures = failures + 1;
            end
        end
        if (!pass || error) begin
            $display("FAIL op=%0d pass=%0d error=%0d signature=%08x", op_value, pass, error, signature);
            failures = failures + 1;
        end
        if (bubble_count !== 16'd0) begin
            $display("FAIL op=%0d bubbles=%0d", op_value, bubble_count);
            failures = failures + 1;
        end
        if (issue_count !== expect_issues[15:0] ||
            output_count !== expect_issues[15:0]) begin
            $display("FAIL op=%0d issues=%0d outputs=%0d expected=%0d", op_value, issue_count, output_count, expect_issues);
            failures = failures + 1;
        end
        if (bank_check_count !== 16'd1024) begin
            $display("FAIL op=%0d bank_check_count=%0d", op_value, bank_check_count);
            failures = failures + 1;
        end
        if (first_latency !== 16'd23) begin
            $display("FAIL op=%0d first_latency=%0d", op_value, first_latency);
            failures = failures + 1;
        end
        if (load_beats != loads0) begin
            $display("FAIL op=%0d consumed %0d coefficient writes while running, so the bank was reconfigured underneath it", op_value, load_beats - loads0);
            failures = failures + 1;
        end
        last_duration[op_value] = duration;
        $display("op=%0d accept=%0d last=%0d handoff=%0d duration=%0d digest=%08x", op_value, last_accept_cycle, complete, handoff, duration, digest);
    end
endtask

// One loaded vector pushed through forward -> inverse -> forward with nothing in
// between but the handshake.
task automatic chain_roundtrip;
    input [2:0] fwd_op;
    input [2:0] inv_op;
    input [31:0] fwd_digest_expected;
    input integer tag;
    integer loads0;
    begin
        loads0 = load_beats;
        load_vector();
        compute_load_fold();
        if (load_beats != loads0 + 256) begin
            $display("FAIL tag=%0d load wrote %0d coefficients, expected 256", tag, load_beats - loads0);
            failures = failures + 1;
        end

        // First op of the chain: accepted after the load window rather than after a
        // previous done, so only its duration is pinned (baseline minus self-init).
        launch(fwd_op, 1024, -1, base_cycles[fwd_op] - INIT_CYCLES);
        if (digest === selfinit_digest(fwd_op)) begin
            $display("FAIL tag=%0d forward digest=%08x is the self-init ramp value, so coeff_load never reached the datapath", tag, digest);
            failures = failures + 1;
        end
        if (digest !== fwd_digest_expected) begin
            $display("FAIL tag=%0d forward digest=%08x model=%08x: the loaded vector did not drive the datapath", tag, digest, fwd_digest_expected);
            failures = failures + 1;
        end

        // Chained inverse op: no reset, no reload, no dead cycle.
        launch(inv_op, 1280, 1, base_cycles[inv_op] - INIT_CYCLES);
        if (digest !== load_fold) begin
            $display("FAIL tag=%0d round trip digest=%08x want=%08x: INTT(NTT(x)) != x through the chained bank", tag, digest, load_fold);
            failures = failures + 1;
        end

        // Chained third op: the bank ping-pong has toggled an odd number of times,
        // so this forward op reads the other physical buffer, and it reads the
        // coefficients the inverse op wrote -- not the ones the test loaded.
        launch(fwd_op, 1024, 1, base_cycles[fwd_op] - INIT_CYCLES);
        if (digest !== fwd_digest_expected) begin
            $display("FAIL tag=%0d third-op digest=%08x want=%08x: the chain did not hand its bank over intact", tag, digest, fwd_digest_expected);
            failures = failures + 1;
        end
        if (load_beats != loads0 + 256) begin
            $display("FAIL tag=%0d the chain reloaded %0d coefficients, so the ops were not actually chained", tag, load_beats - loads0 - 256);
            failures = failures + 1;
        end
    end
endtask

initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    // Baselines: the same four ops self-initialising, on the frozen digests.  The
    // chained mode has to beat each of these by exactly S_INIT and nothing else.
    launch(OP_KEM_NTT, 1024, -1, -1);
    if (digest !== 32'h1e664367) begin
        $display("FAIL auto_init KEM_NTT digest=%08x", digest);
        failures = failures + 1;
    end
    launch(OP_DSA_NTT, 1024, -1, -1);
    if (digest !== 32'h7fc8e2fc) begin
        $display("FAIL auto_init DSA_NTT digest=%08x", digest);
        failures = failures + 1;
    end
    launch(OP_KEM_INTT, 1280, -1, -1);
    if (digest !== 32'hb88a6c64) begin
        $display("FAIL auto_init KEM_INTT digest=%08x", digest);
        failures = failures + 1;
    end
    launch(OP_DSA_INTT, 1280, -1, -1);
    if (digest !== 32'hd23ecef9) begin
        $display("FAIL auto_init DSA_INTT digest=%08x", digest);
        failures = failures + 1;
    end
    base_cycles[OP_KEM_NTT] = last_duration[OP_KEM_NTT];
    base_cycles[OP_DSA_NTT] = last_duration[OP_DSA_NTT];
    base_cycles[OP_KEM_INTT] = last_duration[OP_KEM_INTT];
    base_cycles[OP_DSA_INTT] = last_duration[OP_DSA_INTT];
    $display("baseline auto_init=1 durations kem_ntt=%0d dsa_ntt=%0d kem_intt=%0d dsa_intt=%0d", base_cycles[0], base_cycles[1], base_cycles[2], base_cycles[3]);

    auto_init = 1'b0;

    set_vector(7919, 104729, 3329);
    chain_roundtrip(OP_KEM_NTT, OP_KEM_INTT, KEM_V1_FWD, 1);
    set_vector(104729, 7919, 3329);
    chain_roundtrip(OP_KEM_NTT, OP_KEM_INTT, KEM_V2_FWD, 2);
    set_vector(7919, 104729, 8380417);
    chain_roundtrip(OP_DSA_NTT, OP_DSA_INTT, DSA_V1_FWD, 3);
    set_vector(104729, 7919, 8380417);
    chain_roundtrip(OP_DSA_NTT, OP_DSA_INTT, DSA_V2_FWD, 4);

    if (load_unready != 0) begin
        $display("FAIL %0d coefficient writes were refused, so the load window and the datapath disagree about who owns the bank", load_unready);
        failures = failures + 1;
    end

    if (failures == 0) begin
        $display("tb_ntt256_systolic_chained_roundtrip PASS chains=4 ops_per_chain=3 saved=%0d cycles/op handoff=1_edge_no_dead_cycle", INIT_CYCLES);
        $finish;
    end
    $display("tb_ntt256_systolic_chained_roundtrip FAIL failures=%0d", failures);
    $fatal(1);
end

initial begin
    repeat (400000) @(posedge clk);
    $display("tb_ntt256_systolic_chained_roundtrip FAIL timeout");
    $fatal(1);
end

endmodule
