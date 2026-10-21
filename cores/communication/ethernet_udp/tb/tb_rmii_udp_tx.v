`timescale 1ns/1ps
module tb_rmii_udp_tx;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,cv=0,sv=0,keep=1,last=0,dr=0;
 reg[7:0] sd=0;reg[15:0] length=0;reg[95:0] user=0;
 wire cr,sr,dv;wire[7:0] md;wire[95:0] mu;wire[2:0] error;
 reg[31:0] rng=32'hda7b9e01;integer testcase=0,index=0,n,size;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};end
 wire txen,tdone;wire[1:0] txd,terror;wire[95:0] tuser;
 wire[31:0] frames,bytes;
 rmii_udp_transmitter dut(clk,rst,cv,cr,48'h84ba591684c2,32'hc0a88901,16'd11452,16'd9000,
  length,16'h1234,user,sv,sr,sd,keep,last,txen,txd,dv,dr,error,tuser,frames,bytes);
 reg[7:0] captured=0;integer dibit=0,wire_index=0,idle_clocks=100;
 reg was_tx=0;
 always @(posedge clk)if(rst)begin
  if(txen)begin
   if(!was_tx)begin if(idle_clocks<48)$fatal(1,"short IFG");wire_index=0;dibit=0;end
   captured[dibit*2+:2]=txd;
   if(dibit==3)begin
    $display("WIRE_BYTE case=%0d index=%0d data=%0d",testcase,wire_index,captured);
    wire_index=wire_index+1;dibit=0;
   end else dibit=dibit+1;
   idle_clocks=0;
  end else begin
   idle_clocks=idle_clocks+1;
   if(was_tx&&dibit!=0)$fatal(1,"partial RMII byte");
  end
  was_tx=txen;
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
  wait(dv);if(expected_error==0)begin if(tuser!=testcase)$fatal(1,"serializer completion");end
  if(error!==expected_error)$fatal(1,"TX error");
  repeat(7)begin @(negedge clk);if(!dv||error!==expected_error||cr||txen)$fatal(1,"TX held completion");end
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
  $display("PASS RMII UDP TX lengths/checksums/padding/stalls/inputerrors/heldcompletion");$finish;
 end
 initial begin #3000000;$fatal(1,"TX timeout");end
endmodule
