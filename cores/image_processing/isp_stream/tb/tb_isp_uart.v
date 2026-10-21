`timescale 1ns/1ps
module tb_isp_uart;
 reg clk=0,rx=1;always #5 clk=~clk;
 wire tx;wire [7:0] probe;
 isp_top #(.BIT_CYCLES(8)) dut(clk,rx,tx,probe);
 wire [7:0] received;wire received_valid,framing;
 sys_uart_rx #(.BIT_CYCLES(8)) monitor(clk,dut.rst_n,tx,received,received_valid,framing);
 reg [63:0] reply;integer count=0;
 always @(posedge clk)if(received_valid)begin
  if(count>=8)$fatal(1,"extra UART response");
  reply[count*8+:8]=received;count=count+1;
 end
 function [7:0] crc_byte(input [7:0] previous,input [7:0] value);
 reg [7:0] x;integer b;
 begin x=previous^value;for(b=0;b<8;b=b+1)x=x[7]?(x<<1)^8'h07:x<<1;crc_byte=x;end
 endfunction
 task send_byte(input [7:0] value);
 begin
  @(negedge clk);rx=0;repeat(8)@(negedge clk);
  for(integer b=0;b<8;b=b+1)begin rx=value[b];repeat(8)@(negedge clk);end
  rx=1;repeat(8)@(negedge clk);
 end endtask
 task command(input bit writing,input [7:0] address,input [31:0] value,input [31:0] expected,input bit expected_error);
 reg [55:0] body;reg [7:0] crc;
 begin
  count=0;reply=0;body={value,address,7'd0,writing,8'ha5};crc=0;
  for(integer b=0;b<7;b=b+1)begin send_byte(body[b*8+:8]);crc=crc_byte(crc,body[b*8+:8]);end
  send_byte(crc);wait(count==8);@(negedge clk);
  crc=0;for(integer b=0;b<7;b=b+1)crc=crc_byte(crc,reply[b*8+:8]);
  if(reply[7:0]!=8'h5a||reply[15:8]!={7'd0,expected_error}||reply[23:16]!=address||reply[55:24]!==expected||reply[63:56]!=crc)
   $fatal(1,"UART command/reply mismatch addr=%h reply=%h",address,reply);
  repeat(16)@(negedge clk);
 end endtask
 reg [31:0] config_words[0:15];
 initial begin
  wait(dut.rst_n);repeat(10)@(negedge clk);
  command(0,8,0,32'h49535031,0);
  command(0,8'hc0,0,0,1);
  for(integer i=0;i<16;i=i+1)config_words[i]=0;
  config_words[0]={16'd7,16'd7};config_words[1]=1;config_words[2]=1000;config_words[3]=71;config_words[4]=4;
  config_words[8]={16'd256,16'd256};config_words[9]=256;
  config_words[10]=1024;config_words[12]=1024;config_words[14]=1024;
  for(integer i=0;i<16;i=i+1)command(1,32+i*4,config_words[i],0,0);
  command(1,4,1,0,0);
  repeat(1000)@(negedge clk);
  command(1,12,1,0,0);
  command(0,8'hc0,0,3,0);command(0,8'hc4,0,1,0);
  command(0,8'hd8,0,9,0);command(0,8'hdc,0,1,0);
  command(0,8'he0,0,32'hb6c9cb0b,0);
  command(1,28,3,0,0);command(0,28,0,3,0);
  command(1,8'hfc,1,0,1);
  $display("PASS ISP board bit-serial UART configuration, run, CRC and snapshot readback");$finish;
 end
 initial begin #5000000;$fatal(1,"UART timeout");end
endmodule
