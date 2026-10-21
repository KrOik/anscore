`timescale 1ns / 1ps
// Standalone check of aes128_core against FIPS-197 published vectors and one
// pycryptodome vector (tools/golden_model.py output, independent of RTL).
module tb_aes128_core;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg start = 1'b0;
reg [127:0] key, din;
wire [127:0] dout;
wire done, busy;
integer failures = 0;

always #5 clk = ~clk;

aes128_core dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .start(start), .key(key), .din(din),
    .dout(dout), .done(done), .busy(busy)
);

task run_vec;
    input [127:0] k;
    input [127:0] d;
    input [127:0] exp;
    begin
        @(posedge clk); key <= k; din <= d; start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        wait (done === 1'b1);
        @(posedge clk);
        if (dout !== exp) begin
            $display("FAIL key=%032x din=%032x", k, d);
            $display("     got=%032x exp=%032x", dout, exp);
            failures = failures + 1;
        end else begin
            $display("ok   %032x -> %032x", d, dout);
        end
    end
endtask

initial begin
    repeat (8) @(posedge clk);
    rst_n <= 1'b1;
    repeat (4) @(posedge clk);

    // FIPS-197 Appendix C.1
    run_vec(128'h000102030405060708090a0b0c0d0e0f,
            128'h00112233445566778899aabbccddeeff,
            128'h69c4e0d86a7b0430d8cdb78070b4c55a);
    // all-zero known answer
    run_vec(128'h0, 128'h0,
            128'h66e94bd4ef8a2c3b884cfa59ca342b2e);
    // FIPS-197 Appendix B / SP800-38A F.1.1
    run_vec(128'h2b7e151628aed2a6abf7158809cf4f3c,
            128'h6bc1bee22e409f96e93d7e117393172a,
            128'h3ad77bb40d7a3660a89ecaf32466ef97);
    // pycryptodome-generated vector
    run_vec(128'hd5f0e1d2c3b4a5968778695a4b3c2d1e,
            128'h00102030405060708090a0b0c0d0e0f0,
            128'h159a051d0660c2c42511c3fdb23682a2);

    if (failures == 0) $display("tb_aes128_core PASS");
    else               $display("tb_aes128_core FAIL failures=%0d", failures);
    $finish;
end

initial begin
    repeat (20000) @(posedge clk);
    $display("tb_aes128_core FAIL timeout");
    $fatal(1);
end

endmodule
