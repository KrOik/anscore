`timescale 1ns / 1ps

module tb_mlkem768_flow_scheduler;

localparam [1:0] CMD_KEYGEN = 2'd0;
localparam [1:0] CMD_ENCAPS = 2'd1;
localparam [1:0] CMD_DECAPS = 2'd2;
localparam [1:0] CMD_INVALID = 2'd3;

localparam [2:0] OP_KEM_NTT    = 3'd0;
localparam [2:0] OP_DSA_NTT    = 3'd1;
localparam [2:0] OP_KEM_INTT   = 3'd2;
localparam [2:0] OP_DSA_INTT   = 3'd3;
localparam [2:0] OP_KEM_FLOW   = 3'd4;
localparam [2:0] OP_DSA_FLOW   = 3'd5;
localparam [2:0] OP_HYBRID_RUN = 3'd6;

localparam [4:0] PH_KEYGEN_S_NTT  = 5'd5;
localparam [4:0] PH_KEYGEN_E_NTT  = 5'd6;
localparam [4:0] PH_ENCAPS_R_NTT  = 5'd7;
localparam [4:0] PH_ENCAPS_U_INTT = 5'd8;
localparam [4:0] PH_DECAPS_U_NTT  = 5'd10;
localparam [4:0] PH_DECAPS_M_INTT = 5'd11;

localparam [3:0] CAUSE_NONE           = 4'd0;
localparam [3:0] CAUSE_INVALID_CMD    = 4'd1;
localparam [3:0] CAUSE_SUBBLOCK_ERROR = 4'd2;
localparam [3:0] CAUSE_NTT_ERROR      = 4'd3;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg [1:0] cmd = CMD_KEYGEN;
wire ready;
wire busy;
wire done;
wire error;
wire [1:0] active_cmd;
wire [4:0] active_phase;
wire [1:0] vector_index;
wire [3:0] terminal_cause;
wire [31:0] digest;
wire [31:0] cycle_count;
wire [15:0] ntt_issue_count;
wire [15:0] ntt_done_count;
wire [15:0] subblock_issue_count;
wire ntt_start;
wire [2:0] ntt_op;
wire ntt_mode_dsa;
reg ntt_ready = 1'b1;
reg ntt_done = 1'b0;
reg ntt_error = 1'b0;
reg [31:0] ntt_digest = 32'd0;
reg [31:0] ntt_cycle_count = 32'd0;
wire seed_start;
reg seed_ready = 1'b1;
reg seed_done = 1'b0;
reg seed_error = 1'b0;
reg [31:0] seed_digest = 32'h53454544;
wire xof_start;
reg xof_ready = 1'b1;
reg xof_done = 1'b0;
reg xof_error = 1'b0;
reg [31:0] xof_digest = 32'h584f4620;
wire matrix_start;
reg matrix_ready = 1'b1;
reg matrix_done = 1'b0;
reg matrix_error = 1'b0;
reg [31:0] matrix_digest = 32'h4d415452;
wire cbd_start;
reg cbd_ready = 1'b1;
reg cbd_done = 1'b0;
reg cbd_error = 1'b0;
reg [31:0] cbd_digest = 32'h43424420;
wire compress_start;
reg compress_ready = 1'b1;
reg compress_done = 1'b0;
reg compress_error = 1'b0;
reg [31:0] compress_digest = 32'h434f4d50;
wire verify_start;
reg verify_ready = 1'b1;
reg verify_done = 1'b0;
reg verify_error = 1'b0;
reg [31:0] verify_digest = 32'h56455249;

integer ntt_latency = 0;
integer seed_latency = 0;
integer xof_latency = 0;
integer matrix_latency = 0;
integer cbd_latency = 0;
integer compress_latency = 0;
integer verify_latency = 0;
integer observed_ntt_count = 0;
integer observed_subblock_count = 0;
integer last_phase [0:15];
integer last_vector [0:15];
integer last_op [0:15];
integer forced_cbd_error = 0;
integer forced_ntt_error = 0;

always #5 clk = ~clk;

mlkem768_flow_scheduler dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .cmd(cmd),
    .ready(ready),
    .busy(busy),
    .done(done),
    .error(error),
    .active_cmd(active_cmd),
    .active_phase(active_phase),
    .vector_index(vector_index),
    .terminal_cause(terminal_cause),
    .digest(digest),
    .cycle_count(cycle_count),
    .ntt_issue_count(ntt_issue_count),
    .ntt_done_count(ntt_done_count),
    .subblock_issue_count(subblock_issue_count),
    .ntt_start(ntt_start),
    .ntt_op(ntt_op),
    .ntt_mode_dsa(ntt_mode_dsa),
    .ntt_ready(ntt_ready),
    .ntt_done(ntt_done),
    .ntt_error(ntt_error),
    .ntt_digest(ntt_digest),
    .ntt_cycle_count(ntt_cycle_count),
    .seed_start(seed_start),
    .seed_ready(seed_ready),
    .seed_done(seed_done),
    .seed_error(seed_error),
    .seed_digest(seed_digest),
    .xof_start(xof_start),
    .xof_ready(xof_ready),
    .xof_done(xof_done),
    .xof_error(xof_error),
    .xof_digest(xof_digest),
    .matrix_start(matrix_start),
    .matrix_ready(matrix_ready),
    .matrix_done(matrix_done),
    .matrix_error(matrix_error),
    .matrix_digest(matrix_digest),
    .cbd_start(cbd_start),
    .cbd_ready(cbd_ready),
    .cbd_done(cbd_done),
    .cbd_error(cbd_error),
    .cbd_digest(cbd_digest),
    .compress_start(compress_start),
    .compress_ready(compress_ready),
    .compress_done(compress_done),
    .compress_error(compress_error),
    .compress_digest(compress_digest),
    .verify_start(verify_start),
    .verify_ready(verify_ready),
    .verify_done(verify_done),
    .verify_error(verify_error),
    .verify_digest(verify_digest)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ntt_latency <= 0;
        ntt_done <= 1'b0;
        ntt_error <= 1'b0;
        ntt_digest <= 32'd0;
        ntt_cycle_count <= 32'd0;
        observed_ntt_count <= 0;
    end else begin
        ntt_done <= 1'b0;
        ntt_error <= 1'b0;
        if (ntt_start) begin
            if (ntt_mode_dsa) begin
                $display("tb_mlkem768_flow_scheduler FAIL accidental_dsa_mode");
                $fatal(1);
            end
            if ((ntt_op == OP_DSA_NTT) || (ntt_op == OP_DSA_INTT) ||
                (ntt_op == OP_KEM_FLOW) || (ntt_op == OP_DSA_FLOW) ||
                (ntt_op == OP_HYBRID_RUN)) begin
                $display("tb_mlkem768_flow_scheduler FAIL invalid_engine_op=%0d", ntt_op);
                $fatal(1);
            end
            last_phase[observed_ntt_count] <= active_phase;
            last_vector[observed_ntt_count] <= vector_index;
            last_op[observed_ntt_count] <= ntt_op;
            observed_ntt_count <= observed_ntt_count + 1;
            ntt_latency <= 2;
            ntt_digest <= 32'h60000000 ^ {24'd0, active_phase, vector_index};
            ntt_cycle_count <= 32'd17 + {30'd0, vector_index};
        end else if (ntt_latency > 0) begin
            ntt_latency <= ntt_latency - 1;
            if (ntt_latency == 1) begin
                ntt_done <= 1'b1;
                ntt_error <= forced_ntt_error != 0;
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        seed_latency <= 0;
        xof_latency <= 0;
        matrix_latency <= 0;
        cbd_latency <= 0;
        compress_latency <= 0;
        verify_latency <= 0;
        seed_done <= 1'b0;
        xof_done <= 1'b0;
        matrix_done <= 1'b0;
        cbd_done <= 1'b0;
        compress_done <= 1'b0;
        verify_done <= 1'b0;
        cbd_error <= 1'b0;
        observed_subblock_count <= 0;
    end else begin
        seed_done <= 1'b0;
        xof_done <= 1'b0;
        matrix_done <= 1'b0;
        cbd_done <= 1'b0;
        compress_done <= 1'b0;
        verify_done <= 1'b0;
        cbd_error <= 1'b0;

        if (seed_start) begin
            seed_latency <= 1;
            observed_subblock_count <= observed_subblock_count + 1;
        end else if (seed_latency > 0) begin
            seed_latency <= seed_latency - 1;
            if (seed_latency == 1) seed_done <= 1'b1;
        end

        if (xof_start) begin
            xof_latency <= 1;
            observed_subblock_count <= observed_subblock_count + 1;
        end else if (xof_latency > 0) begin
            xof_latency <= xof_latency - 1;
            if (xof_latency == 1) xof_done <= 1'b1;
        end

        if (matrix_start) begin
            matrix_latency <= 1;
            observed_subblock_count <= observed_subblock_count + 1;
        end else if (matrix_latency > 0) begin
            matrix_latency <= matrix_latency - 1;
            if (matrix_latency == 1) matrix_done <= 1'b1;
        end

        if (cbd_start) begin
            cbd_latency <= 1;
            observed_subblock_count <= observed_subblock_count + 1;
        end else if (cbd_latency > 0) begin
            cbd_latency <= cbd_latency - 1;
            if (cbd_latency == 1) begin
                cbd_done <= 1'b1;
                cbd_error <= forced_cbd_error != 0;
            end
        end

        if (compress_start) begin
            compress_latency <= 1;
            observed_subblock_count <= observed_subblock_count + 1;
        end else if (compress_latency > 0) begin
            compress_latency <= compress_latency - 1;
            if (compress_latency == 1) compress_done <= 1'b1;
        end

        if (verify_start) begin
            verify_latency <= 1;
            observed_subblock_count <= observed_subblock_count + 1;
        end else if (verify_latency > 0) begin
            verify_latency <= verify_latency - 1;
            if (verify_latency == 1) verify_done <= 1'b1;
        end
    end
end

task automatic run_cmd;
    input [1:0] run_command;
    input expect_error;
    input [3:0] expected_cause;
    input integer expected_ntt;
    input integer expected_subblocks;
    input integer initial_ntt_ready_low_cycles;
    integer wait_cycles;
    integer ready_wait_cycles;
    begin
        observed_ntt_count = 0;
        observed_subblock_count = 0;
        ready_wait_cycles = initial_ntt_ready_low_cycles;
        wait (ready);
        @(negedge clk);
        if (ready_wait_cycles > 0) begin
            ntt_ready = 1'b0;
        end else begin
            ntt_ready = 1'b1;
        end
        cmd = run_command;
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        wait_cycles = 0;
        while (!done && wait_cycles < 400) begin
            @(posedge clk);
            if (ready_wait_cycles > 0) begin
                ready_wait_cycles = ready_wait_cycles - 1;
                if (ready_wait_cycles == 0) begin
                    ntt_ready = 1'b1;
                end
            end
            wait_cycles = wait_cycles + 1;
        end
        ntt_ready = 1'b1;
        if (!done) begin
            $display("tb_mlkem768_flow_scheduler FAIL timeout cmd=%0d", run_command);
            $fatal(1);
        end
        if (active_cmd != run_command) begin
            $display("tb_mlkem768_flow_scheduler FAIL active_cmd=%0d expected=%0d",
                     active_cmd, run_command);
            $fatal(1);
        end
        if (error != expect_error) begin
            $display("tb_mlkem768_flow_scheduler FAIL error=%0d expected=%0d cmd=%0d",
                     error, expect_error, run_command);
            $fatal(1);
        end
        if (terminal_cause != expected_cause) begin
            $display("tb_mlkem768_flow_scheduler FAIL cause=%0d expected=%0d cmd=%0d",
                     terminal_cause, expected_cause, run_command);
            $fatal(1);
        end
        if (observed_ntt_count != expected_ntt) begin
            $display("tb_mlkem768_flow_scheduler FAIL observed_ntt=%0d expected=%0d cmd=%0d",
                     observed_ntt_count, expected_ntt, run_command);
            $fatal(1);
        end
        if (observed_subblock_count != expected_subblocks) begin
            $display("tb_mlkem768_flow_scheduler FAIL observed_subblocks=%0d expected=%0d cmd=%0d",
                     observed_subblock_count, expected_subblocks, run_command);
            $fatal(1);
        end
        if (ntt_issue_count != expected_ntt || ntt_done_count != expected_ntt) begin
            $display("tb_mlkem768_flow_scheduler FAIL ntt_counters issue=%0d done=%0d expected=%0d",
                     ntt_issue_count, ntt_done_count, expected_ntt);
            $fatal(1);
        end
        if (subblock_issue_count != expected_subblocks) begin
            $display("tb_mlkem768_flow_scheduler FAIL subblock_counter=%0d expected=%0d",
                     subblock_issue_count, expected_subblocks);
            $fatal(1);
        end
        @(posedge clk);
    end
endtask

task automatic check_entry;
    input integer idx;
    input integer expected_phase;
    input integer expected_vector;
    input integer expected_op;
    begin
        if ((last_phase[idx] != expected_phase) ||
            (last_vector[idx] != expected_vector) ||
            (last_op[idx] != expected_op)) begin
            $display("tb_mlkem768_flow_scheduler FAIL seq idx=%0d phase=%0d/%0d vector=%0d/%0d op=%0d/%0d",
                     idx, last_phase[idx], expected_phase, last_vector[idx], expected_vector,
                     last_op[idx], expected_op);
            $fatal(1);
        end
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    run_cmd(CMD_KEYGEN, 1'b0, CAUSE_NONE, 6, 4, 20);
    check_entry(0, PH_KEYGEN_S_NTT, 0, OP_KEM_NTT);
    check_entry(1, PH_KEYGEN_S_NTT, 1, OP_KEM_NTT);
    check_entry(2, PH_KEYGEN_S_NTT, 2, OP_KEM_NTT);
    check_entry(3, PH_KEYGEN_E_NTT, 0, OP_KEM_NTT);
    check_entry(4, PH_KEYGEN_E_NTT, 1, OP_KEM_NTT);
    check_entry(5, PH_KEYGEN_E_NTT, 2, OP_KEM_NTT);

    run_cmd(CMD_ENCAPS, 1'b0, CAUSE_NONE, 6, 5, 0);
    check_entry(0, PH_ENCAPS_R_NTT, 0, OP_KEM_NTT);
    check_entry(1, PH_ENCAPS_R_NTT, 1, OP_KEM_NTT);
    check_entry(2, PH_ENCAPS_R_NTT, 2, OP_KEM_NTT);
    check_entry(3, PH_ENCAPS_U_INTT, 0, OP_KEM_INTT);
    check_entry(4, PH_ENCAPS_U_INTT, 1, OP_KEM_INTT);
    check_entry(5, PH_ENCAPS_U_INTT, 2, OP_KEM_INTT);

    run_cmd(CMD_DECAPS, 1'b0, CAUSE_NONE, 4, 4, 0);
    check_entry(0, PH_DECAPS_U_NTT, 0, OP_KEM_NTT);
    check_entry(1, PH_DECAPS_U_NTT, 1, OP_KEM_NTT);
    check_entry(2, PH_DECAPS_U_NTT, 2, OP_KEM_NTT);
    check_entry(3, PH_DECAPS_M_INTT, 0, OP_KEM_INTT);

    run_cmd(CMD_INVALID, 1'b1, CAUSE_INVALID_CMD, 0, 0, 0);

    forced_cbd_error = 1;
    run_cmd(CMD_KEYGEN, 1'b1, CAUSE_SUBBLOCK_ERROR, 0, 4, 0);
    forced_cbd_error = 0;

    forced_ntt_error = 1;
    run_cmd(CMD_DECAPS, 1'b1, CAUSE_NTT_ERROR, 1, 2, 0);
    check_entry(0, PH_DECAPS_U_NTT, 0, OP_KEM_NTT);
    forced_ntt_error = 0;

    $display("tb_mlkem768_flow_scheduler PASS keygen_encaps_decaps_k3_kem_only_shell_and_errors");
    $finish;
end

initial begin
    repeat (3000) @(posedge clk);
    $display("tb_mlkem768_flow_scheduler FAIL global timeout");
    $fatal(1);
end

endmodule
