`timescale 1ns/1ps
module tb_buffer_dma_uart;
 reg clk=0,rx=1;always #5 clk=~clk;
 wire tx;wire [7:0] probe;
 buffer_dma_top #(.BIT_CYCLES(8),.FRAME_COUNT(4)) dut(clk,rx,tx,probe);
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
 initial begin
  wait(dut.rst_n);repeat(10)@(negedge clk);
  command(0,8'hfc,0,32'h42444631,0);
  command(1,8'he4,32'habcdef01,0,0);
  command(0,8'he4,0,32'habcdef01,0);
  command(1,8'he0,1,0,0);wait(probe[7]);
  command(0,8'he0,0,3,0);command(0,8'hf0,0,20,0);
  command(1,0,1,0,0);command(0,16,0,8,0);
  command(0,20,0,8,0);command(1,8'hfc,1,0,1);
  $display("PASS board UART serial control, selftest and coherent snapshot readback");$finish;
 end
 initial begin #5000000;$fatal(1,"UART timeout");end
endmodule
