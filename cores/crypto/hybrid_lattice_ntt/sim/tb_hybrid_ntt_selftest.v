`timescale 1ns / 1ps

module tb_hybrid_ntt_selftest;

reg clk = 1'b0;
reg rst_n = 1'b0;
wire test_done;
wire test_pass;
wire test_fail;
wire [2:0] case_index;
wire [31:0] cycle_count;
wire [31:0] digest;

always #5 clk = ~clk;

hybrid_ntt_selftest dut (
    .clk(clk),
    .rst_n(rst_n),
    .test_done(test_done),
    .test_pass(test_pass),
    .test_fail(test_fail),
    .case_index(case_index),
    .cycle_count(cycle_count),
    .digest(digest)
);

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    repeat (400) begin
        @(posedge clk);
        if (test_done) begin
            if (test_pass && !test_fail && case_index == 3'd4) begin
                $display("tb_hybrid_ntt_selftest PASS cycles=%0d digest=%08x", cycle_count, digest);
                $finish;
            end else begin
                $display("tb_hybrid_ntt_selftest FAIL pass=%0d fail=%0d case=%0d", test_pass, test_fail, case_index);
                $fatal(1);
            end
        end
    end

    $display("tb_hybrid_ntt_selftest FAIL timeout");
    $fatal(1);
end

endmodule
