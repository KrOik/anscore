`timescale 1ns / 1ps
// FIPS-197 known-answer test for vendored secworks aes_core
module tb_aes_core;

reg         clk;
reg         reset_n;
reg         encdec;
reg         init;
reg         next;
wire        ready;
reg  [255:0] key;
reg         keylen;
reg  [127:0] block;
wire [127:0] result;
wire        result_valid;

integer errors = 0;

aes_core dut (
    .clk(clk), .reset_n(reset_n),
    .encdec(encdec), .init(init), .next(next), .ready(ready),
    .key(key), .keylen(keylen),
    .block(block), .result(result), .result_valid(result_valid)
);

always #5 clk = ~clk;

task run_block(input [255:0] k, input kl, input [127:0] pt,
               input ed, input [127:0] exp, input [127:0] tag);
begin
    key = k; keylen = kl; block = pt; encdec = ed;
    @(negedge clk); init = 1; @(negedge clk); init = 0;
    wait (!ready); wait (ready);
    @(negedge clk); next = 1; @(negedge clk); next = 0;
    wait (result_valid); @(posedge clk);
    if (result !== exp) begin
        errors = errors + 1;
        $display("AES FAIL tag=%h got=%h exp=%h", tag, result, exp);
    end else begin
        $display("AES PASS tag=%h result=%h", tag, result);
    end
end
endtask

initial begin
    clk = 0; reset_n = 0; encdec = 0; init = 0; next = 0;
    key = 0; keylen = 0; block = 0;
    repeat (8) @(posedge clk);
    reset_n = 1;
    repeat (4) @(posedge clk);

    // FIPS-197 AES-128 encrypt (128-bit key is MSB-aligned in key[255:128])
    run_block(256'h000102030405060708090a0b0c0d0e0f_00000000000000000000000000000000, 1'b0,
              128'h00112233445566778899aabbccddeeff, 1'b1,
              128'h69c4e0d86a7b0430d8cdb78070b4c55a, 128'hE128);
    // FIPS-197 AES-128 decrypt
    run_block(256'h000102030405060708090a0b0c0d0e0f_00000000000000000000000000000000, 1'b0,
              128'h69c4e0d86a7b0430d8cdb78070b4c55a, 1'b0,
              128'h00112233445566778899aabbccddeeff, 128'hD128);
    // FIPS-197 AES-256 encrypt
    run_block(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f, 1'b1,
              128'h00112233445566778899aabbccddeeff, 1'b1,
              128'h8ea2b7ca516745bfeafc49904b496089, 128'hE256);
    // FIPS-197 AES-256 decrypt
    run_block(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f, 1'b1,
              128'h8ea2b7ca516745bfeafc49904b496089, 1'b0,
              128'h00112233445566778899aabbccddeeff, 128'hD256);

    if (errors == 0) $display("AES ALL PASS");
    else             $display("AES ERRORS=%0d", errors);
    $finish;
end

endmodule
