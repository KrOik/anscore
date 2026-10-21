`timescale 1ns/1ps
module tb_bayer_mode_latency;
 reg clk=0,rst=0,cv=0,sv=0,sof=0,eol=0,ready=0,rr=0;always #5 clk=~clk;
 reg [7:0] data=0;reg [15:0] id=0;reg [1:0] pattern=0;
 wire [1:0] cr,sr,mv,ms,me,mf,rv;wire [23:0] md[0:1];wire [15:0] mid[0:1],ow[0:1],oh[0:1];wire [3:0] error[0:1];
 genvar mode;
 generate for(mode=0;mode<2;mode=mode+1)begin:pair
  raw_bayer_mode_stream #(.RAW_BITS(8)) dut(clk,rst,cv,cr[mode],16'd7,16'd6,id,pattern,mode!=0,
  sv,sr[mode],data,sof,eol,mv[mode],ready,md[mode],ms[mode],me[mode],mf[mode],mid[mode],rv[mode],rr,error[mode],ow[mode],oh[mode]);
 end endgenerate
 reg [31:0] rng=32'h12345678;integer index=0,total=0,differences=0,expected;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ready=rng[2]||rng[5];end
 always @(posedge clk)if(rst)begin
  if(cr[0]!==cr[1]||sr[0]!==sr[1]||mv[0]!==mv[1]||rv[0]!==rv[1])$fatal(1,"bypass changed handshake cadence");
  if(rv[0]&&{error[0],ow[0],oh[0]}!=={error[1],ow[1],oh[1]})$fatal(1,"bypass changed response");
  if(cv&&cr[0])index=0;
  if(mv[0])begin
   if({ms[0],me[0],mf[0],mid[0]}!=={ms[1],me[1],mf[1],mid[1]})$fatal(1,"bypass changed marker timing");
   expected=(23*(1+index%5)+37*(1+index/5)+57*mid[1])&255;
   if(md[1]!=={3{expected[7:0]}})$fatal(1,"center bypass pixel");
   if(ready)begin index=index+1;total=total+1;if(md[0]!=md[1])differences=differences+1;end
  end
 end
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(integer f=0;f<4;f=f+1)begin
   @(negedge clk);cv=1;id=f;pattern=f;
   do @(posedge clk);while(!cr[0]);@(negedge clk);cv=0;
   for(integer y=0;y<6;y=y+1)for(integer x=0;x<7;x=x+1)begin
    sv=1;data=(23*x+37*y+57*f)&255;sof=x==0&&y==0;eol=x==6;
    do @(posedge clk);while(!sr[0]);@(negedge clk);sv=0;
   end
   do @(posedge clk);while(!rv[0]);@(negedge clk);rr=1;@(negedge clk);rr=0;
  end
  if(total!=80||differences==0)$fatal(1,"latency test did not exercise distinct Bayer/center data");
  $display("PASS Bayer normal/bypass cycle-equivalent ready/valid, markers and responses;80pixels");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
