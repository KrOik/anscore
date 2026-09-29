`timescale 1ns / 1ps

module tb_ntt256_systolic_state_array;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam [15:0] FORWARD_ISSUES = 16'd1024;
localparam [15:0] INVERSE_ISSUES = 16'd1280;
localparam [15:0] STAGE_BANK_CHECKS = 16'd1024;
localparam [15:0] EXPECTED_LATENCY = 16'd23;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg [2:0] op = OP_KEM_NTT;
reg auto_init = 1'b1;
reg check_expected = 1'b1;
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

integer failures = 0;
integer run_index;
integer gap_cycles;
reg [15:0] transition_mask = 16'd0;
reg [2:0] last_op = OP_KEM_NTT;
reg [31:0] digest_fold = 32'h53544154;

always #5 clk = ~clk;

ntt256_systolic_state_array dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .op(op),
    .auto_init(auto_init),
    .check_expected(check_expected),
    .coeff_load_valid(coeff_load_valid),
    .coeff_load_addr(coeff_load_addr),
    .coeff_load_data(coeff_load_data),
    .coeff_load_ready(coeff_load_ready),
    .start_ready(start_ready),
    .busy(busy),
    .done(done),
    .pass(pass),
    .error(error),
    .out_valid(out_valid),
    .out_op(out_op),
    .out_index(out_index),
    .out_y0(out_y0),
    .out_y1(out_y1),
    .issue_count(issue_count),
    .output_count(output_count),
    .bubble_count(bubble_count),
    .bank_check_count(bank_check_count),
    .first_latency(first_latency),
    .digest(digest),
    .signature(signature)
);

function [2:0] seq_op;
    input integer idx;
    begin
        case (idx)
            0: seq_op = OP_KEM_NTT;
            1: seq_op = OP_DSA_NTT;
            2: seq_op = OP_KEM_INTT;
            default: seq_op = OP_DSA_INTT;
        endcase
    end
endfunction

function is_inverse_op;
    input [2:0] op_value;
    begin
        is_inverse_op = (op_value == OP_KEM_INTT) || (op_value == OP_DSA_INTT);
    end
endfunction

function [31:0] expected_digest;
    input [2:0] op_value;
    begin
        case (op_value)
            OP_KEM_NTT: expected_digest = 32'h1e664367;
            OP_DSA_NTT: expected_digest = 32'h7fc8e2fc;
            OP_KEM_INTT: expected_digest = 32'hb88a6c64;
            default: expected_digest = 32'hd23ecef9;
        endcase
    end
endfunction

function [15:0] expected_issues;
    input [2:0] op_value;
    begin
        expected_issues = is_inverse_op(op_value) ? INVERSE_ISSUES : FORWARD_ISSUES;
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

function [3:0] pair_index;
    input [2:0] from_op;
    input [2:0] to_op;
    begin
        pair_index = {from_op[1:0], to_op[1:0]};
    end
endfunction

task automatic pulse_start;
    input [2:0] op_value;
    begin
        gap_cycles = 0;
        while (!start_ready) begin
            @(posedge clk);
            gap_cycles = gap_cycles + 1;
        end

        @(negedge clk);
        op = op_value;
        start = 1'b1;
        @(posedge clk);
        #1;
        if (!busy && !done) begin
            $display("FAIL start did not enter active state op=%0d", op_value);
            failures = failures + 1;
        end
        @(negedge clk);
        start = 1'b0;
    end
endtask

task automatic check_run;
    input integer idx;
    input [2:0] op_value;
    begin
        pulse_start(op_value);
        wait (done || error);
        #1;

        if (!done || !pass || error) begin
            $display("FAIL op=%0d done=%0d pass=%0d error=%0d signature=%08x",
                     op_value, done, pass, error, signature);
            failures = failures + 1;
        end
        if (digest !== expected_digest(op_value)) begin
            $display("FAIL digest op=%0d got=%08x expected=%08x",
                     op_value, digest, expected_digest(op_value));
            failures = failures + 1;
        end
        if (issue_count !== expected_issues(op_value)) begin
            $display("FAIL issue_count op=%0d got=%0d expected=%0d",
                     op_value, issue_count, expected_issues(op_value));
            failures = failures + 1;
        end
        if (output_count !== expected_issues(op_value)) begin
            $display("FAIL output_count op=%0d got=%0d expected=%0d",
                     op_value, output_count, expected_issues(op_value));
            failures = failures + 1;
        end
        if (bank_check_count !== STAGE_BANK_CHECKS) begin
            $display("FAIL bank_check_count op=%0d got=%0d expected=%0d",
                     op_value, bank_check_count, STAGE_BANK_CHECKS);
            failures = failures + 1;
        end
        if (bubble_count !== 16'd0) begin
            $display("FAIL bubble_count op=%0d got=%0d", op_value, bubble_count);
            failures = failures + 1;
        end
        if (first_latency !== EXPECTED_LATENCY) begin
            $display("FAIL first_latency op=%0d got=%0d expected=%0d",
                     op_value, first_latency, EXPECTED_LATENCY);
            failures = failures + 1;
        end

        if (idx > 0) begin
            transition_mask = transition_mask |
                (16'd1 << pair_index(last_op, op_value));
            if (gap_cycles != 0) begin
                $display("FAIL inter-op gap op=%0d gap_cycles=%0d", op_value, gap_cycles);
                failures = failures + 1;
            end
        end
        last_op = op_value;
        digest_fold = rotl5(digest_fold) ^ digest ^ {29'd0, op_value};
        $display("state_array op=%0d digest=%08x issues=%0d outputs=%0d bubbles=%0d latency=%0d signature=%08x",
                 op_value, digest, issue_count, output_count, bubble_count,
                 first_latency, signature);
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    for (run_index = 0; run_index < 4; run_index = run_index + 1) begin
        check_run(run_index, seq_op(run_index));
    end

    if (transition_mask !== 16'h0842) begin
        $display("FAIL transition_mask=%04x expected=0842", transition_mask);
        failures = failures + 1;
    end

    if (failures == 0) begin
        $display("tb_ntt256_systolic_state_array PASS transitions=%04x digest_fold=%08x",
                 transition_mask, digest_fold);
        $finish;
    end

    $display("tb_ntt256_systolic_state_array FAIL failures=%0d transitions=%04x digest_fold=%08x",
             failures, transition_mask, digest_fold);
    $fatal(1);
end

initial begin
    repeat (100000) @(posedge clk);
    $display("tb_ntt256_systolic_state_array FAIL timeout");
    $fatal(1);
end

endmodule
