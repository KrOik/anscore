`timescale 1ns/1ps
// ============================================================================
// tb_w2_selftest -- aggregated wave2 selftest TB.
// Drives clk/rst_n, waits for all_done, scans per-unit digests via digest_sel,
// prints one line per unit "W2ST Uii D=XXXXXXXX V=<P|F|X>" then the verdict
// "W2TB W2ALL PASS/FAIL".  Compile with -Ptb_w2_selftest.MASK=40'h... to test
// a UNIT_EN mask.
// ============================================================================
module tb_w2_selftest;
`ifdef MASK_HEX
    parameter [39:0] MASK = `MASK_HEX;
`else
    parameter [39:0] MASK = 40'hFF_FF_FF_FF_FF;
`endif

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire all_done, all_pass, any_fail;
    wire [39:0] done_mask, pass_mask;
    reg  [5:0]  digest_sel = 6'd0;
    wire [31:0] digest_q;

    w2_selftest #(.UNIT_EN(MASK)) dut (
        .clk(clk), .rst_n(rst_n),
        .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
        .digest_sel(digest_sel), .digest_q(digest_q),
        .done_mask(done_mask), .pass_mask(pass_mask));

    integer i;
    integer timeout = 40_000_000;

    initial begin
        repeat (40) @(posedge clk);
        rst_n = 1;
        for (i = 0; i < timeout && !all_done; i = i + 1) @(posedge clk);
        if (!all_done) begin
            $display("W2TB W2ALL FAIL timeout done_mask=%010x", done_mask);
            $finish;
        end
        // settle, then scan digests (digest_q is combinational on sel)
        repeat (4) @(posedge clk);
        for (i = 0; i < 40; i = i + 1) begin
            digest_sel = i[5:0];
            #1;
            $display("W2ST U%02d D=%08X V=%s", i, digest_q,
                     !MASK[i] ? "S" :
                     (pass_mask[i] ? "P" : (done_mask[i] ? "F" : "X")));
        end
        if (all_done && all_pass && !any_fail)
            $display("W2TB W2ALL PASS M=%010x", MASK);
        else
            $display("W2TB W2ALL FAIL M=%010x done=%010x pass=%010x",
                     MASK, done_mask, pass_mask);
        $finish;
    end
endmodule
