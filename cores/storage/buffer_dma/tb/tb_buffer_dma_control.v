`timescale 1ns/1ps
module tb_buffer_dma_control;
 reg clk=0,rst=0,v=0,w=0,rr=0;always #5 clk=~clk;
 reg [7:0] addr=0;reg [31:0] data=0;reg [3:0] mask=15;
 wire ready,rv,re;wire [31:0] rd;wire [7:0] probe;
 buffer_dma_control #(.FRAME_COUNT(4),.SLOT_WORDS(16)) dut(clk,rst,v,w,addr,data,mask,ready,rv,re,rd,rr,probe);
 task txn(input bit writing,input [7:0] address,input [31:0] value,input bit err,input [31:0] expected);
 begin
  @(negedge clk);v=1;w=writing;addr=address;data=value;
  do @(posedge clk);while(!ready);
  @(negedge clk);v=0;
  wait(rv);
  repeat(4)begin
   if(re!==err||rd!==expected)$fatal(1,"control response mismatch %h data=%h err=%b",address,rd,re);
   // Response route and content must not follow the changing address.
   addr=addr^8'hfc;@(negedge clk);
  end
  rr=1;@(negedge clk);rr=0;
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  txn(0,8'hfc,0,0,32'h42444631);
  txn(0,8'he0,0,0,1);
  txn(1,8'he4,32'h12345678,0,0);txn(0,8'he4,0,0,32'h12345678);
  txn(1,8'he8,2,1,0);txn(1,8'hf0,1,1,0);
  mask=7;txn(1,8'he0,1,1,0);mask=15;
  txn(1,8'he0,1,0,0);
  txn(1,8'he0,1,1,0);txn(1,8'he4,0,1,0);txn(1,8'he8,0,1,0);
  wait(probe[7]);txn(0,8'he0,0,0,3);txn(0,8'hf0,0,0,20);txn(0,8'hf4,0,0,0);
  txn(1,0,1,0,0);txn(0,16,0,0,8);txn(0,20,0,0,8);
  txn(1,8'he8,0,0,0);txn(1,8'he0,1,0,0);
  wait(!probe[7]);wait(probe[7]);txn(0,8'hf0,0,0,20);
  txn(0,16,0,1,0); // previous snapshot invalidated by restart
  $display("PASS control CSR routing, stalls, config guards, run/restart and snapshot reset");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
