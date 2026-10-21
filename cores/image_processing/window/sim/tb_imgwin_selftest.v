`timescale 1ns/1ps
// ============================================================================
// tb_imgwin_selftest -- runs imgwin_selftest to completion, prints every unit
// digest, and dumps each DUT's output stream to sim/dump_*.txt for offline
// comparison against tools/golden_model.py output (sim/golden_*.txt).
// ============================================================================
module tb_imgwin_selftest;

`ifndef UNIT_EN
`define UNIT_EN 6'h3F
`endif

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

wire all_done, all_pass, any_fail;
wire [5:0] done_mask, pass_mask;
reg  [4:0] sel = 5'd0;
wire [31:0] dq;

imgwin_selftest #(.UNIT_EN(`UNIT_EN)) dut (
    .clk(clk), .rst_n(rst_n),
    .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
    .digest_sel(sel), .digest_q(dq),
    .done_mask(done_mask), .pass_mask(pass_mask)
);

reg [8*4-1:0] names [0:5];
initial begin
    names[0]="WIN"; names[1]="GAUS"; names[2]="SOB";
    names[3]="MED"; names[4]="MRP"; names[5]="THR";
end

integer i;
integer timeout;
reg [7:0] mrp_er_d = 8'd0, mrp_di_d = 8'd0;

// ---------------------------------------------------------------------------
// stream dumps for offline golden comparison (simulation only)
// ---------------------------------------------------------------------------
integer fd_win, fd_gau, fd_sob, fd_med, fd_mrp, fd_thr;
initial begin
    fd_win = $fopen("sim/dump_win.txt", "w");
    fd_gau = $fopen("sim/dump_gau.txt", "w");
    fd_sob = $fopen("sim/dump_sob.txt", "w");
    fd_med = $fopen("sim/dump_med.txt", "w");
    fd_mrp = $fopen("sim/dump_mrp.txt", "w");
    fd_thr = $fopen("sim/dump_thr.txt", "w");
end

// dump each logical-beat output exactly once: sample at the ce edge
// (ce_div==15 posedge sees the value set by the previous ce beat)
wire ce_beat = (dut.ce_div == 4'd15);
always @(posedge clk) begin
    if (rst_n && ce_beat && dut.w0_v === 1'b1)
        $fwrite(fd_win, "%02x%02x%02x%02x%02x%02x%02x%02x%02x %b\n",
                dut.w0_win[7:0],   dut.w0_win[15:8],  dut.w0_win[23:16],
                dut.w0_win[31:24], dut.w0_win[39:32], dut.w0_win[47:40],
                dut.w0_win[55:48], dut.w0_win[63:56], dut.w0_win[71:64],
                dut.w0_nlo);
    if (rst_n && ce_beat && dut.g1_v === 1'b1)
        $fwrite(fd_gau, "%02x %b\n", dut.g1_pix, dut.g1_nlo);
    if (rst_n && ce_beat && dut.e2_v === 1'b1)
        $fwrite(fd_sob, "%02x%02x %b\n", dut.e2_mag, dut.e2_bin, dut.e2_nlo);
    if (rst_n && ce_beat && dut.m3_v === 1'b1)
        $fwrite(fd_med, "%02x %b\n", dut.m3_pix, dut.m3_nlo);
    // morph: capture combinational erode/dilate at the win_valid beat, write
    // the full per-window line when the registered pix_out arrives one beat
    // later -> "er di sel nlo" per line, matching golden_mrp.txt
    if (rst_n && ce_beat && dut.w4_v === 1'b1) begin
        mrp_er_d <= dut.m4_er;
        mrp_di_d <= dut.m4_di;
    end
    if (rst_n && ce_beat && dut.m4_v === 1'b1)
        $fwrite(fd_mrp, "%02x%02x%02x %b\n", mrp_er_d, mrp_di_d,
                dut.m4_pix, dut.m4_nlo);
    if (rst_n && ce_beat && dut.t5_v === 1'b1)
        $fwrite(fd_thr, "%02x\n", dut.t5_pix);
end

initial begin
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    timeout = 0;
    while (!all_done && timeout < 400000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end
    if (!all_done) begin
        $display("SELFTEST TIMEOUT done_mask=%02x", done_mask);
    end
    repeat (64) @(posedge clk);
    for (i = 0; i < 6; i = i + 1) begin
        sel = i[4:0];
        #1;
        $display("UNIT %0d %-4s done=%b pass=%b digest=%08x",
                 i, names[i], done_mask[i], pass_mask[i], dq);
    end
    $display("SELFTEST %s done_mask=%02x pass_mask=%02x",
             all_pass ? "ALL-PASS" : "DONE-WITH-FAIL", done_mask, pass_mask);
    if (all_done && all_pass && !any_fail) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $fclose(fd_win); $fclose(fd_gau); $fclose(fd_sob);
    $fclose(fd_med); $fclose(fd_mrp); $fclose(fd_thr);
    $finish;
end

endmodule
