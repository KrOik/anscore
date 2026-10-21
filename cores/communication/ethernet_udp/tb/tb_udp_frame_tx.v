`timescale 1ns/1ps
module tb_udp_frame_tx;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,cv=0,sv=0,keep=1,last=0,mr=0,dr=0;
 reg[7:0] sd=0;reg[15:0] length=0;reg[95:0] user=0;
 wire cr,sr,mv,mk,ml,dv;wire[7:0] md;wire[95:0] mu;wire[1:0] error;
 udp_frame_tx dut(clk,rst,cv,cr,48'h84ba591684c2,32'hc0a88901,16'd11452,16'd9000,
  length,16'h1234,user,sv,sr,sd,keep,last,mv,mr,md,mk,ml,mu,dv,dr,error);
 reg[31:0] rng=32'hda7b9e01;integer testcase=0,index=0,n,size;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[2:0]!=0;end
 reg stalled=0;reg[105:0] held;
 always @(posedge clk)if(rst)begin
  if(stalled&&(!mv||{md,mk,ml,mu}!==held))$fatal(1,"TX stalled output");
  stalled=mv&&!mr;held={md,mk,ml,mu};
  if(mv&&mr)begin
   if(mu!=testcase||!mk)$fatal(1,"TX metadata");
   $display("TX_BYTE case=%0d index=%0d data=%0d last=%0d",testcase,index,md,ml);
   if(ml)index=0;else index=index+1;
  end
 end
 task command(input integer len);
 begin
  @(negedge clk);length=len;user=testcase;cv=1;
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;length=999;user=999;
 end endtask
 task beat(input[7:0] b,input bit k,input bit l);
 begin
  repeat(rng[1:0])@(negedge clk);
  @(negedge clk);sv=1;sd=b;keep=k;last=l;
  do @(posedge clk);while(!sr);
  @(negedge clk);sv=0;
 end endtask
 task completion(input[1:0] expected_error);
 begin
  wait(dv);if(error!==expected_error)$fatal(1,"TX error");
  repeat(7)begin @(negedge clk);if(!dv||error!==expected_error||cr||mv)$fatal(1,"TX held completion");end
  dr=1;@(negedge clk);dr=0;
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(testcase=0;testcase<6;testcase=testcase+1)begin
   case(testcase)0:size=0;1:size=1;2:size=2;3:size=7;4:size=63;5:size=1472;endcase
   command(size);
   for(n=0;n<size;n=n+1)beat((n*29+size)&255,1,n==size-1);
   completion(0);
  end
  command(1473);completion(1);
  command(2);beat(9,1,1);completion(2);
  command(1);beat(9,1,0);beat(0,1,1);completion(2);
  command(1);beat(9,0,1);completion(2);
  $display("PASS UDP frame TX lengths/checksums/padding/stalls/inputerrors/heldcompletion");$finish;
 end
 initial begin #3000000;$fatal(1,"TX timeout");end
endmodule
