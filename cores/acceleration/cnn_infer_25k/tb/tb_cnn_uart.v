`timescale 1ns/1ps
module tb_cnn_uart;
 reg clk=0,rx=1;always #5 clk=~clk;
 wire tx;wire [7:0] probe;
 cnn_top #(.BIT_CYCLES(8)) dut(clk,rx,tx,probe);
 wire [7:0] received;wire received_valid,framing;
 sys_uart_rx #(.BIT_CYCLES(8)) monitor(clk,dut.rst_n,tx,received,received_valid,framing);
 reg [63:0] reply;integer count=0;reg [31:0] read_value;
 always @(posedge clk)if(received_valid)begin
  if(count>=8)$fatal(1,"extra CNN UART reply");
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
   $fatal(1,"CNN UART frame addr=%h reply=%h",address,reply);
  read_value=reply[55:24];repeat(16)@(negedge clk);
 end endtask
 reg [7:0] w1[0:35],w2[0:287],wf[0:3919],pixels[0:783];
 reg [31:0] b1[0:3],b2[0:7],bf[0:9];
 reg [2047:0] directory;integer i;
 initial begin
  if(!$value$plusargs("memdir=%s",directory))$fatal(1,"missing memories");
  $readmemh({directory,"/conv1.mem"},w1);$readmemh({directory,"/conv2.mem"},w2);$readmemh({directory,"/dense.mem"},wf);
  $readmemh({directory,"/bias1.mem"},b1);$readmemh({directory,"/bias2.mem"},b2);$readmemh({directory,"/bias3.mem"},bf);
  $readmemh({directory,"/ramp_input.mem"},pixels);
  wait(dut.rst_n);repeat(10)@(negedge clk);
  command(0,0,0,0);if(read_value!=32'h434e4e31)$fatal(1,"UART ID");
  command(0,48,0,0);if(read_value!=32'h12345678)$fatal(1,"UART fingerprint low");
  command(0,52,0,0);if(read_value!=32'h2505abcd)$fatal(1,"UART fingerprint high");
  command(0,40,0,1);command(1,8,1,0);
  for(i=0;i<36;i=i+1)command(1,16,w1[i],0);
  for(i=0;i<288;i=i+1)command(1,16,w2[i],0);
  for(i=0;i<3920;i=i+1)command(1,16,wf[i],0);
  command(1,8,2,0);
  for(i=0;i<4;i=i+1)command(1,16,b1[i],0);
  for(i=0;i<8;i=i+1)command(1,16,b2[i],0);
  for(i=0;i<10;i=i+1)command(1,16,bf[i],0);
  command(1,8,0,0);for(i=0;i<784;i=i+1)command(1,16,pixels[i],0);
  command(1,20,1,0);repeat(400000)@(negedge clk);
  command(0,4,0,0);if(read_value!=4)$fatal(1,"UART run status");
  command(0,28,0,0);if(read_value!=10597)$fatal(1,"UART trace count");
  command(1,36,10584,0);
  for(i=0;i<13;i=i+1)begin command(0,40,0,0);$display("UART_CNN_RESULT index=%0d value=%0d",i,$signed(read_value));end
  command(1,20,2,0);command(0,40,0,1);
  $display("PASS complete CNN physical-top bit-serial simulation loading/inference/scores/Top3");$finish;
 end
 initial begin #200000000;$fatal(1,"UART CNN timeout");end
endmodule
