`timescale 1ns/1ps
module tb_motor_uart;
 reg clk=0,rx=1;always #5 clk=~clk;
 wire tx;wire [7:0] probe;
 motor_top #(.BIT_CYCLES(8)) dut(clk,rx,tx,probe);
 wire [7:0] received;wire received_valid,framing;
 sys_uart_rx #(.BIT_CYCLES(8)) monitor(clk,dut.rst_n,tx,received,received_valid,framing);
 reg [63:0] reply;integer count=0;reg [31:0] read_value;
 always @(posedge clk)if(received_valid)begin
  if(count>=8)$fatal(1,"extra motor UART reply");
  reply[count*8+:8]=received;count=count+1;
 end
 function [7:0] crc_byte(input [7:0] previous,input [7:0] value);
 reg [7:0] x;integer b;
 begin x=previous^value;for(b=0;b<8;b=b+1)x=x[7]?(x<<1)^8'h07:x<<1;crc_byte=x;end endfunction
 task send_byte(input [7:0] value);
 begin
  @(negedge clk);rx=0;repeat(8)@(negedge clk);
  for(integer b=0;b<8;b=b+1)begin rx=value[b];repeat(8)@(negedge clk);end
  rx=1;repeat(8)@(negedge clk);
 end endtask
 task command(input bit writing,input [7:0] address,input [31:0] value,input bit expected_error);
 reg [55:0] body;reg [7:0] crc;
 begin
  count=0;reply=0;body={value,address,7'd0,writing,8'ha5};crc=0;
  for(integer b=0;b<7;b=b+1)begin send_byte(body[b*8+:8]);crc=crc_byte(crc,body[b*8+:8]);end
  send_byte(crc);wait(count==8);@(negedge clk);
  crc=0;for(integer b=0;b<7;b=b+1)crc=crc_byte(crc,reply[b*8+:8]);
  if(reply[7:0]!=8'h5a||reply[15:8]!={7'd0,expected_error}||reply[23:16]!=address||reply[63:56]!=crc)
   $fatal(1,"motor UART frame addr=%h reply=%h",address,reply);
  read_value=reply[55:24];repeat(16)@(negedge clk);
 end endtask
 integer i,n;
 initial begin
  wait(dut.rst_n);repeat(10)@(negedge clk);
  command(0,0,0,0);if(read_value!=32'h464f4331)$fatal(1,"UART ID");
  command(0,8,0,0);if(read_value!=32'h9abcdef0)$fatal(1,"UART fingerprint");
  command(0,12,0,0);if(read_value!=32'h12345678)$fatal(1,"UART fingerprint high");
  command(0,128,0,1);command(1,16,2,1);command(1,64,256,0);
  for(n=0;n<3;n=n+1)begin
   command(1,120,n,0);command(1,92,n==1?80:n==2?-40:0,0);
   command(1,96,n==1?-60:n==2?60:0,0);command(1,16,1,0);
   command(1,120,999,1);
   command(0,4,0,0);if(!read_value[1])$fatal(1,"UART missing result");
   for(i=0;i<12;i=i+1)begin command(0,128+4*i,0,0);$display("UART_MOTOR %0d %0d %0d",n,i,$signed(read_value));end
   command(1,16,2,0);command(0,128,0,1);
  end
  $display("PASS motor physical-top UART framing/three numerical commands/ACK/errors");$finish;
 end
 initial begin #20000000;$fatal(1,"UART motor timeout");end
endmodule
