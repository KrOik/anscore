`timescale 1ns/1ps
module tb_lockin_uart;
 reg clk=0,rx=1;always #5 clk=~clk;
 wire tx;wire [7:0] probe;
 lockin_top #(.BIT_CYCLES(8)) dut(clk,rx,tx,probe);
 wire [7:0] received;wire received_valid,framing;
 sys_uart_rx #(.BIT_CYCLES(8)) monitor(clk,dut.rst_n,tx,received,received_valid,framing);
 reg [63:0] reply;integer count=0;reg [31:0] read_value;
 always @(posedge clk)if(received_valid)begin
  if(count>=8)$fatal(1,"extra lock-in UART reply");
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
   $fatal(1,"lock-in UART frame addr=%h reply=%h",address,reply);
  read_value=reply[55:24];repeat(16)@(negedge clk);
 end endtask
 reg[31:0] status,low;reg[63:0] first,last,previous_last=0;integer run,lane;
 task put(input[3:0] n,input[31:0] d);begin command(1,8'h40+n*4,d,0);end endtask
 task wait_done;begin
  status=0;
  while(!status[1])begin command(0,4,0,0);status=read_value;end
 end endtask
 initial begin
  wait(dut.rst_n);repeat(10)@(negedge clk);
  command(0,0,0,0);if(read_value!=32'h4c4f434b)$fatal(1,"magic");
  command(0,20,0,0);if(read_value!=32'h9abcdef0)$fatal(1,"build");
  command(0,8'h80,0,1);command(1,16,1,1);command(0,1,0,1);command(1,0,0,1);
  put(0,32'h01000000);put(1,4);put(2,8);put(3,100);put(4,10000);
  put(5,{16'd4000,16'd1000});put(6,{16'd24000,16'd12000});
  put(7,{8'd96,8'd192,8'd32,8'd0});put(8,0);put(9,0);
  put(10,32'h80008000);put(11,32'h80008000);put(12,0);
  command(1,12,1,0);
  // Queue an operation during the active measurement.
  put(3,101);command(1,12,1,0);command(1,8'h4c,102,1);
  command(1,12,1,1);
  for(run=100;run<=101;run=run+1)begin
   wait_done;
   command(0,8'h80,0,0);if(read_value!=run)$fatal(1,"queued id");
   command(0,8'h84,0,0);if(read_value)$fatal(1,"measurement error");
   command(0,8'h90,0,0);if(read_value!=256)$fatal(1,"accepted count");
   command(0,8'h98,0,0);low=read_value;command(0,8'h9c,0,0);first={read_value,low};
   command(0,8'ha0,0,0);low=read_value;command(0,8'ha4,0,0);last={read_value,low};
   if(last-first!=1020||first<=previous_last)$fatal(1,"CSR timestamps");
   previous_last=last;
   for(lane=0;lane<4;lane=lane+1)begin
    command(0,8'hb0+lane*12,0,0);
    $display("CSR_IQ run=%0d lane=%0d i=%0d q=%0d",run,lane,$signed(read_value[15:0]),$signed(read_value[31:16]));
    command(0,8'hb4+lane*12,0,0);low=read_value;
    command(0,8'hb8+lane*12,0,0);
    $display("CSR_POLAR run=%0d lane=%0d amplitude=%0d phase=%0d",run,lane,low,$signed(read_value));
   end
   command(0,8'h80,0,0);if(read_value!=run)$fatal(1,"result changed before ack");
   command(1,16,1,0);
  end
  command(0,8'h80,0,1);
  put(3,102);put(4,0);command(1,12,1,0);wait_done;
  command(0,8'h84,0,0);if(read_value!=128)$fatal(1,"timeout error");
  command(0,8'hb0,0,0);if(read_value)$fatal(1,"failed data");
  command(1,16,1,0);command(0,8,0,0);if(read_value!=3)$fatal(1,"version/duplicate launch");
  $display("PASS lock-in UART atomic queue/results/errors/ack");$finish;
 end
 initial begin #30000000;$fatal(1,"CSR timeout");end
endmodule
