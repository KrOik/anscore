`timescale 1ns / 1ps

module tb_ntt256_systolic_arith_pipe;

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;
localparam integer SEQ_LEN = 17;
localparam integer EXPECTED_LATENCY = 23;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg in_valid = 1'b0;
reg [2:0] in_op = OP_KEM_NTT;
reg [4:0] in_index = 5'd0;
wire in_ready;
wire out_valid;
wire [2:0] out_op;
wire [4:0] out_index;
wire [22:0] out_y0;
wire [22:0] out_y1;
wire [15:0] accepted_count;

integer cycle;
integer out_count;
integer bubble_count;
integer first_out_cycle;
integer failures;
reg [15:0] pair_mask;
reg [2:0] previous_out_op;

always #5 clk = ~clk;

ntt256_systolic_arith_pipe dut (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_op(in_op),
    .in_index(in_index),
    .in_a(input_a(in_op, in_index)),
    .in_b(input_b(in_op, in_index)),
    .in_twiddle(input_twiddle(in_op, in_index)),
    .in_ready(in_ready),
    .out_valid(out_valid),
    .out_op(out_op),
    .out_index(out_index),
    .out_y0(out_y0),
    .out_y1(out_y1),
    .accepted_count(accepted_count)
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

function [22:0] input_a;
    input [2:0] op;
    input [4:0] index;
    reg [31:0] raw;
    begin
        if (is_dsa_op(op)) begin
            raw = 32'd12345 + ({27'd0, index} * 32'd65537);
            input_a = raw[22:0];
        end else begin
            input_a = 23'd5 + ({18'd0, index} * 23'd17);
        end
    end
endfunction

function [22:0] input_b;
    input [2:0] op;
    input [4:0] index;
    reg [31:0] raw;
    begin
        if (is_dsa_op(op)) begin
            raw = 32'd54321 + ({27'd0, index} * 32'd4093);
            input_b = raw[22:0];
        end else begin
            input_b = 23'd7 + ({18'd0, index} * 23'd31);
        end
    end
endfunction

function [22:0] input_twiddle;
    input [2:0] op;
    input [4:0] index;
    begin
        if (is_dsa_op(op)) begin
            if (is_inverse_op(op)) begin
                case (index[2:0])
                    3'd0: input_twiddle = 23'd5307408;
                    3'd1: input_twiddle = 23'd3572223;
                    3'd2: input_twiddle = 23'd4614810;
                    3'd3: input_twiddle = 23'd4618904;
                    3'd4: input_twiddle = 23'd3201494;
                    3'd5: input_twiddle = 23'd3145678;
                    3'd6: input_twiddle = 23'd2883726;
                    default: input_twiddle = 23'd3201430;
                endcase
            end else begin
                case (index[2:0])
                    3'd0: input_twiddle = 23'd3073009;
                    3'd1: input_twiddle = 23'd4808194;
                    3'd2: input_twiddle = 23'd3765607;
                    3'd3: input_twiddle = 23'd3761513;
                    3'd4: input_twiddle = 23'd5178923;
                    3'd5: input_twiddle = 23'd5234739;
                    3'd6: input_twiddle = 23'd5496691;
                    default: input_twiddle = 23'd5178987;
                endcase
            end
        end else if (is_inverse_op(op)) begin
            case (index[2:0])
                3'd0: input_twiddle = 23'd3312;
                3'd1: input_twiddle = 23'd1600;
                3'd2: input_twiddle = 23'd749;
                3'd3: input_twiddle = 23'd40;
                3'd4: input_twiddle = 23'd687;
                3'd5: input_twiddle = 23'd1432;
                3'd6: input_twiddle = 23'd2699;
                default: input_twiddle = 23'd2481;
            endcase
        end else begin
            case (index[2:0])
                3'd0: input_twiddle = 23'd17;
                3'd1: input_twiddle = 23'd1729;
                3'd2: input_twiddle = 23'd2580;
                3'd3: input_twiddle = 23'd3289;
                3'd4: input_twiddle = 23'd2642;
                3'd5: input_twiddle = 23'd1897;
                3'd6: input_twiddle = 23'd630;
                default: input_twiddle = 23'd848;
            endcase
        end
    end
endfunction

function [22:0] expected_y0;
    input integer index;
    begin
        case (index)
            0: expected_y0 = 23'd124;
            1: expected_y0 = 23'd2473;
            2: expected_y0 = 23'd4548306;
            3: expected_y0 = 23'd2714;
            4: expected_y0 = 23'd204;
            5: expected_y0 = 23'd1136;
            6: expected_y0 = 23'd484446;
            7: expected_y0 = 23'd5498793;
            8: expected_y0 = 23'd7252501;
            9: expected_y0 = 23'd444;
            10: expected_y0 = 23'd5032889;
            11: expected_y0 = 23'd832596;
            12: expected_y0 = 23'd588;
            13: expected_y0 = 23'd636;
            14: expected_y0 = 23'd1041486;
            15: expected_y0 = 23'd1111116;
            default: expected_y0 = 23'd2170;
        endcase
    end
endfunction

function [22:0] expected_y1;
    input integer index;
    begin
        case (index)
            0: expected_y1 = 23'd3215;
            1: expected_y1 = 23'd900;
            2: expected_y1 = 23'd4118949;
            3: expected_y1 = 23'd727;
            4: expected_y1 = 23'd102;
            5: expected_y1 = 23'd2373;
            6: expected_y1 = 23'd2482850;
            7: expected_y1 = 23'd3823832;
            8: expected_y1 = 23'd2201198;
            9: expected_y1 = 23'd1598;
            10: expected_y1 = 23'd4682958;
            11: expected_y1 = 23'd1724955;
            12: expected_y1 = 23'd3054;
            13: expected_y1 = 23'd2832;
            14: expected_y1 = 23'd6512554;
            15: expected_y1 = 23'd7615270;
            default: expected_y1 = 23'd1713;
        endcase
    end
endfunction

initial begin
    failures = 0;
    out_count = 0;
    bubble_count = 0;
    first_out_cycle = -1;
    pair_mask = 16'd0;
    previous_out_op = OP_KEM_NTT;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    for (cycle = 0; cycle < (SEQ_LEN + EXPECTED_LATENCY + 5); cycle = cycle + 1) begin
        @(negedge clk);
        if (cycle < SEQ_LEN) begin
            in_valid = 1'b1;
            in_op = seq_op(cycle);
            in_index = cycle[4:0];
            if (!in_ready) begin
                $display("FAIL in_ready deasserted at issue cycle %0d", cycle);
                failures = failures + 1;
            end
        end else begin
            in_valid = 1'b0;
            in_op = OP_KEM_NTT;
            in_index = 5'd0;
        end

        @(posedge clk);
        #1;

        if (out_valid) begin
            if (first_out_cycle < 0) begin
                first_out_cycle = cycle;
            end
            if (out_op !== seq_op(out_count)) begin
                $display("FAIL out_op[%0d]=%0d expected=%0d",
                         out_count, out_op, seq_op(out_count));
                failures = failures + 1;
            end
            if (out_index !== out_count[4:0]) begin
                $display("FAIL out_index[%0d]=%0d", out_count, out_index);
                failures = failures + 1;
            end
            if ((out_y0 !== expected_y0(out_count)) ||
                (out_y1 !== expected_y1(out_count))) begin
                $display("FAIL out[%0d] y0=%0d expected=%0d y1=%0d expected=%0d",
                         out_count, out_y0, expected_y0(out_count),
                         out_y1, expected_y1(out_count));
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

    if (first_out_cycle != EXPECTED_LATENCY) begin
        $display("FAIL first_out_cycle=%0d expected=%0d",
                 first_out_cycle, EXPECTED_LATENCY);
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

    if (failures == 0) begin
        $display("tb_ntt256_systolic_arith_pipe PASS zero_bubbles latency=%0d ops=%0d ordered_pairs=16 exact_modular_butterflies=17",
                 first_out_cycle, out_count);
        $finish;
    end else begin
        $display("tb_ntt256_systolic_arith_pipe FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (2000) @(posedge clk);
    $display("tb_ntt256_systolic_arith_pipe FAIL timeout");
    $fatal(1);
end

endmodule
