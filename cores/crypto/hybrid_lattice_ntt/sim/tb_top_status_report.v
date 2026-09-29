`timescale 1ns / 1ps

module tb_top_status_report;

reg clk = 1'b0;
wire uart_tx_pin;
wire status_pass;
wire status_fail;

always #5 clk = ~clk;

top dut (
    .clk(clk),
    .uart_tx_pin(uart_tx_pin),
    .status_pass(status_pass),
    .status_fail(status_fail)
);

initial begin
    wait ((dut.test_done && dut.pipe_done && dut.arith_done) ||
          status_fail);
    @(posedge clk);
    #1;

    if (status_pass && !status_fail &&
        dut.report_pass &&
        dut.test_pass && !dut.test_fail &&
        dut.pipe_pass && !dut.pipe_fail &&
        (dut.pipe_bubble_count == 16'h0000) &&
        (dut.pipe_issue_count == 16'h0011) &&
        (dut.pipe_pair_mask == 16'hffff) &&
        dut.arith_pass && !dut.arith_fail &&
        (dut.arith_signature == 32'h0b1a0306) &&
        (dut.arith_dbg_kem_ntt_digest == 32'h1e664367) &&
        (dut.arith_dbg_dsa_ntt_digest == 32'h7fc8e2fc) &&
        (dut.arith_dbg_kem_intt_digest == 32'hb88a6c64) &&
        (dut.arith_dbg_dsa_intt_digest == 32'hd23ecef9) &&
        (dut.arith_bubble_count == 16'h0000) &&
        (dut.arith_issue_count == 16'h1200) &&
        (dut.arith_output_count == 16'h1200)) begin
        $display("tb_top_status_report PASS syst_sig=%08x syst_bubbles=%04x syst_issue=%04x syst_output=%04x pipe_bubbles=%04x pipe_pairs=%04x kem=%08x dsa=%08x kemi=%08x dsai=%08x",
                 dut.arith_signature, dut.arith_bubble_count,
                 dut.arith_issue_count, dut.arith_output_count,
                 dut.pipe_bubble_count, dut.pipe_pair_mask,
                 dut.arith_dbg_kem_ntt_digest, dut.arith_dbg_dsa_ntt_digest,
                 dut.arith_dbg_kem_intt_digest, dut.arith_dbg_dsa_intt_digest);
        $finish;
    end

    $display("tb_top_status_report FAIL status_pass=%0d status_fail=%0d report_pass=%0d test_done=%0d test_pass=%0d test_fail=%0d pipe_done=%0d pipe_pass=%0d pipe_fail=%0d pipe_bubbles=%04x pipe_issue=%04x pipe_pairs=%04x arith_done=%0d arith_pass=%0d arith_fail=%0d syst_sig=%08x syst_bubbles=%04x syst_issue=%04x syst_output=%04x kem=%08x dsa=%08x kemi=%08x dsai=%08x",
             status_pass, status_fail, dut.report_pass,
             dut.test_done, dut.test_pass, dut.test_fail,
             dut.pipe_done, dut.pipe_pass, dut.pipe_fail,
             dut.pipe_bubble_count, dut.pipe_issue_count, dut.pipe_pair_mask,
             dut.arith_done, dut.arith_pass, dut.arith_fail,
             dut.arith_signature, dut.arith_bubble_count,
             dut.arith_issue_count, dut.arith_output_count,
             dut.arith_dbg_kem_ntt_digest, dut.arith_dbg_dsa_ntt_digest,
             dut.arith_dbg_kem_intt_digest, dut.arith_dbg_dsa_intt_digest);
    $fatal(1);
end

initial begin
    repeat (900000) @(posedge clk);
    $display("tb_top_status_report FAIL timeout status_pass=%0d status_fail=%0d report_pass=%0d test_done=%0d pipe_done=%0d arith_done=%0d arith_pass=%0d arith_fail=%0d syst_sig=%08x syst_bubbles=%04x syst_issue=%04x syst_output=%04x",
             status_pass, status_fail, dut.report_pass,
             dut.test_done, dut.pipe_done,
             dut.arith_done, dut.arith_pass, dut.arith_fail,
             dut.arith_signature, dut.arith_bubble_count,
             dut.arith_issue_count, dut.arith_output_count);
    $fatal(1);
end

endmodule
