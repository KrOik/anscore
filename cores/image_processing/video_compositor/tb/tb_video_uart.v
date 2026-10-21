`timescale 1ns/1ps
module tb_video_uart;
 integer run,lane;reg[31:0] status;
 reg clk=0,rx=1;always #5 clk=~clk;
 wire tx;wire [7:0] probe;
 video_top #(.BIT_CYCLES(8)) dut(clk,rx,tx,probe);
 wire [7:0] received;wire received_valid,framing;
 sys_uart_rx #(.BIT_CYCLES(8)) monitor(clk,dut.rst_n,tx,received,received_valid,framing);
 reg [63:0] reply;integer count=0;reg [31:0] read_value;
 always @(posedge clk)if(received_valid)begin
  if(count>=8)$fatal(1,"extra video UART reply");
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
   $fatal(1,"video UART frame addr=%h reply=%h",address,reply);
  read_value=reply[55:24];if(!writing&&!expected_error&&address>=128)$display("CSR_WORD run=%0d address=%0d value=%0d",run,address,read_value);repeat(16)@(negedge clk);
 end endtask

 integer g,n;reg [31:0] f,c,p,e,v;
 task snapshot(input integer lane,input integer epoch);
 begin
  command(1,8'hfc,0,0);
  command(0,8'h40+lane*32,0,0);f=read_value;
  command(0,8'h44+lane*32,0,0);c=read_value;
  command(0,8'h48+lane*32,0,0);p=read_value;
  command(0,8'h4c+lane*32,0,0);e=read_value;
  command(0,8'h50+lane*32,0,0);v=read_value;
  $display("SNAP %0d %0d %0d %0d %0d %0d %0d",epoch,lane,f,c,p,e,v);
 end endtask
 initial begin
  wait(dut.rst_n);repeat(10)@(negedge clk);
  command(0,0,0,0);if(read_value!=32'h56494431)$fatal(1,"identity");
  command(0,8,0,0);if(read_value!=32'h9abcdef0)$fatal(1,"buildID");
  command(0,8'h40,0,1);
  for(g=0;g<3;g=g+1)begin
   command(1,8'hfc,g+1,0);
   command(0,8'hfc,0,0);if(read_value!=g+1)$fatal(1,"bank");
   for(n=0;n<8;n=n+1)begin
    case(n)
     0:status=32'h123456+g*32'h10101;1:status=32'h654321;2:status=32'habcdef;
     3:status=32'h00400080;4:status=32'h103;default:status=0;
    endcase
    command(1,8'h40+n*4,status,0);
   end
   command(1,8'h38,1,0);command(1,8'h30,1,0);
  end
  command(1,8'hfc,4,1);command(0,8'hfc,0,0);if(read_value!=3)$fatal(1,"badbank changed state");
  for(g=0;g<3;g=g+1)snapshot(g,0);
  command(1,8'h10,7,0);command(0,8'h40,0,1);
  command(1,8'hfc,1,0);command(1,8'h40,32'hf0a050,0);
  command(1,8'h38,1,0);command(1,8'h30,1,0);
  snapshot(0,1);
  $display("PASS video UART banked control");$finish;
 end
 initial begin #30000000;$fatal(1,"UART timeout");end
endmodule
