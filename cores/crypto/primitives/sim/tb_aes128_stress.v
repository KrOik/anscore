`timescale 1ns/1ps
module tb_aes128_stress;
  reg clk=0, rst_n=0, ce=1, start=0;
  reg [127:0] key=0, din=0;
  wire [127:0] dout;
  wire done, busy;
  reg [383:0] vectors [0:255];
  reg [127:0] previous, expected;
  integer i, beat;
  always #5 clk=~clk;
  aes128_core dut(.clk(clk),.clk_en(ce),.rst_n(rst_n),.start(start),
    .key(key),.din(din),.dout(dout),.done(done),.busy(busy));
  task tick;
    begin @(negedge clk); end
  endtask
  initial begin
    $readmemh("aes_vectors.mem",vectors);
    repeat(3) tick; rst_n=1; tick;
    for(i=0;i<256;i=i+1) begin
      previous=dout; expected=vectors[i][127:0];
      key=vectors[i][383:256]; din=vectors[i][255:128]; start=1;
      tick;
      if(busy!==1 || done!==0) $fatal(1,"launch %0d",i);
      // Change inputs and assert start while busy: accepted transaction wins.
      key=~key; din=~din;
      for(beat=0;beat<10;beat=beat+1) begin
        if(beat%3==0) begin
          ce=0; repeat(2) tick;
          if(busy!==1 || done!==0 || dout!==previous) $fatal(1,"pause %0d",i);
          ce=1;
        end
        tick;
        if(beat<9 && (busy!==1 || done!==0 || dout!==previous))
          $fatal(1,"early output %0d beat %0d",i,beat);
      end
      if(busy!==0 || done!==1 || dout!==expected)
        $fatal(1,"ciphertext %0d got %032x expected %032x",i,dout,expected);
      start=0; ce=0; repeat(2) tick;
      if(done!==1 || dout!==expected) $fatal(1,"done must freeze with ce=0");
      ce=1; tick;
      if(done!==0) $fatal(1,"done must clear after one enabled beat");
    end
    start=1; tick; start=0; repeat(4) tick;
    rst_n=0; #1;
    if(done!==0 || busy!==0 || dout!==0) $fatal(1,"mid-block reset failed");
    tick; rst_n=1; tick;
    key=vectors[0][383:256]; din=vectors[0][255:128]; start=1;
    tick; start=0; repeat(10) tick;
    if(done!==1 || dout!==vectors[0][127:0]) $fatal(1,"reset recovery failed");
    $display("AES_STRESS PASS vectors=256 rounds=10 ce_pause busy_start reset_recovery");
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
