`timescale 1ns / 1ps

module tb_ntt256_systolic_state_equiv_monitor;

reg clk = 1'b0;
reg rst_n = 1'b0;
wire done;
wire pass;
wire fail;
wire [15:0] bubble_count;
wire [15:0] issue_count;
wire [15:0] output_count;
wire [31:0] signature;
wire [31:0] dbg_kem_ntt_digest;
wire [31:0] dbg_dsa_ntt_digest;
wire [31:0] dbg_kem_intt_digest;
wire [31:0] dbg_dsa_intt_digest;

always #5 clk = ~clk;

ntt256_systolic_state_equiv_monitor dut (
    .clk(clk),
    .rst_n(rst_n),
    .done(done),
    .pass(pass),
    .fail(fail),
    .bubble_count(bubble_count),
    .issue_count(issue_count),
    .output_count(output_count),
    .signature(signature),
    .dbg_kem_ntt_digest(dbg_kem_ntt_digest),
    .dbg_dsa_ntt_digest(dbg_dsa_ntt_digest),
    .dbg_kem_intt_digest(dbg_kem_intt_digest),
    .dbg_dsa_intt_digest(dbg_dsa_intt_digest)
);

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    wait (done || fail);
    if (done && pass && !fail &&
        (bubble_count == 16'd0) &&
        (issue_count == 16'h1200) &&
        (output_count == 16'h1200) &&
        (signature == 32'h0b1a0306) &&
        (dbg_kem_ntt_digest == 32'h1e664367) &&
        (dbg_dsa_ntt_digest == 32'h7fc8e2fc) &&
        (dbg_kem_intt_digest == 32'hb88a6c64) &&
        (dbg_dsa_intt_digest == 32'hd23ecef9)) begin
        $display("tb_ntt256_systolic_state_equiv_monitor PASS issue=%0d output=%0d bubbles=%0d signature=%08x kem=%08x dsa=%08x kemi=%08x dsai=%08x",
                 issue_count, output_count, bubble_count, signature,
                 dbg_kem_ntt_digest, dbg_dsa_ntt_digest,
                 dbg_kem_intt_digest, dbg_dsa_intt_digest);
        $finish;
    end

    $display("tb_ntt256_systolic_state_equiv_monitor FAIL done=%0d pass=%0d fail=%0d issue=%0d output=%0d bubbles=%0d signature=%08x kem=%08x dsa=%08x kemi=%08x dsai=%08x",
             done, pass, fail, issue_count, output_count, bubble_count,
             signature, dbg_kem_ntt_digest, dbg_dsa_ntt_digest,
             dbg_kem_intt_digest, dbg_dsa_intt_digest);
    $fatal(1);
end

initial begin
    repeat (100000) @(posedge clk);
    $display("tb_ntt256_systolic_state_equiv_monitor FAIL timeout");
    $fatal(1);
end

endmodule
