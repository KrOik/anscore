`timescale 1ns/1ps
module tb_rmii_tx_errors;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,sv=0,keep=1,last=0,ack=0;reg[7:0] data=0;reg[95:0] user=0;
 wire ready,txen,done;wire[1:0] txd,error;wire[95:0] result_user;
 wire[31:0] frames,bytes;
 rmii_frame_tx dut(clk,rst,sv,ready,data,keep,last,user,txen,txd,done,ack,error,result_user,frames,bytes);
 integer testcase=0,j,index=0,dibit=0,idle_clocks=100;reg[7:0] captured=0;reg was_tx=0;
 always @(posedge clk)if(rst)begin
  if(txen)begin
   if(!was_tx)begin if(idle_clocks<48)$fatal(1,"IFG");index=0;dibit=0;end
   captured[dibit*2+:2]=txd;
   if(dibit==3)begin $display("WIRE_BYTE case=%0d index=%0d data=%0d",testcase,index,captured);index=index+1;dibit=0;end
   else dibit=dibit+1;
   idle_clocks=0;
  end else idle_clocks=idle_clocks+1;
  was_tx=txen;
 end
 task beat(input[7:0] d,input bit k,input bit l,input[95:0] u);
 begin
  @(negedge clk);sv=1;data=d;keep=k;last=l;user=u;
  do @(posedge clk);while(!ready);
  @(negedge clk);sv=0;
 end endtask
 task finish(input[1:0] expected);
 begin
  wait(done);if(error!==expected||txen)$fatal(1,"serializer error");
  repeat(8)begin @(negedge clk);if(!done||ready||txen||error!==expected)$fatal(1,"held result");end
  ack=1;@(negedge clk);ack=0;
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(j=0;j<60;j=j+1)beat((3+j*17)&255,1,j==59,0);finish(0);
  testcase=1;for(j=0;j<59;j=j+1)beat(j,1,j==58,1);finish(1);
  testcase=2;for(j=0;j<1515;j=j+1)beat(j,1,j==1514,2);finish(2);
  testcase=3;beat(0,0,1,3);finish(2);
  testcase=4;beat(0,1,0,4);beat(1,1,1,999);finish(2);
  testcase=5;beat(0,0,0,5);repeat(20)@(negedge clk);
  if(done||txen)$fatal(1,"did not drain malformed frame");beat(1,1,1,5);finish(2);
  if(frames!=1||bytes!=60)$fatal(1,"bad frames transmitted");
  testcase=6;beat(9,1,0,6);repeat(5)@(negedge clk);rst=0;@(negedge clk);rst=1;
  if(txen||done)$fatal(1,"reset ownership");
  testcase=7;for(j=0;j<64;j=j+1)beat((7+j*17)&255,1,j==63,7);finish(0);
  if(frames!=1||bytes!=64)$fatal(1,"reset recovery counters");
  $display("PASS RMII serializer 5rejects/drain/reset/recovery/heldcompletion");$finish;
 end
 initial begin #3000000;$fatal(1,"serializer timeout");end
endmodule
