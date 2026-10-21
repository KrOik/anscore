`timescale 1ns/1ps
module tb_csr_metrics_snapshot;
 parameter WORDS=51;
 reg clk=0,rst=0;always #5 clk=~clk;
 reg [WORDS*32-1:0] live=0,saved;
 reg v=0,w=0,rr=0;reg [7:0] addr=0;reg [31:0] data=0;reg [3:0] strobe=15;
 wire ready,rv,re;wire [31:0] rd;
 csr_metrics_snapshot #(.WORDS(WORDS)) dut(clk,rst,live,v,w,addr,data,strobe,ready,rv,re,rd,rr);
 integer t=0;
 always @(posedge clk)begin
  t<=t+1;
  for(integer i=0;i<WORDS;i=i+1)live[i*32+:32]<=32'h12340000+i*100+t;
 end
 task txn(input bit writing,input [7:0] address,input [31:0] value,input [3:0] mask,
          input bit expected_error,input [31:0] expected);
 begin
  @(negedge clk);v=1;w=writing;addr=address;data=value;strobe=mask;
  do @(posedge clk);while(!ready);
  if(writing&&address==0&&value==1&&mask==15)saved=live;
  @(negedge clk);v=0;
  repeat(3)begin
   if(!rv||re!==expected_error||rd!==expected)$fatal(1,"CSR mismatch address=%d got=%h error=%d",address,rd,re);
   // Adversarial request fields may change during a stalled response.
   addr=addr+7;data=~data;
   @(negedge clk);
  end
  rr=1;@(negedge clk);rr=0;
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;
  txn(0,16,0,15,1,0); // no snapshot yet
  txn(0,12,0,15,0,0);
  txn(1,0,1,7,1,0);
  txn(1,0,2,15,1,0);
  txn(1,16,1,15,1,0);
  txn(0,1,0,15,1,0);
  for(integer generation=1;generation<=2;generation=generation+1)begin
   txn(1,0,1,15,0,0);
   txn(0,0,0,15,0,generation);
   txn(0,12,0,15,0,1);
   for(integer i=0;i<WORDS;i=i+1)txn(0,16+i*4,0,15,0,saved[i*32+:32]);
   if(WORDS<60)txn(0,16+WORDS*4,0,15,1,0);
  end
  @(negedge clk);rst=0;@(negedge clk);rst=1;
  txn(0,0,0,15,0,0);txn(0,16,0,15,1,0);
  $display("PASS coherent CSR snapshot WORDS=%0d generations=2",WORDS);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
