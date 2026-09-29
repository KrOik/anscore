`timescale 1ns / 1ps

module tb_mldsa44_flow_scheduler;

localparam [1:0] FLOW_KEYGEN = 2'd0;
localparam [1:0] FLOW_SIGN   = 2'd1;
localparam [1:0] FLOW_VERIFY = 2'd2;

localparam [2:0] OP_KEM_NTT    = 3'd0;
localparam [2:0] OP_DSA_NTT    = 3'd1;
localparam [2:0] OP_KEM_INTT   = 3'd2;
localparam [2:0] OP_DSA_INTT   = 3'd3;
localparam [2:0] OP_DSA_FLOW   = 3'd5;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg [1:0] flow_op = FLOW_KEYGEN;
wire ready;
wire busy;
wire done;
wire error;
wire [1:0] active_flow;
wire [7:0] phase;
wire [3:0] k_index;
wire [3:0] l_index;
wire engine_start;
wire [2:0] engine_op;
wire engine_mode_dsa;
wire engine_inverse;
wire [22:0] engine_q;
reg engine_ready = 1'b1;
reg engine_done = 1'b0;
wire shake_request;
wire expand_request;
wire sample_request;
wire mac_request;
wire decompose_request;
wire hint_request;
wire pack_request;
wire shake_done = shake_request;
wire expand_done = expand_request;
wire sample_done = sample_request;
wire mac_done = mac_request;
wire decompose_done = decompose_request;
wire hint_done = hint_request;
wire pack_done = pack_request;
wire [15:0] ntt_issue_count;
wire [15:0] intt_issue_count;
wire [15:0] mac_issue_count;
wire [15:0] stub_request_count;
wire [31:0] schedule_digest;
wire [15:0] terminal_error_cause;

integer failures = 0;
integer wait_cycles;
integer engine_delay = 0;
integer engine_start_count = 0;
integer kem_path_count = 0;
integer legacy_alias_count = 0;
integer bad_engine_op_count = 0;
integer dsa_ntt_count = 0;
integer dsa_intt_count = 0;

always #5 clk = ~clk;

mldsa44_flow_scheduler dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .flow_op(flow_op),
    .ready(ready),
    .busy(busy),
    .done(done),
    .error(error),
    .active_flow(active_flow),
    .phase(phase),
    .k_index(k_index),
    .l_index(l_index),
    .engine_start(engine_start),
    .engine_op(engine_op),
    .engine_mode_dsa(engine_mode_dsa),
    .engine_inverse(engine_inverse),
    .engine_q(engine_q),
    .engine_ready(engine_ready),
    .engine_done(engine_done),
    .shake_request(shake_request),
    .shake_done(shake_done),
    .expand_request(expand_request),
    .expand_done(expand_done),
    .sample_request(sample_request),
    .sample_done(sample_done),
    .mac_request(mac_request),
    .mac_done(mac_done),
    .decompose_request(decompose_request),
    .decompose_done(decompose_done),
    .hint_request(hint_request),
    .hint_done(hint_done),
    .pack_request(pack_request),
    .pack_done(pack_done),
    .ntt_issue_count(ntt_issue_count),
    .intt_issue_count(intt_issue_count),
    .mac_issue_count(mac_issue_count),
    .stub_request_count(stub_request_count),
    .schedule_digest(schedule_digest),
    .terminal_error_cause(terminal_error_cause)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        engine_delay <= 0;
        engine_ready <= 1'b1;
        engine_done <= 1'b0;
    end else begin
        engine_done <= 1'b0;

        if (engine_start) begin
            engine_delay <= 3;
            engine_ready <= 1'b0;
        end else if (engine_delay > 0) begin
            engine_delay <= engine_delay - 1;
            if (engine_delay == 1) begin
                engine_done <= 1'b1;
                engine_ready <= 1'b1;
            end
        end
    end
end

always @(posedge clk) begin
    if (rst_n && engine_start) begin
        engine_start_count = engine_start_count + 1;
        if ((engine_op == OP_KEM_NTT) || (engine_op == OP_KEM_INTT) ||
            !engine_mode_dsa || (engine_q != 23'd8380417)) begin
            kem_path_count = kem_path_count + 1;
        end
        if (engine_op == OP_DSA_FLOW) begin
            legacy_alias_count = legacy_alias_count + 1;
        end
        if ((engine_op != OP_DSA_NTT) && (engine_op != OP_DSA_INTT)) begin
            bad_engine_op_count = bad_engine_op_count + 1;
        end
        if (engine_op == OP_DSA_NTT) begin
            dsa_ntt_count = dsa_ntt_count + 1;
        end
        if (engine_op == OP_DSA_INTT) begin
            dsa_intt_count = dsa_intt_count + 1;
        end
    end
end

task automatic reset_all;
    begin
        rst_n = 1'b0;
        start = 1'b0;
        flow_op = FLOW_KEYGEN;
        engine_start_count = 0;
        kem_path_count = 0;
        legacy_alias_count = 0;
        bad_engine_op_count = 0;
        dsa_ntt_count = 0;
        dsa_intt_count = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    end
endtask

task automatic launch_invalid_flow_sample_done;
    output done_seen;
    begin
        wait (ready);
        @(negedge clk);
        flow_op = 2'd3;
        start = 1'b1;
        @(posedge clk);
        #1;
        done_seen = done;
        @(negedge clk);
        start = 1'b0;
    end
endtask

reg invalid_done_seen;

task automatic run_flow;
    input [80*8-1:0] name;
    input [1:0] op_i;
    input [15:0] expected_ntt;
    input [15:0] expected_intt;
    input [15:0] expected_mac;
    input [15:0] expected_stub;
    begin
        wait (ready);
        @(negedge clk);
        flow_op = op_i;
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        wait_cycles = 0;
        while (!done && wait_cycles < 1000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (!done) begin
            $display("FAIL %0s timeout", name);
            failures = failures + 1;
        end
        if (error || terminal_error_cause != 16'd0) begin
            $display("FAIL %0s error=%0d cause=%04x", name, error,
                     terminal_error_cause);
            failures = failures + 1;
        end
        if (active_flow != op_i) begin
            $display("FAIL %0s active_flow=%0d expected=%0d", name,
                     active_flow, op_i);
            failures = failures + 1;
        end
        if (ntt_issue_count != expected_ntt ||
            intt_issue_count != expected_intt ||
            mac_issue_count != expected_mac ||
            stub_request_count != expected_stub) begin
            $display("FAIL %0s counts ntt=%0d/%0d intt=%0d/%0d mac=%0d/%0d stub=%0d/%0d",
                     name, ntt_issue_count, expected_ntt,
                     intt_issue_count, expected_intt,
                     mac_issue_count, expected_mac,
                     stub_request_count, expected_stub);
            failures = failures + 1;
        end
        if (kem_path_count != 0 || legacy_alias_count != 0 ||
            bad_engine_op_count != 0) begin
            $display("FAIL %0s path violations kem=%0d alias=%0d badop=%0d",
                     name, kem_path_count, legacy_alias_count,
                     bad_engine_op_count);
            failures = failures + 1;
        end
        if (dsa_ntt_count != expected_ntt || dsa_intt_count != expected_intt) begin
            $display("FAIL %0s dsa op counts ntt=%0d/%0d intt=%0d/%0d",
                     name, dsa_ntt_count, expected_ntt,
                     dsa_intt_count, expected_intt);
            failures = failures + 1;
        end

        @(posedge clk);
    end
endtask

initial begin
    reset_all();
    run_flow("ML-DSA-44 keygen shell", FLOW_KEYGEN,
             16'd8, 16'd0, 16'd0, 16'd11);

    reset_all();
    run_flow("ML-DSA-44 sign shell", FLOW_SIGN,
             16'd4, 16'd4, 16'd4, 16'd14);

    reset_all();
    run_flow("ML-DSA-44 verify shell", FLOW_VERIFY,
             16'd4, 16'd4, 16'd4, 16'd10);

    reset_all();
    launch_invalid_flow_sample_done(invalid_done_seen);
    if (!invalid_done_seen || !error || terminal_error_cause != 16'h0001 ||
        engine_start_count != 0) begin
        $display("FAIL invalid flow done=%0d error=%0d cause=%04x engine_starts=%0d",
                 invalid_done_seen, error, terminal_error_cause,
                 engine_start_count);
        failures = failures + 1;
    end

    if (failures == 0) begin
        $display("tb_mldsa44_flow_scheduler PASS dsa_only_no_legacy_flow_alias");
        $finish;
    end else begin
        $display("tb_mldsa44_flow_scheduler FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (5000) @(posedge clk);
    $display("tb_mldsa44_flow_scheduler FAIL timeout");
    $fatal(1);
end

endmodule
