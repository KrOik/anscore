`timescale 1ns/1ps
module tb_udp_uart;
 integer run,lane;reg[31:0] status;
 reg clk=0,rx=1;always #5 clk=~clk;
 wire tx;wire [7:0] probe;
 udp_top #(.BIT_CYCLES(8)) dut(clk,rx,tx,probe);
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
  read_value=reply[55:24];if(!writing&&!expected_error&&address>=128)$display("CSR_WORD run=%0d address=%0d value=%0d",run,address,read_value);repeat(16)@(negedge clk);
 end endtask
 task put(input[2:0] n,input[31:0] d);begin command(1,8'h40+n*4,d,0);end endtask
 task wait_done;begin
  status=0;while(!status[1])begin command(0,4,0,0);status=read_value;end
 end endtask
 initial begin
  wait(dut.rst_n);repeat(10)@(negedge clk);
  command(0,0,0,0);if(read_value!=32'h55445031)$fatal(1,"CSR identity");
  command(0,20,0,0);if(read_value!=32'h9abcdef0)$fatal(1,"build ID");
  command(0,8'h80,0,1);command(1,16,1,1);command(0,1,0,1);command(1,0,0,1);
  put(0,{16'd37,16'd3});put(1,32'h12345678);
  put(2,200000);put(3,0);put(4,100);command(1,12,1,0);
  put(0,{16'd7,16'd2});put(1,32'h87654321);put(4,101);command(1,12,1,0);
  command(1,8'h50,999,1);command(1,12,1,1);
  command(0,8'h40,0,0);if(read_value!={16'd37,16'd3})$fatal(1,"active config changed while busy");
  for(run=100;run<=101;run=run+1)begin
   wait_done;
   command(0,8'h80,0,0);if(read_value!=run)$fatal(1,"result ID");
   command(0,8'h84,0,0);if(read_value)$fatal(1,"replay error");
   command(0,8'h88,0,0);
   for(lane=0;lane<6;lane=lane+1)command(0,8'h8c+lane*4,0,0);
   command(0,8'h80,0,0);if(read_value!=run)$fatal(1,"result coherence");
   command(1,16,1,0);
  end
  command(0,8'h80,0,1);
  put(2,0);put(4,102);command(1,12,1,0);wait_done;
  command(0,8'h84,0,0);if(read_value!=1)$fatal(1,"invalid timeout");
  command(0,8'h94,0,0);if(read_value)$fatal(1,"invalid command has bytes");
  command(1,16,1,0);command(0,8,0,0);if(read_value!=3)$fatal(1,"version");
  $display("PASS UDP UART atomic queue/byte strobes/held responses/results/errors/ACK");$finish;
 end
 initial begin #30000000;$fatal(1,"CSR timeout");end
endmodule
