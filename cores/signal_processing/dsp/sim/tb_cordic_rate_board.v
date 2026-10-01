`timescale 1ns/1ps
module tb_cordic_rate_board;
  reg clk=0;
  always #5 clk=~clk;
  wire done,pass,fail;
  reg [63:0] expected[0:31];
  integer i;
  cordic_rate_board dut(.clk(clk),.dbg_done(done),.dbg_pass(pass),.dbg_fail(fail));
  initial begin
    $readmemh("cordic_board_expected.mem",expected);
    wait(done===1); #1;
    if(pass!==1 || fail!==0 || dut.latency!==17 || dut.received!==32)
      $fatal(1,"stream status/latency");
    for(i=0;i<32;i=i+1)
      if(dut.results[2047-i*64 -: 64]!==expected[i])
        $fatal(1,"board stream %0d",i);
    $display("CORDIC_RATE_BOARD PASS outputs=32 latency=17 cadence=1 modes=2");
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
