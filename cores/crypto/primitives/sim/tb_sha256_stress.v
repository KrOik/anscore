`timescale 1ns/1ps
module tb_sha256_stress;
  reg clk=0, rst_n=0, ce=1, init=0, valid=0, last=0;
  reg [7:0] din=0;
  wire ready,dv,ref_ready,ref_dv;
  wire [255:0] hash,ref_hash;
  reg [319:0] cases[0:63];
  reg [7:0] bytes_mem[0:262143];
  reg [257:0] held;
  integer c,i,offset,length,cycles;
  always #5 clk=~clk;
  sha256_core dut(.clk(clk),.clk_en(ce),.rst_n(rst_n),.init(init),
    .din(din),.din_valid(valid),.din_last(last),.din_ready(ready),.digest(hash),.digest_valid(dv));
  sha256_reference refdut(.clk(clk),.clk_en(ce),.rst_n(rst_n),.init(init),
    .din(din),.din_valid(valid),.din_last(last),.din_ready(ref_ready),.digest(ref_hash),.digest_valid(ref_dv));
  always @(posedge clk) begin
    held={ready,dv,hash}; #1;
    if({ready,dv,hash} !== {ref_ready,ref_dv,ref_hash})
      $fatal(1,"cycle-level difference from original");
    if(rst_n && !ce && {ready,dv,hash}!==held) $fatal(1,"clk_en freeze");
  end
  task tick; begin @(negedge clk); end endtask
  task restart;
    begin ce=1; valid=0; last=0; init=1; tick; init=0; end
  endtask
  task send_byte(input [7:0] value,input final_byte);
    begin
      din=value; valid=1; last=final_byte;
      while(ready!==1) tick;
      tick;
      valid=0; last=0;
    end
  endtask
  initial begin
    $readmemh("sha_cases.mem",cases);
    $readmemh("sha_bytes.mem",bytes_mem,0,cases[63][319:288]+cases[63][287:256]-1);
    repeat(3) tick; rst_n=1; tick;
    for(c=0;c<64;c=c+1) begin
      restart;
      offset=cases[c][319:288]; length=cases[c][287:256];
      for(i=0;i<length;i=i+1) begin
        if(i%11==0) begin ce=0; repeat(2) tick; ce=1; end
        if(i%7==0) tick;
        send_byte(bytes_mem[offset+i],i==length-1);
      end
      cycles=0;
      while(dv!==1 && cycles<10000) begin
        ce=(cycles%13!=0); tick; cycles=cycles+1;
      end
      ce=1;
      if(dv!==1 || hash!==cases[c][255:0]) $fatal(1,"hashlib mismatch case=%0d len=%0d",c,length);
      repeat(2) tick;
      if(dv!==1) $fatal(1,"digest_valid must hold until init");
    end
    // Abort an incomplete load and, separately, an active compression.
    restart;
    for(i=0;i<19;i=i+1) send_byte(i,0);
    restart;
    for(i=0;i<64;i=i+1) send_byte(i,0);
    repeat(9) tick;
    restart;
    send_byte(bytes_mem[cases[0][319:288]],1);
    cycles=0;
    while(dv!==1 && cycles<1000) begin tick; cycles=cycles+1; end
    if(dv!==1 || hash!==cases[0][255:0]) $fatal(1,"init abort recovery");
    restart; send_byte(8'h42,0); rst_n=0; #1;
    if(dv!==0 || ready!==1) $fatal(1,"async reset");
    tick; rst_n=1; restart;
    send_byte(bytes_mem[cases[0][319:288]],1);
    cycles=0;
    while(dv!==1 && cycles<1000) begin tick; cycles=cycles+1; end
    if(dv!==1 || hash!==cases[0][255:0]) $fatal(1,"reset recovery");
    $display("SHA_STRESS PASS messages=64 hashlib cycle_equivalence stalls bubbles init_abort reset");
    $finish;
  end
  initial begin #10000000; $fatal(1,"timeout"); end
endmodule
