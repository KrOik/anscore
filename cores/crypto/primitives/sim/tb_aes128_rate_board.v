`timescale 1ns/1ps
module tb_aes128_rate_board;
  reg clk=0;
  always #5 clk=~clk;
  wire complete, pass, fail;
  aes128_rate_board dut(.clk(clk),.dbg_done(complete),.dbg_pass(pass),.dbg_fail(fail));
  initial begin
    wait(complete===1); #1;
    if(pass!==1 || fail!==0 || dut.measured!==10)
      $fatal(1,"full-rate verdict");
    if(dut.results !== 512'h69c4e0d86a7b0430d8cdb78070b4c55a66e94bd4ef8a2c3b884cfa59ca342b2e3ad77bb40d7a3660a89ecaf32466ef97159a051d0660c2c42511c3fdb23682a2)
      $fatal(1,"raw ciphertext capture");
    $display("AES_RATE_BOARD PASS vectors=4 rounds=10 full_rate");
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
