`timescale 1ns/1ps
module tb_encoder_feedback;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,qa=0,qb=0,idx=0,ir=0,sample=0,clear=0;
wire [31:0] count,il,seq,invalid;wire dir,step,ie,sv,vv,error;
wire signed [31:0] pos,velocity;wire [63:0] timestamp;
encoder_feedback dut(clk,rst_n,qa,qb,idx,ir,sample,clear,count,il,dir,step,ie,sv,vv,pos,velocity,timestamp,seq,error,invalid);
integer n,state=0;reg [1:0] ab;
always @(posedge clk)if(rst_n)begin
 #1;$display("QEI %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",qa,qb,idx,ir,sample,clear,count,il,dir,step,ie,sv,vv,pos,velocity,timestamp,seq,error,invalid);
end
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 for(n=0;n<1000;n=n+1)begin
  sample=n%11==0;idx=n>=160&&n<166||n>=400&&n<407;ir=n>=350;
  clear=n==800;
  if(n<300&&n%4==0)state=(state+1)%4;
  else if(n>=300&&n<600&&n%4==0)state=(state+3)%4;
  case(state)0:ab=0;1:ab=2;2:ab=3;3:ab=1;endcase
  if(n>=600&&n<620)ab=(n/4)%2==0?0:3;
  if(n>=620)ab=0;
  {qa,qb}=ab;@(negedge clk);
 end
 $display("PASS encoder feedback");$finish;
end
endmodule
