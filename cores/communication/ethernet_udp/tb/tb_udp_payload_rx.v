`timescale 1ns/1ps
module tb_udp_payload_rx;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,sv=0,sk=1,sl=0,mr=0;reg[7:0] sd=0;reg[95:0] su=0;
 wire sr,mv,mk,ml;wire[7:0] md;wire[95:0] mu;
 wire[31:0] sip,good,bh,bi,bu;wire[15:0] sport;
 udp_payload_rx dut(clk,rst,sv,sr,sd,sk,sl,su,mv,mr,md,mk,ml,mu,sip,sport,good,bh,bi,bu);
 reg[31:0] fixture[0:32767];reg[2047:0] filename;
 reg[31:0] rng=32'h7a35c281;
 integer cursor=0,testcase=0,n,length,cases,outputs=0;
 reg stalled=0;reg[153:0] held;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[2:0]!=0;end
 always @(posedge clk)if(rst)begin
  if(stalled&&(!mv||{md,mk,ml,mu,sip,sport}!==held))$fatal(1,"UDP output changed under stall");
  stalled=mv&&!mr;held={md,mk,ml,mu,sip,sport};
  if(mv&&mr)begin
   if(mu!=testcase||sip!=32'hc0a88901||sport!=9000)$fatal(1,"UDP metadata/source");
   $display("UDP_BYTE case=%0d data=%0d keep=%0d last=%0d",testcase,md,mk,ml);
   outputs=outputs+1;
  end
 end
 initial begin
  if(!$value$plusargs("fixture=%s",filename))$fatal(1,"fixture missing");
  $readmemh(filename,fixture);cases=fixture[0];cursor=1;
  repeat(5)@(negedge clk);rst=1;
  for(testcase=0;testcase<cases;testcase=testcase+1)begin
   length=fixture[cursor];cursor=cursor+1;
   for(n=0;n<length;n=n+1)begin
    repeat(rng[1:0])@(negedge clk);
    @(negedge clk);sv=1;sd=fixture[cursor];sk=1;sl=n==length-1;su=testcase;
    do @(posedge clk);while(!sr);
    @(negedge clk);sv=0;cursor=cursor+1;
   end
   @(posedge clk);#1;wait(sr);repeat(3)@(negedge clk);
  end
  $display("UDP_COUNTS good=%0d header=%0d ip=%0d udp=%0d",good,bh,bi,bu);
  $display("PASS UDP payload receiver");$finish;
 end
 initial begin #3000000;$fatal(1,"UDP timeout");end
endmodule
