`timescale 1ns / 1ps

// Selftest TB: runs dsp_selftest, prints per-unit digests, requires
// all_done && all_pass && !any_fail. Optional dump of raw digest table.
module tb_dsp_selftest;

`ifndef UNIT_EN
`define UNIT_EN 16'hFFFF
`endif

reg clk = 1'b0;
reg rst_n = 1'b0;
wire all_done, all_pass, any_fail;
wire [15:0] done_mask, pass_mask;
reg  [4:0]  digest_sel = 5'd0;
wire [31:0] digest_q;

always #5 clk = ~clk;

dsp_selftest #(.UNIT_EN(`UNIT_EN)) dut (
    .clk(clk), .rst_n(rst_n),
    .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
    .digest_sel(digest_sel), .digest_q(digest_q),
    .done_mask(done_mask), .pass_mask(pass_mask)
);

integer i;

initial begin
    repeat (20) @(posedge clk);
    @(negedge clk);              // release mid-cycle: matches board reset_count
    rst_n = 1'b1;                // timing and avoids the clk_en delta race
    wait (all_done === 1'b1);
    repeat (40) @(posedge clk);   // let pass_r settle (template convention)

    for (i = 0; i < 5; i = i + 1) begin
        digest_sel = i[4:0];
        #1;
        $display("UNIT %0d digest=%08X done=%b pass=%b",
                 i, digest_q, done_mask[i], pass_mask[i]);
    end
    $display("done_mask=%04X pass_mask=%04X all_pass=%b any_fail=%b",
             done_mask, pass_mask, all_pass, any_fail);

    if (all_done && all_pass && !any_fail) begin
        $display("tb_dsp_selftest PASS");
        $finish;
    end else begin
        $display("tb_dsp_selftest FAIL");
        $fatal(1);
    end
end

initial begin
    repeat (2000000) @(posedge clk);
    $display("tb_dsp_selftest FAIL timeout");
    $fatal(1);
end

endmodule
