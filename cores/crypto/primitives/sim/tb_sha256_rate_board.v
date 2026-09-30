`timescale 1ns/1ps
module tb_sha256_rate_board;
  reg clk=0;
  always #5 clk=~clk;
  wire done,pass,fail;
  reg [271:0] expected[0:11];
  integer i;
  sha256_rate_board dut(.clk(clk),.dbg_done(done),.dbg_pass(pass),.dbg_fail(fail));
  initial begin
    $readmemh("sha_board_expected.mem",expected);
    wait(done===1); #1;
    if(pass!==1 || fail!==0 || dut.completed!==12) $fatal(1,"board verdict/cycle count");
    for(i=0;i<12;i=i+1)
      if(dut.results[3263-i*272 -: 272]!==expected[i]) $fatal(1,"digest/cycles case %0d",i);
    $display("SHA_RATE_BOARD PASS cases=12 hashlib_digests exact_cycles full_rate");
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
