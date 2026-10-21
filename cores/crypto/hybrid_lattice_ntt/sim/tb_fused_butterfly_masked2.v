`timescale 1ns / 1ps

module tb_fused_butterfly_masked2;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg mode_dsa = 1'b0;
reg inverse_mode = 1'b0;
reg [22:0] a_share0 = 23'd0;
reg [22:0] a_share1 = 23'd0;
reg [22:0] a_share2 = 23'd0;
reg [22:0] b_share0 = 23'd0;
reg [22:0] b_share1 = 23'd0;
reg [22:0] b_share2 = 23'd0;
reg [22:0] twiddle_share0 = 23'd0;
reg [22:0] twiddle_share1 = 23'd0;
reg [22:0] twiddle_share2 = 23'd0;
reg random_valid = 1'b0;
wire random_ready;
reg [22:0] random_y0_share1 = 23'd0;
reg [22:0] random_y0_share2 = 23'd0;
reg [22:0] random_y1_share1 = 23'd0;
reg [22:0] random_y1_share2 = 23'd0;
wire [22:0] y0_share0;
wire [22:0] y0_share1;
wire [22:0] y0_share2;
wire [22:0] y1_share0;
wire [22:0] y1_share1;
wire [22:0] y1_share2;
wire busy;
wire done;
wire error;
wire random_missing_error;
wire [15:0] random_accept_count;

integer failures = 0;

always #5 clk = ~clk;

fused_butterfly_masked2 dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .mode_dsa(mode_dsa),
    .inverse_mode(inverse_mode),
    .a_share0(a_share0),
    .a_share1(a_share1),
    .a_share2(a_share2),
    .b_share0(b_share0),
    .b_share1(b_share1),
    .b_share2(b_share2),
    .twiddle_share0(twiddle_share0),
    .twiddle_share1(twiddle_share1),
    .twiddle_share2(twiddle_share2),
    .random_valid(random_valid),
    .random_ready(random_ready),
    .random_y0_share1(random_y0_share1),
    .random_y0_share2(random_y0_share2),
    .random_y1_share1(random_y1_share1),
    .random_y1_share2(random_y1_share2),
    .y0_share0(y0_share0),
    .y0_share1(y0_share1),
    .y0_share2(y0_share2),
    .y1_share0(y1_share0),
    .y1_share1(y1_share1),
    .y1_share2(y1_share2),
    .busy(busy),
    .done(done),
    .error(error),
    .random_missing_error(random_missing_error),
    .random_accept_count(random_accept_count)
);

function [22:0] q_value;
    input mode;
    begin
        q_value = mode ? 23'd8380417 : 23'd3329;
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

function [22:0] share0_for;
    input [22:0] value;
    input [22:0] s1;
    input [22:0] s2;
    input [22:0] q;
    begin
        share0_for = mod_sub_ref(mod_sub_ref(value, s1, q), s2, q);
    end
endfunction

function [22:0] recombine3;
    input [22:0] s0;
    input [22:0] s1;
    input [22:0] s2;
    input [22:0] q;
    begin
        recombine3 = mod_add_ref(mod_add_ref(s0, s1, q), s2, q);
    end
endfunction

function [22:0] expected_y0;
    input inverse;
    input [22:0] a;
    input [22:0] b;
    input [22:0] twiddle;
    input [22:0] q;
    reg [22:0] product;
    begin
        if (inverse) begin
            expected_y0 = mod_add_ref(a, b, q);
        end else begin
            product = modmul_ref(b, twiddle, q);
            expected_y0 = mod_add_ref(a, product, q);
        end
    end
endfunction

function [22:0] expected_y1;
    input inverse;
    input [22:0] a;
    input [22:0] b;
    input [22:0] twiddle;
    input [22:0] q;
    reg [22:0] product;
    begin
        if (inverse) begin
            expected_y1 = modmul_ref(mod_sub_ref(a, b, q), twiddle, q);
        end else begin
            product = modmul_ref(b, twiddle, q);
            expected_y1 = mod_sub_ref(a, product, q);
        end
    end
endfunction

task automatic run_case;
    input [80*8-1:0] name;
    input mode_i;
    input inverse_i;
    input [22:0] a_i;
    input [22:0] b_i;
    input [22:0] twiddle_i;
    input [22:0] a_r1_i;
    input [22:0] a_r2_i;
    input [22:0] b_r1_i;
    input [22:0] b_r2_i;
    input [22:0] t_r1_i;
    input [22:0] t_r2_i;
    input [22:0] y0_r1_i;
    input [22:0] y0_r2_i;
    input [22:0] y1_r1_i;
    input [22:0] y1_r2_i;
    reg [22:0] q;
    reg [22:0] y0_expected;
    reg [22:0] y1_expected;
    reg [22:0] y0_recombined;
    reg [22:0] y1_recombined;
    integer cycles;
    begin
        q = q_value(mode_i);
        y0_expected = expected_y0(inverse_i, a_i, b_i, twiddle_i, q);
        y1_expected = expected_y1(inverse_i, a_i, b_i, twiddle_i, q);

        @(posedge clk);
        #1;
        mode_dsa = mode_i;
        inverse_mode = inverse_i;
        a_share1 = a_r1_i;
        a_share2 = a_r2_i;
        a_share0 = share0_for(a_i, a_r1_i, a_r2_i, q);
        b_share1 = b_r1_i;
        b_share2 = b_r2_i;
        b_share0 = share0_for(b_i, b_r1_i, b_r2_i, q);
        twiddle_share1 = t_r1_i;
        twiddle_share2 = t_r2_i;
        twiddle_share0 = share0_for(twiddle_i, t_r1_i, t_r2_i, q);
        random_y0_share1 = y0_r1_i;
        random_y0_share2 = y0_r2_i;
        random_y1_share1 = y1_r1_i;
        random_y1_share2 = y1_r2_i;
        random_valid = 1'b1;
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        random_valid = 1'b0;

        cycles = 0;
        while (!done && cycles < 120) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        y0_recombined = recombine3(y0_share0, y0_share1, y0_share2, q);
        y1_recombined = recombine3(y1_share0, y1_share1, y1_share2, q);

        if (!done) begin
            $display("FAIL %0s timeout", name);
            failures = failures + 1;
        end else if (error || random_missing_error) begin
            $display("FAIL %0s unexpected error=%0d random_missing=%0d",
                     name, error, random_missing_error);
            failures = failures + 1;
        end else if ((y0_recombined != y0_expected) ||
                     (y1_recombined != y1_expected)) begin
            $display("FAIL %0s y0=%0d expected=%0d y1=%0d expected=%0d",
                     name, y0_recombined, y0_expected,
                     y1_recombined, y1_expected);
            failures = failures + 1;
        end else begin
            $display("PASS %0s cycles=%0d y0=%0d y1=%0d",
                     name, cycles, y0_recombined, y1_recombined);
        end
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    run_case("KEM forward recombination", 1'b0, 1'b0,
             23'd1234, 23'd2020, 23'd17,
             23'd11, 23'd29, 23'd7, 23'd31, 23'd3, 23'd5,
             23'd41, 23'd43, 23'd47, 23'd53);
    run_case("KEM inverse recombination", 1'b0, 1'b1,
             23'd2284, 23'd184, 23'd3316,
             23'd61, 23'd67, 23'd71, 23'd73, 23'd79, 23'd83,
             23'd89, 23'd97, 23'd101, 23'd103);
    run_case("DSA forward recombination", 1'b1, 1'b0,
             23'd1234567, 23'd7654321, 23'd1753,
             23'd1009, 23'd2003, 23'd3001, 23'd4001, 23'd5003, 23'd6007,
             23'd7001, 23'd8009, 23'd9001, 23'd10007);
    run_case("DSA inverse recombination", 1'b1, 1'b1,
             23'd2211663, 23'd257471, 23'd8347681,
             23'd11003, 23'd12007, 23'd13001, 23'd14009,
             23'd15013, 23'd16001, 23'd17011, 23'd18013,
             23'd19001, 23'd20011);

    @(posedge clk);
    #1;
    mode_dsa = 1'b0;
    inverse_mode = 1'b0;
    a_share0 = 23'd1;
    b_share0 = 23'd2;
    twiddle_share0 = 23'd1;
    random_valid = 1'b0;
    start = 1'b1;
    @(posedge clk);
    #1;
    start = 1'b0;
    if (!done || !error || !random_missing_error) begin
        $display("FAIL missing randomness done=%0d error=%0d missing=%0d",
                 done, error, random_missing_error);
        failures = failures + 1;
    end else begin
        $display("PASS missing randomness error path");
    end

    if (random_accept_count != 16'd4) begin
        $display("FAIL random_accept_count=%0d expected=4",
                 random_accept_count);
        failures = failures + 1;
    end

    if (failures == 0) begin
        $display("tb_fused_butterfly_masked2 PASS prototype_recombination_and_randomness_accounting");
        $finish;
    end else begin
        $display("tb_fused_butterfly_masked2 FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (1000) @(posedge clk);
    $display("tb_fused_butterfly_masked2 FAIL timeout");
    $fatal(1);
end

endmodule
