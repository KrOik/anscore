`timescale 1ns/1ps
module tb_fft64_stress;
reg clk=0; always #5 clk=~clk;
reg clk_en=1, rst_n=0, ld_en=0, start=0, rd_en=0;
reg [5:0] ld_addr=0, rd_addr=0;
reg signed [15:0] ld_re=0, ld_im=0;
wire busy, done, ref_busy, ref_done;
wire signed [15:0] rd_re, rd_im, ref_re, ref_im;
fft64 dut(.*);
fft64_baseline ref_dut(.clk(clk),.clk_en(clk_en),.rst_n(rst_n),
 .ld_en(ld_en),.ld_addr(ld_addr),.ld_re(ld_re),.ld_im(ld_im),
 .start(start),.busy(ref_busy),.done(ref_done),.rd_en(rd_en),
 .rd_addr(rd_addr),.rd_re(ref_re),.rd_im(ref_im));
reg [31:0] inputs[0:8191], expected[0:8191];
reg [31:0] rng=32'h1234abcd;
integer v,n,cycles,wall,checks=0;
reg previous_en;
task tick;
 reg check_read, check_hold;
 reg [31:0] before_data;
 begin
  check_read=rd_en && !busy && clk_en;
  check_hold=!clk_en;
  before_data={rd_re,rd_im};
  @(posedge clk); #1;
  if ({busy,done} !== {ref_busy,ref_done}) $fatal(1,"control mismatch");
  // Host readout is defined only outside busy; the optimized core intentionally
  // fetches butterfly operands in the opposite internal order.
  if (check_read && {rd_re,rd_im} !== {ref_re,ref_im}) $fatal(1,"read data mismatch v=%0d",v);
  if (check_hold && {rd_re,rd_im} !== before_data) $fatal(1,"read output changed while disabled");
  @(negedge clk);
 end
endtask
task run_fft;
 input stalls;
 begin
  start=1; clk_en=1; tick; start=0;
  if (!busy || done) $fatal(1,"start not accepted");
  cycles=0; wall=0;
  while(busy) begin
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   clk_en=!stalls || rng[0] || rng[3];
   // Busy-time host requests must not corrupt the operation.
   start=(wall%37==0); ld_en=(wall%19==0); rd_en=(wall%11==0);
   previous_en=clk_en;
   tick;
   if(previous_en) cycles=cycles+1;
   wall=wall+1;
   if(wall>2000) $fatal(1,"timeout");
  end
  start=0; ld_en=0; rd_en=0; clk_en=1;
  if(!done || cycles!=768) $fatal(1,"bad latency %0d",cycles);
 end
endtask
initial begin
 $readmemh("fft_input.mem",inputs); $readmemh("fft_expected.mem",expected);
 repeat(3) tick; rst_n=1;
 // Abort a partial operation, then completely reload after reset.
 start=1; tick; start=0; repeat(29) tick;
 rst_n=0; tick;
 if(busy || done) $fatal(1,"reset control");
 rst_n=1;
 for(v=0;v<128;v=v+1) begin
  for(n=0;n<64;n=n+1) begin
   ld_en=1; ld_addr=n; {ld_re,ld_im}=inputs[v*64+n];
   clk_en=0; tick; clk_en=1; tick;
  end
  ld_en=0;
  run_fft(v%2);
  for(n=0;n<64;n=n+1) begin
   rd_en=1; rd_addr=n; tick;
   if({rd_re,rd_im} !== expected[v*64+n])
    $fatal(1,"golden mismatch v=%0d bin=%0d got=%h expected=%h",v,n,{rd_re,rd_im},expected[v*64+n]);
   checks=checks+1;
   clk_en=0; tick; clk_en=1;
  end
  rd_en=0;
 end
 $display("PASS FFT64 vectors=128 complex_bins=%0d latency=768 control=all_cycles data=valid_host_reads",checks);
 $finish;
end
initial begin #10000000; $fatal(1,"global timeout"); end
endmodule
