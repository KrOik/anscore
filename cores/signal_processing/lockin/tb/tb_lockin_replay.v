`timescale 1ns/1ps
module tb_lockin_replay;
 parameter SIN_FILE="",COS_FILE="";
 reg clk=0,rst=0,cv=0,mr=0,allow=1;
 reg [31:0] tuning=32'h01000000,period=4,id=0,timeout=10000;
 reg [3:0] log2=8;
 wire cr,mv;wire [63:0] oi,oq,amp,first,last;wire [71:0] phase;
 wire [31:0] oid,cycles,generated,accepted,dropped;wire [7:0] error;
 lockin_replay #(.SIN_FILE(SIN_FILE),.COS_FILE(COS_FILE)) dut(clk,rst,cv,cr,tuning,period,id,timeout,log2,
  {16'd24000,16'd12000,16'd4000,16'd1000},64'd0,{4{16'd32768}},{8'd96,8'd192,8'd32,8'd0},allow,
  mv,mr,oi,oq,amp,phase,first,last,oid,cycles,generated,accepted,dropped,error);
 always #5 clk=~clk;
 task command(input integer run);
 begin
  @(negedge clk);id=run;cv=1;
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;id=999;
 end endtask
 reg [255:0] normal_values;reg [71:0] normal_phase;reg [63:0] previous_last=0;
 task response(input integer run,input [7:0] expected_error);
 reg [583:0] held;
 begin
  wait(mv);held={oi,oq,amp,phase,first,last,oid,cycles,generated,accepted,dropped,error};
  if(error!==expected_error||oid!=run)$fatal(1,"replay error/id %0d/%0d vs%0d/%0d",error,oid,expected_error,run);
  if(error==0)begin
   if(generated!=256||accepted!=256||dropped!=0||last-first!=255*4||first<=previous_last)$fatal(1,"replay accounting/time epoch");
   if(run==0)begin normal_values={64'd0,oi,oq,amp};normal_phase=phase;end
   else if({64'd0,oi,oq,amp}!==normal_values||phase!==normal_phase)$fatal(1,"recovery differs from clean run");
   previous_last=last;
   for(integer lane=0;lane<4;lane=lane+1)$display("REPLAY_RESULT run=%0d lane=%0d i=%0d q=%0d amplitude=%0d phase=%0d first=%0d last=%0d",
    run,lane,$signed(oi[lane*16+:16]),$signed(oq[lane*16+:16]),amp[lane*16+:16],$signed(phase[lane*18+:18]),first,last);
  end else begin
   if({oi,oq,amp,phase,first,last}!==0)$fatal(1,"failed replay leaked partial result");
   if(run==1&&(dropped==0||accepted!=0||cycles>20))$fatal(1,"overflow not bounded/accounted");
   if(run==3&&cycles!=10)$fatal(1,"timeout not exact");
  end
  repeat(13)begin @(negedge clk);if(!mv||{oi,oq,amp,phase,first,last,oid,cycles,generated,accepted,dropped,error}!==held||cr)$fatal(1,"held replay response");end
  $display("REPLAY_DONE run=%0d error=%0d cycles=%0d generated=%0d accepted=%0d dropped=%0d",run,error,cycles,generated,accepted,dropped);
  mr=1;@(negedge clk);mr=0;
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  command(0);response(0,0);
  allow=0;command(1);response(1,64);
  allow=1;command(2);response(2,0);
  period=16;timeout=10;command(3);response(3,128);
  period=4;timeout=10000;command(4);response(4,0);
  period=3;command(5);response(5,32);
  period=4;command(6);response(6,0);
  log2=0;command(7);response(7,48);
  log2=8;timeout=0;command(8);response(8,128);
  timeout=10000;command(9);repeat(20)@(negedge clk);rst=0;@(negedge clk);rst=1;previous_last=0;
  command(10);response(10,0);
  $display("PASS replay finiteabort/overflow/timeout/invalid/reset,clean recovery and continuous epoch");$finish;
 end
 initial begin #1000000;$fatal(1,"replay timeout");end
endmodule
