`timescale 1ns / 1ps

module tb_ntt256_systolic_state_equiv;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;
localparam integer EXPECTED_LATENCY = 23;
localparam integer STAGE_SLOTS = 128;
localparam integer SCALE_SLOTS = 256;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg in_valid = 1'b0;
reg [2:0] in_op = OP_KEM_NTT;
reg [4:0] in_index = 5'd0;
reg [22:0] in_a = 23'd0;
reg [22:0] in_b = 23'd0;
reg [22:0] in_twiddle = 23'd1;

wire in_ready;
wire out_valid;
wire [2:0] out_op;
wire [4:0] out_index;
wire [22:0] out_y0;
wire [22:0] out_y1;
wire [15:0] accepted_count;

reg map_inverse = 1'b0;
reg [2:0] map_stage = 3'd0;
reg [6:0] map_bfly = 7'd0;
wire [7:0] map_addr_a;
wire [7:0] map_addr_b;
wire [1:0] map_bank_a;
wire [1:0] map_bank_b;
wire map_conflict;

reg [22:0] coeff [0:255];
reg [7:0] meta_addr_a [0:255];
reg [7:0] meta_addr_b [0:255];
reg [22:0] meta_a [0:255];
reg [22:0] meta_b [0:255];
reg [22:0] meta_twiddle [0:255];
reg [2:0] meta_op [0:255];
reg [4:0] meta_index [0:255];
reg meta_scale [0:255];

integer failures = 0;
integer total_issue_slots = 0;
integer total_output_slots = 0;
integer total_bubbles = 0;
integer total_bank_checks = 0;
integer min_first_latency = 9999;
integer max_first_latency = -1;
integer current_issue_count;
integer current_output_count;
integer current_first_latency;
integer current_cycle;
integer transform_slots;
integer state_i;
integer digest_i;
reg [31:0] digest_value;

always #5 clk = ~clk;

ntt256_systolic_arith_pipe arith_pipe (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_op(in_op),
    .in_index(in_index),
    .in_a(in_a),
    .in_b(in_b),
    .in_twiddle(in_twiddle),
    .in_ready(in_ready),
    .out_valid(out_valid),
    .out_op(out_op),
    .out_index(out_index),
    .out_y0(out_y0),
    .out_y1(out_y1),
    .accepted_count(accepted_count)
);

ntt256_systolic_bank_mapper mapper (
    .inverse(map_inverse),
    .stage(map_stage),
    .butterfly_index(map_bfly),
    .addr_a(map_addr_a),
    .addr_b(map_addr_b),
    .bank_a(map_bank_a),
    .bank_b(map_bank_b),
    .conflict(map_conflict)
);

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

function [22:0] n_inv_value;
    input [2:0] op;
    begin
        n_inv_value = is_dsa_op(op) ? 23'd8347681 : 23'd3316;
    end
endfunction

function [22:0] reduce_init;
    input [31:0] raw_in;
    input [22:0] q;
    reg [31:0] raw;
    begin
        raw = raw_in;
        if (raw >= {9'd0, q}) begin
            raw = raw - {9'd0, q};
        end
        reduce_init = raw[22:0];
    end
endfunction

function [22:0] init_value;
    input [2:0] op;
    input [7:0] index;
    reg [31:0] raw;
    begin
        if (is_dsa_op(op)) begin
            raw = ({24'd0, index} << 16) + {24'd0, index} + 32'd12345;
        end else begin
            raw = ({24'd0, index} << 4) + {24'd0, index} + 32'd5;
        end
        init_value = reduce_init(raw, q_value(op));
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

task automatic sample_output;
    input integer slot_total;
    begin
        if (out_valid) begin
            if (current_first_latency < 0) begin
                current_first_latency = current_cycle;
                if (current_first_latency < min_first_latency) begin
                    min_first_latency = current_first_latency;
                end
                if (current_first_latency > max_first_latency) begin
                    max_first_latency = current_first_latency;
                end
                if (current_first_latency != EXPECTED_LATENCY) begin
                    $display("FAIL latency=%0d expected=%0d", current_first_latency, EXPECTED_LATENCY);
                    failures = failures + 1;
                end
            end

            if (current_output_count >= slot_total) begin
                $display("FAIL extra output at slot %0d", current_output_count);
                failures = failures + 1;
            end else begin
                if (out_op !== meta_op[current_output_count]) begin
                    $display("FAIL out_op slot=%0d got=%0d expected=%0d",
                             current_output_count, out_op, meta_op[current_output_count]);
                    failures = failures + 1;
                end
                if (out_index !== meta_index[current_output_count]) begin
                    $display("FAIL out_index slot=%0d got=%0d expected=%0d",
                             current_output_count, out_index, meta_index[current_output_count]);
                    failures = failures + 1;
                end
                if ((out_y0 !== expected_y0(meta_op[current_output_count],
                                            meta_a[current_output_count],
                                            meta_b[current_output_count],
                                            meta_twiddle[current_output_count])) ||
                    (out_y1 !== expected_y1(meta_op[current_output_count],
                                            meta_a[current_output_count],
                                            meta_b[current_output_count],
                                            meta_twiddle[current_output_count]))) begin
                    $display("FAIL arithmetic slot=%0d y0=%0d expected=%0d y1=%0d expected=%0d",
                             current_output_count, out_y0,
                             expected_y0(meta_op[current_output_count],
                                         meta_a[current_output_count],
                                         meta_b[current_output_count],
                                         meta_twiddle[current_output_count]),
                             out_y1,
                             expected_y1(meta_op[current_output_count],
                                         meta_a[current_output_count],
                                         meta_b[current_output_count],
                                         meta_twiddle[current_output_count]));
                    failures = failures + 1;
                end

                coeff[meta_addr_a[current_output_count]] = out_y0;
                if (!meta_scale[current_output_count]) begin
                    coeff[meta_addr_b[current_output_count]] = out_y1;
                end
            end

            current_output_count = current_output_count + 1;
            total_output_slots = total_output_slots + 1;
        end else if ((current_first_latency >= 0) && (current_output_count < slot_total)) begin
            total_bubbles = total_bubbles + 1;
            failures = failures + 1;
            $display("FAIL output bubble after stream start output_count=%0d slot_total=%0d",
                     current_output_count, slot_total);
        end
    end
endtask

task automatic run_stage;
    input [2:0] op;
    input [2:0] stage;
    integer slot;
    begin
        current_issue_count = 0;
        current_output_count = 0;
        current_first_latency = -1;
        current_cycle = 0;

        for (slot = 0; slot < STAGE_SLOTS; slot = slot + 1) begin
            @(negedge clk);
            map_inverse = is_inverse_op(op);
            map_stage = stage;
            map_bfly = slot[6:0];
            #1;
            in_valid = 1'b1;
            in_op = op;
            in_index = slot[4:0];
            in_a = coeff[map_addr_a];
            in_b = coeff[map_addr_b];
            in_twiddle = twiddle_for_slot(op, stage, slot[6:0]);

            meta_addr_a[current_issue_count] = map_addr_a;
            meta_addr_b[current_issue_count] = map_addr_b;
            meta_a[current_issue_count] = in_a;
            meta_b[current_issue_count] = in_b;
            meta_twiddle[current_issue_count] = in_twiddle;
            meta_op[current_issue_count] = op;
            meta_index[current_issue_count] = slot[4:0];
            meta_scale[current_issue_count] = 1'b0;

            if (!in_ready) begin
                $display("FAIL in_ready low op=%0d stage=%0d slot=%0d", op, stage, slot);
                failures = failures + 1;
            end
            if (map_conflict || (map_bank_a == map_bank_b) || (map_addr_b <= map_addr_a)) begin
                $display("FAIL bank conflict op=%0d stage=%0d slot=%0d a=%0d b=%0d bank_a=%0d bank_b=%0d",
                         op, stage, slot, map_addr_a, map_addr_b, map_bank_a, map_bank_b);
                failures = failures + 1;
            end

            current_issue_count = current_issue_count + 1;
            total_issue_slots = total_issue_slots + 1;
            total_bank_checks = total_bank_checks + 1;

            @(posedge clk);
            #1;
            sample_output(STAGE_SLOTS);
            current_cycle = current_cycle + 1;
        end

        @(negedge clk);
        in_valid = 1'b0;
        in_op = OP_KEM_NTT;
        in_index = 5'd0;
        in_a = 23'd0;
        in_b = 23'd0;
        in_twiddle = 23'd1;

        while (current_output_count < STAGE_SLOTS) begin
            @(posedge clk);
            #1;
            sample_output(STAGE_SLOTS);
            current_cycle = current_cycle + 1;
        end
    end
endtask

task automatic run_scale;
    input [2:0] op;
    integer slot;
    reg [2:0] scale_op;
    begin
        current_issue_count = 0;
        current_output_count = 0;
        current_first_latency = -1;
        current_cycle = 0;
        scale_op = is_dsa_op(op) ? OP_DSA_NTT : OP_KEM_NTT;

        for (slot = 0; slot < SCALE_SLOTS; slot = slot + 1) begin
            @(negedge clk);
            in_valid = 1'b1;
            in_op = scale_op;
            in_index = slot[4:0];
            in_a = 23'd0;
            in_b = coeff[slot[7:0]];
            in_twiddle = n_inv_value(op);

            meta_addr_a[current_issue_count] = slot[7:0];
            meta_addr_b[current_issue_count] = slot[7:0];
            meta_a[current_issue_count] = in_a;
            meta_b[current_issue_count] = in_b;
            meta_twiddle[current_issue_count] = in_twiddle;
            meta_op[current_issue_count] = scale_op;
            meta_index[current_issue_count] = slot[4:0];
            meta_scale[current_issue_count] = 1'b1;

            if (!in_ready) begin
                $display("FAIL in_ready low scale op=%0d slot=%0d", op, slot);
                failures = failures + 1;
            end

            current_issue_count = current_issue_count + 1;
            total_issue_slots = total_issue_slots + 1;

            @(posedge clk);
            #1;
            sample_output(SCALE_SLOTS);
            current_cycle = current_cycle + 1;
        end

        @(negedge clk);
        in_valid = 1'b0;
        in_op = OP_KEM_NTT;
        in_index = 5'd0;
        in_a = 23'd0;
        in_b = 23'd0;
        in_twiddle = 23'd1;

        while (current_output_count < SCALE_SLOTS) begin
            @(posedge clk);
            #1;
            sample_output(SCALE_SLOTS);
            current_cycle = current_cycle + 1;
        end
    end
endtask

task automatic init_coefficients;
    input [2:0] op;
    integer idx;
    begin
        for (idx = 0; idx < 256; idx = idx + 1) begin
            coeff[idx] = init_value(op, idx[7:0]);
        end
    end
endtask

task automatic compute_digest;
    output [31:0] digest_out;
    begin
        digest_out = 32'h4e545432;
        for (digest_i = 0; digest_i < 256; digest_i = digest_i + 1) begin
            digest_out = rotl5(digest_out) ^ {9'd0, coeff[digest_i]} ^ {24'd0, digest_i[7:0]};
        end
    end
endtask

task automatic run_transform;
    input [2:0] op;
    input [31:0] expected_digest;
    integer stage;
    begin
        init_coefficients(op);
        transform_slots = transform_slots + 1;

        for (stage = 0; stage < 8; stage = stage + 1) begin
            run_stage(op, stage[2:0]);
        end

        if (is_inverse_op(op)) begin
            run_scale(op);
        end

        compute_digest(digest_value);
        if (digest_value !== expected_digest) begin
            $display("FAIL digest op=%0d got=%08x expected=%08x", op, digest_value, expected_digest);
            failures = failures + 1;
        end else begin
            $display("state_equiv op=%0d digest=%08x", op, digest_value);
        end
    end
endtask

initial begin
    transform_slots = 0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    run_transform(OP_KEM_NTT, 32'h1e664367);
    run_transform(OP_DSA_NTT, 32'h7fc8e2fc);
    run_transform(OP_KEM_INTT, 32'hb88a6c64);
    run_transform(OP_DSA_INTT, 32'hd23ecef9);

    if (accepted_count != total_issue_slots[15:0]) begin
        $display("FAIL accepted_count=%0d expected=%0d", accepted_count, total_issue_slots);
        failures = failures + 1;
    end

    if (failures == 0) begin
        $display("tb_ntt256_systolic_state_equiv PASS transforms=%0d issue_slots=%0d outputs=%0d bubbles=%0d bank_checks=%0d latency_min=%0d latency_max=%0d accepted=%0d",
                 transform_slots, total_issue_slots, total_output_slots, total_bubbles,
                 total_bank_checks, min_first_latency, max_first_latency, accepted_count);
        $finish;
    end else begin
        $display("tb_ntt256_systolic_state_equiv FAIL failures=%0d issue_slots=%0d outputs=%0d bubbles=%0d bank_checks=%0d accepted=%0d",
                 failures, total_issue_slots, total_output_slots, total_bubbles,
                 total_bank_checks, accepted_count);
        $fatal(1);
    end
end

initial begin
    repeat (20000) @(posedge clk);
    $display("tb_ntt256_systolic_state_equiv FAIL timeout");
    $fatal(1);
end

endmodule
