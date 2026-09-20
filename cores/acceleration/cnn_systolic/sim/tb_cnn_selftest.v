`timescale 1ns/1ps
// Runs cnn_selftest to completion and prints every unit digest.
// Usage: run once with EXP_* = 0 to harvest golden digests, then embed
// them in src/cnn_selftest.v so the board can self-check.
module tb_cnn_selftest;

`ifndef UNIT_EN
`define UNIT_EN 16'hFFFF
`endif

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

wire all_done, all_pass, any_fail;
wire [15:0] done_mask, pass_mask;
reg  [4:0]  sel = 5'd0;
wire [31:0] dq;

cnn_selftest #(.UNIT_EN(`UNIT_EN)) dut (
    .clk(clk), .rst_n(rst_n),
    .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
    .digest_sel(sel), .digest_q(dq),
    .done_mask(done_mask), .pass_mask(pass_mask)
);

reg [8*6-1:0] names [0:15];
initial begin
    names[0]="PE";    names[1]="PED";   names[2]="DM";    names[3]="WM";
    names[4]="RAM";   names[5]="FIFO";  names[6]="COL";   names[7]="PAGE";
    names[8]="POOL";  names[9]="ALUT";  names[10]="IL";   names[11]="OL";
    names[12]="LAYR"; names[13]="EXTR"; names[14]="SSUM"; names[15]="CTC";
end

integer i;
integer timeout;

// ---------------------------------------------------------------------------
// Stream dumps for offline golden-model comparison (simulation only)
// ---------------------------------------------------------------------------
integer fd_il, fd_ol, fd_ly, fd_ss, fd_ef, fd_ctc;
initial begin
    fd_il = $fopen("sim/dump_il.txt", "w");
    fd_ol = $fopen("sim/dump_ol.txt", "w");
    fd_ly = $fopen("sim/dump_ly.txt", "w");
    fd_ss = $fopen("sim/dump_ss.txt", "w");
    fd_ef = $fopen("sim/dump_ef.txt", "w");
    fd_ctc = $fopen("sim/dump_ctc.txt", "w");
end

// input_layer: dump all 18 window bytes per valid beat, plus nlo flag
always @(posedge clk) begin
    if (rst_n && dut.il_ov) begin
        $fwrite(fd_il, "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x %b\n",
                dut.il_dout[0][0], dut.il_dout[0][1], dut.il_dout[1][0], dut.il_dout[1][1],
                dut.il_dout[2][0], dut.il_dout[2][1], dut.il_dout[3][0], dut.il_dout[3][1],
                dut.il_dout[4][0], dut.il_dout[4][1], dut.il_dout[5][0], dut.il_dout[5][1],
                dut.il_dout[6][0], dut.il_dout[6][1], dut.il_dout[7][0], dut.il_dout[7][1],
                dut.il_dout[8][0], dut.il_dout[8][1], dut.il_nlo);
    end
    if (rst_n && dut.ol_v) begin
        $fwrite(fd_ol, "%02x%02x %b\n", dut.ol_out[0], dut.ol_out[1], dut.ol_nlo);
    end
    if (rst_n && dut.ly_v) begin
        $fwrite(fd_ly, "%02x%02x %b\n", dut.ly_out[0], dut.ly_out[1], dut.ly_nlo);
    end
    if (rst_n && dut.ss_v) begin
        $fwrite(fd_ss, "%04x%04x %b\n", dut.ss_y[0], dut.ss_y[1], dut.ss_nlo);
    end
    if (rst_n && dut.ss_nlo) begin
        $fwrite(fd_ss, "nlo\n");
    end
    if (rst_n && dut.ef_v) begin
        $fwrite(fd_ef, "%04x %02x\n", dut.ef_val, dut.ef_ch);
    end
    if (rst_n && dut.ctc_v) begin
        $fwrite(fd_ctc, "%02x\n", dut.ctc_char);
    end
    // stimulus events seen by ssum/ctc DUTs (for golden-model alignment)
    if (rst_n && (dut.ss_nl || dut.ss_dv)) begin
        $fwrite(fd_ss, "in %b %b %02x %02x\n", dut.ss_nl, dut.ss_dv,
                8'($signed(dut.ss_seq + (dut.ss_seq<<2) + 7'd2)),
                8'($signed(dut.ss_seq + (dut.ss_seq<<3) - 7'd40)));
    end
    if (rst_n && (dut.ctc_nl || dut.ctc_dv)) begin
        $fwrite(fd_ctc, "in %b %b %02x %02x\n", dut.ctc_nl, dut.ctc_dv,
                8'($signed(dut.ctc_seq + (dut.ctc_seq<<2) + 7'd2)),
                8'($signed(dut.ctc_seq + (dut.ctc_seq<<3) - 7'd40)));
    end
end

initial begin
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    timeout = 0;
    while (!all_done && timeout < 200000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end
    if (!all_done) begin
        $display("SELFTEST TIMEOUT done_mask=%04x", done_mask);
    end
    // let digest registers and the verdict latch settle (verdict is captured
    // one ce beat, i.e. ~16 clks, after all_done asserts)
    repeat (64) @(posedge clk);
    for (i = 0; i < 16; i = i + 1) begin
        sel = i[4:0];
        #1;
        $display("UNIT %0d %-4s done=%b pass=%b digest=%08x",
                 i, names[i], done_mask[i], pass_mask[i], dq);
    end
    $display("SELFTEST %s done_mask=%04x pass_mask=%04x",
             all_pass ? "ALL-PASS" : "DONE-WITH-FAIL", done_mask, pass_mask);
    if (all_done && all_pass && !any_fail) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $fclose(fd_il); $fclose(fd_ol); $fclose(fd_ly);
    $fclose(fd_ss); $fclose(fd_ef); $fclose(fd_ctc);
    $finish;
end

endmodule
