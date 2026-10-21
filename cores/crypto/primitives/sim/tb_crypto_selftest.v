`timescale 1ns / 1ps
// Runs crypto_selftest to completion; requires all_done && all_pass &&
// !any_fail. Prints per-unit digests for cross-checking vs golden model.
module tb_crypto_selftest;

`ifndef UNIT_EN
`define UNIT_EN 8'h1F
`endif

reg clk = 1'b0;
reg rst_n = 1'b0;
wire all_done, all_pass, any_fail;
reg [4:0] sel = 5'd0;
wire [31:0] digest_q;
wire [15:0] done_mask, pass_mask;
integer i;

always #5 clk = ~clk;

crypto_selftest #(.UNIT_EN(`UNIT_EN)) dut (
    .clk(clk), .rst_n(rst_n),
    .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
    .digest_sel(sel), .digest_q(digest_q),
    .done_mask(done_mask), .pass_mask(pass_mask)
);

initial begin
    repeat (300) @(posedge clk);
    rst_n <= 1'b1;
    wait (all_done === 1'b1 || any_fail === 1'b1);
    repeat (40) @(posedge clk);

    for (i = 0; i < 5; i = i + 1) begin
        sel <= i[4:0];
        @(posedge clk); @(posedge clk);
        $display("unit %0d digest = %08x", i, digest_q);
    end
    $display("done_mask=%04x pass_mask=%04x all_pass=%0d any_fail=%0d",
             done_mask, pass_mask, all_pass, any_fail);

    if (all_done && all_pass && !any_fail)
        $display("tb_crypto_selftest PASS");
    else
        $display("tb_crypto_selftest FAIL");
    $finish;
end

initial begin
    repeat (5000000) @(posedge clk);
    $display("tb_crypto_selftest FAIL timeout");
    $fatal(1);
end

endmodule
