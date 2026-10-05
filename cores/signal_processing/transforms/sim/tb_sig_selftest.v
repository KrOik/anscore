`timescale 1ns/1ps
// Runs sig_selftest to completion and prints every unit digest.
// Golden EXP_* constants live in src/sig_selftest.v (from tools/golden_model.py).
module tb_sig_selftest;

`ifndef UNIT_EN
`define UNIT_EN 4'hF
`endif

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

wire all_done, all_pass, any_fail;
wire [3:0] done_mask, pass_mask;
reg  [4:0]  sel = 5'd0;
wire [31:0] dq;

sig_selftest #(.UNIT_EN(`UNIT_EN)) dut (
    .clk(clk), .rst_n(rst_n),
    .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
    .digest_sel(sel), .digest_q(dq),
    .done_mask(done_mask), .pass_mask(pass_mask)
);

reg [8*6-1:0] names [0:3];
initial begin
    names[0]="FFT"; names[1]="CIC"; names[2]="HST"; names[3]="OTSU";
end

integer i;
integer timeout;

// ---------------------------------------------------------------------------
// Stream dumps for offline golden-model comparison (simulation only)
// ---------------------------------------------------------------------------
integer fd_fft, fd_cic, fd_hist;
initial begin
    fd_fft  = $fopen("sim/dump_fft.txt", "w");
    fd_cic  = $fopen("sim/dump_cic.txt", "w");
    fd_hist = $fopen("sim/dump_hist.txt", "w");
end

// dump hooks use only module-level signals (valid under every UNIT_EN mask)
always @(posedge clk) begin
    if (rst_n && dut.fstate === 4'd5 && dut.ce && !dut.f_done)
        $fwrite(fd_fft, "%08x\n", dut.fft_mag2);
    if (rst_n && dut.cic_ov && dut.ce)
        $fwrite(fd_cic, "%05x\n", dut.cic_dout & 17'h1ffff);
    if (rst_n && dut.ce && (dut.hstate === 5'd5 || dut.hstate === 5'd10)
            && !dut.h_done)
        $fwrite(fd_hist, "%04x\n", dut.hist_rd_data);
end

initial begin
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    timeout = 0;
    while (!all_done && timeout < 500000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end
    if (!all_done) begin
        $display("SELFTEST TIMEOUT done_mask=%x", done_mask);
    end
    // let digest registers and verdict latch settle
    repeat (64) @(posedge clk);
    for (i = 0; i < 4; i = i + 1) begin
        sel = i[4:0];
        #1;
        $display("UNIT %0d %-4s done=%b pass=%b digest=%08x",
                 i, names[i], done_mask[i], pass_mask[i], dq);
    end
    $display("SELFTEST %s done_mask=%x pass_mask=%x",
             all_pass ? "ALL-PASS" : "DONE-WITH-FAIL", done_mask, pass_mask);
    if (all_done && all_pass && !any_fail) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $fclose(fd_fft); $fclose(fd_cic); $fclose(fd_hist);
    $finish;
end

endmodule
