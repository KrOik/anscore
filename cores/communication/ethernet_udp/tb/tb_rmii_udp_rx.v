`timescale 1ns/1ps
module tb_rmii_udp_rx;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,mr=0,crs=0;reg[1:0] rxd=0;
 wire[31:0] rg,rb,ro,frames,bytes;
 wire mv,mk,ml;wire[7:0] md;wire[95:0] mu;
 wire[31:0] sip,good,bh,bi,bu;wire[15:0] sport;
 rmii_udp_receiver receiver(clk,rst,crs,rxd,mv,mr,md,mk,ml,mu,sip,sport,
  rg,rb,ro,frames,bytes,good,bh,bi,bu);
 reg[31:0] fixture[0:32767];reg[2047:0] filename;
 reg[31:0] rng=32'h7a35c281;
 integer cursor=0,testcase=0,n,length,cases,outputs=0;
 reg[31:0] crc;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);
 reg[31:0] x;integer j;
 begin x=c;for(j=0;j<8;j=j+1)x=(x[0]^b[j])?(x>>1)^32'hedb88320:x>>1;crcbyte=x;end endfunction
 task sendbyte(input[7:0] b);integer j;
 begin for(j=0;j<4;j=j+1)begin @(negedge clk);crs=1;rxd=b>>(2*j);end end endtask
 reg stalled=0;reg[153:0] held;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[2:0]!=0;end
 always @(posedge clk)if(rst)begin
  if(stalled&&(!mv||{md,mk,ml,mu,sip,sport}!==held))$fatal(1,"UDP output changed under stall");
  stalled=mv&&!mr;held={md,mk,ml,mu,sip,sport};
  if(mv&&mr)begin
   if(mu[31:0]!=testcase||sip!=32'hc0a88901||sport!=9000)$fatal(1,"UDP metadata/source");
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
   repeat(48)@(negedge clk);
   repeat(7)sendbyte(8'h55);sendbyte(8'hd5);crc=32'hffffffff;
   for(n=0;n<length;n=n+1)begin
    sendbyte(fixture[cursor]);crc=crcbyte(crc,fixture[cursor]);cursor=cursor+1;
   end
   crc=~crc;if(testcase==cases-1)crc=crc^1;
   for(n=0;n<4;n=n+1)sendbyte(crc>>(8*n));
   @(negedge clk);crs=0;rxd=0;
   // Drain both ownership stages before the next independent packet.
   repeat(2)@(negedge clk);
   wait(receiver.frontend.pending==0&&receiver.frontend.state==0&&receiver.ready&&!mv);
   repeat(3)@(negedge clk);
  end
  $display("UDP_COUNTS good=%0d header=%0d ip=%0d udp=%0d",good,bh,bi,bu);
  if(rg!=13||rb!=2||ro!=0)$fatal(1,"RMII counters");
  $display("PASS RMII UDP payload receiver");$finish;
 end
 initial begin #10000000;$fatal(1,"UDP timeout");end
endmodule
