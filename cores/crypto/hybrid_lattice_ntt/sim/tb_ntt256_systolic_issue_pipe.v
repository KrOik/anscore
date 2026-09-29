`timescale 1ns / 1ps

module tb_ntt256_systolic_issue_pipe;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;
localparam integer SEQ_LEN = 17;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg in_valid = 1'b0;
reg [2:0] in_op = OP_KEM_NTT;
wire in_ready;
wire [7:0] stage_valid;
wire [7:0] stage_mode_dsa;
wire [7:0] stage_inverse;
wire [183:0] stage_q_flat;
wire [183:0] stage_root_flat;
wire [183:0] stage_n_inv_flat;
wire out_valid;
wire [2:0] out_op;
wire [31:0] out_signature;
wire [15:0] accepted_count;

reg map_inverse = 1'b0;
reg [2:0] map_stage = 3'd0;
reg [6:0] map_index = 7'd0;
wire [7:0] map_addr_a;
wire [7:0] map_addr_b;
wire [1:0] map_bank_a;
wire [1:0] map_bank_b;
wire map_conflict;

reg expected_valid [0:7];
reg [2:0] expected_op [0:7];
reg old_valid7;
reg [2:0] old_op7;
integer cycle;
integer stage_idx;
integer out_count;
integer bubble_count;
integer first_out_cycle;
integer failures;
integer inv_i;
integer stage_i;
integer index_i;
integer expected_gap;
reg [15:0] pair_mask;
reg [2:0] previous_out_op;

always #5 clk = ~clk;

ntt256_systolic_issue_pipe dut (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_op(in_op),
    .in_ready(in_ready),
    .stage_valid(stage_valid),
    .stage_mode_dsa(stage_mode_dsa),
    .stage_inverse(stage_inverse),
    .stage_q_flat(stage_q_flat),
    .stage_root_flat(stage_root_flat),
    .stage_n_inv_flat(stage_n_inv_flat),
    .out_valid(out_valid),
    .out_op(out_op),
    .out_signature(out_signature),
    .accepted_count(accepted_count)
);

ntt256_systolic_bank_mapper mapper (
    .inverse(map_inverse),
    .stage(map_stage),
    .butterfly_index(map_index),
    .addr_a(map_addr_a),
    .addr_b(map_addr_b),
    .bank_a(map_bank_a),
    .bank_b(map_bank_b),
    .conflict(map_conflict)
);

function [2:0] seq_op;
    input integer index;
    begin
        case (index)
            0: seq_op = OP_KEM_NTT;
            1: seq_op = OP_KEM_NTT;
            2: seq_op = OP_DSA_NTT;
            3: seq_op = OP_KEM_NTT;
            4: seq_op = OP_KEM_INTT;
            5: seq_op = OP_KEM_NTT;
            6: seq_op = OP_DSA_INTT;
            7: seq_op = OP_DSA_NTT;
            8: seq_op = OP_DSA_NTT;
            9: seq_op = OP_KEM_INTT;
            10: seq_op = OP_DSA_NTT;
            11: seq_op = OP_DSA_INTT;
            12: seq_op = OP_KEM_INTT;
            13: seq_op = OP_KEM_INTT;
            14: seq_op = OP_DSA_INTT;
            15: seq_op = OP_DSA_INTT;
            default: seq_op = OP_KEM_NTT;
        endcase
    end
endfunction

function expected_dsa;
    input [2:0] op;
    begin
        expected_dsa = (op == OP_DSA_NTT) || (op == OP_DSA_INTT);
    end
endfunction

function expected_inverse;
    input [2:0] op;
    begin
        expected_inverse = (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

function [22:0] expected_q;
    input [2:0] op;
    begin
        expected_q = expected_dsa(op) ? 23'd8380417 : 23'd3329;
    end
endfunction

function [22:0] expected_root;
    input [2:0] op;
    begin
        expected_root = expected_dsa(op) ? 23'd3073009 : 23'd17;
    end
endfunction

function [22:0] expected_n_inv;
    input [2:0] op;
    begin
        expected_n_inv = expected_dsa(op) ? 23'd8347681 : 23'd3316;
    end
endfunction

function [22:0] flat23;
    input [183:0] flat;
    input integer index;
    begin
        flat23 = flat[(index * 23) +: 23];
    end
endfunction

task automatic check_stage_config;
    input integer idx;
    begin
        if (stage_valid[idx] !== expected_valid[idx]) begin
            $display("FAIL stage_valid[%0d]=%0d expected=%0d",
                     idx, stage_valid[idx], expected_valid[idx]);
            failures = failures + 1;
        end
        if (expected_valid[idx]) begin
            if (stage_mode_dsa[idx] !== expected_dsa(expected_op[idx])) begin
                $display("FAIL stage_mode_dsa[%0d]", idx);
                failures = failures + 1;
            end
            if (stage_inverse[idx] !== expected_inverse(expected_op[idx])) begin
                $display("FAIL stage_inverse[%0d]", idx);
                failures = failures + 1;
            end
            if (flat23(stage_q_flat, idx) !== expected_q(expected_op[idx])) begin
                $display("FAIL stage_q[%0d]=%0d expected=%0d",
                         idx, flat23(stage_q_flat, idx), expected_q(expected_op[idx]));
                failures = failures + 1;
            end
            if (flat23(stage_root_flat, idx) !== expected_root(expected_op[idx])) begin
                $display("FAIL stage_root[%0d]=%0d expected=%0d",
                         idx, flat23(stage_root_flat, idx), expected_root(expected_op[idx]));
                failures = failures + 1;
            end
            if (flat23(stage_n_inv_flat, idx) !== expected_n_inv(expected_op[idx])) begin
                $display("FAIL stage_n_inv[%0d]=%0d expected=%0d",
                         idx, flat23(stage_n_inv_flat, idx), expected_n_inv(expected_op[idx]));
                failures = failures + 1;
            end
        end
    end
endtask

initial begin
    failures = 0;
    out_count = 0;
    bubble_count = 0;
    first_out_cycle = -1;
    pair_mask = 16'd0;
    previous_out_op = OP_KEM_NTT;
    for (stage_idx = 0; stage_idx < 8; stage_idx = stage_idx + 1) begin
        expected_valid[stage_idx] = 1'b0;
        expected_op[stage_idx] = OP_KEM_NTT;
    end

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    for (cycle = 0; cycle < (SEQ_LEN + 10); cycle = cycle + 1) begin
        @(negedge clk);
        if (cycle < SEQ_LEN) begin
            in_valid = 1'b1;
            in_op = seq_op(cycle);
            if (!in_ready) begin
                $display("FAIL in_ready deasserted at issue cycle %0d", cycle);
                failures = failures + 1;
            end
        end else begin
            in_valid = 1'b0;
            in_op = OP_KEM_NTT;
        end

        old_valid7 = expected_valid[7];
        old_op7 = expected_op[7];
        @(posedge clk);
        #1;

        for (stage_idx = 7; stage_idx > 0; stage_idx = stage_idx - 1) begin
            expected_valid[stage_idx] = expected_valid[stage_idx - 1];
            expected_op[stage_idx] = expected_op[stage_idx - 1];
        end
        expected_valid[0] = in_valid;
        expected_op[0] = in_op;

        for (stage_idx = 0; stage_idx < 8; stage_idx = stage_idx + 1) begin
            check_stage_config(stage_idx);
        end

        if (out_valid !== old_valid7) begin
            $display("FAIL out_valid cycle=%0d got=%0d expected=%0d",
                     cycle, out_valid, old_valid7);
            failures = failures + 1;
        end
        if (out_valid) begin
            if (first_out_cycle < 0) begin
                first_out_cycle = cycle;
            end
            if (out_op !== seq_op(out_count)) begin
                $display("FAIL out_op[%0d]=%0d expected=%0d",
                         out_count, out_op, seq_op(out_count));
                failures = failures + 1;
            end
            if (out_count > 0) begin
                pair_mask[{previous_out_op[1:0], out_op[1:0]}] = 1'b1;
            end
            previous_out_op = out_op;
            out_count = out_count + 1;
        end else if ((first_out_cycle >= 0) && (out_count < SEQ_LEN)) begin
            bubble_count = bubble_count + 1;
        end
    end

    if (first_out_cycle != 8) begin
        $display("FAIL first_out_cycle=%0d expected=8", first_out_cycle);
        failures = failures + 1;
    end
    if (out_count != SEQ_LEN) begin
        $display("FAIL out_count=%0d expected=%0d", out_count, SEQ_LEN);
        failures = failures + 1;
    end
    if (bubble_count != 0) begin
        $display("FAIL bubble_count=%0d expected=0", bubble_count);
        failures = failures + 1;
    end
    if (accepted_count != SEQ_LEN) begin
        $display("FAIL accepted_count=%0d expected=%0d", accepted_count, SEQ_LEN);
        failures = failures + 1;
    end
    if (pair_mask != 16'hffff) begin
        $display("FAIL pair_mask=%04x expected=ffff", pair_mask);
        failures = failures + 1;
    end

    for (inv_i = 0; inv_i < 2; inv_i = inv_i + 1) begin
        for (stage_i = 0; stage_i < 8; stage_i = stage_i + 1) begin
            for (index_i = 0; index_i < 128; index_i = index_i + 1) begin
                map_inverse = inv_i[0];
                map_stage = stage_i[2:0];
                map_index = index_i[6:0];
                #1;
                expected_gap = inv_i ? (1 << (7 - stage_i)) : (1 << stage_i);
                if (map_conflict || (map_bank_a == map_bank_b)) begin
                    $display("FAIL bank conflict inv=%0d stage=%0d index=%0d banks=%0d/%0d",
                             inv_i, stage_i, index_i, map_bank_a, map_bank_b);
                    failures = failures + 1;
                end
                if ((map_addr_b - map_addr_a) != expected_gap) begin
                    $display("FAIL gap inv=%0d stage=%0d index=%0d addr=%0d/%0d expected_gap=%0d",
                             inv_i, stage_i, index_i, map_addr_a, map_addr_b, expected_gap);
                    failures = failures + 1;
                end
            end
        end
    end

    if (failures == 0) begin
        $display("tb_ntt256_systolic_issue_pipe PASS zero_bubbles latency=%0d ops=%0d ordered_pairs=16 bank_checks=%0d",
                 first_out_cycle, out_count, 2 * 8 * 128);
        $finish;
    end else begin
        $display("tb_ntt256_systolic_issue_pipe FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (2000) @(posedge clk);
    $display("tb_ntt256_systolic_issue_pipe FAIL timeout");
    $fatal(1);
end

endmodule
