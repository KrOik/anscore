`timescale 1ns / 1ps

module tb_ntt256_serial_core;

reg clk = 1'b0;
reg rst_n = 1'b0;
wire test_done;
wire test_pass;
wire test_fail;
wire [1:0] phase;
wire [31:0] cycle_count;
wire [31:0] digest;
wire [31:0] kem_ntt_digest;
wire [31:0] dsa_ntt_digest;
wire [31:0] kem_intt_digest;
wire [31:0] dsa_intt_digest;
wire [31:0] kem_flow_digest;
wire [31:0] dsa_flow_digest;

always #5 clk = ~clk;

hybrid_ntt256_selftest dut (
    .clk(clk),
    .rst_n(rst_n),
    .test_done(test_done),
    .test_pass(test_pass),
    .test_fail(test_fail),
    .phase(phase),
    .cycle_count(cycle_count),
    .digest(digest),
    .kem_ntt_digest(kem_ntt_digest),
    .dsa_ntt_digest(dsa_ntt_digest),
    .kem_intt_digest(kem_intt_digest),
    .dsa_intt_digest(dsa_intt_digest),
    .kem_flow_digest(kem_flow_digest),
    .dsa_flow_digest(dsa_flow_digest)
);

initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    repeat (260000) begin
        @(posedge clk);
        if (test_done) begin
            if (test_pass && !test_fail && digest == 32'h2f9c94ad) begin
                $display("tb_ntt256_serial_core PASS cycles=%0d digest=%08x", cycle_count, digest);
                $finish;
            end else begin
                $display("tb_ntt256_serial_core FAIL pass=%0d fail=%0d phase=%0d digest=%08x",
                         test_pass, test_fail, phase, digest);
                $fatal(1);
            end
        end
    end

    $display("tb_ntt256_serial_core FAIL timeout phase=%0d digest=%08x", phase, digest);
    $fatal(1);
end

endmodule
