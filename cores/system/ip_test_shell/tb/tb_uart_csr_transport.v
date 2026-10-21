`timescale 1ns/1ps
module tb_uart_csr_transport;
 reg clk=0,rst=0;
 always #5 clk=~clk;
 reg [7:0] rx=0;
 reg rv=0,err=0,tr=0;
 wire [7:0] tx;
 wire tv,qv,qw,qr,pv,pe,pr;
 wire [7:0] qa,probe;
 wire [31:0] qd,pd;
 reg [63:0] response;
 integer received=0,requests=0,ticks=0;
 uart_csr_transport #(.GAP_TIMEOUT(30)) transport(clk,rst,rx,rv,err,tx,tv,tr,qv,qw,qa,qd,qr,pv,pd,pe,pr);
 ip_test_shell_core core(clk,rst,qv,qw,qa,qd,4'hf,qr,pv,pd,pe,pr,probe);
 function [7:0] crc_byte;
  input [7:0] c,b; reg [7:0] x; integer j;
  begin x=c^b; for(j=0;j<8;j=j+1) x=x[7]?(x<<1)^8'h07:x<<1; crc_byte=x; end
 endfunction
 task send_byte;
  input [7:0] b;
  begin @(negedge clk); rx=b; rv=1; @(negedge clk); rv=0; end
 endtask
 task command;
  input [7:0] op,a; input [31:0] d; input corrupt;
  reg [55:0] body; reg [7:0] crc; integer i;
  begin
   body={d,a,op,8'ha5}; crc=0;
   for(i=0;i<7;i=i+1) begin send_byte(body[i*8+:8]); crc=crc_byte(crc,body[i*8+:8]); end
   send_byte(crc^{7'd0,corrupt});
  end
 endtask
 task expect_reply;
  input [7:0] a,status; input [31:0] data;
  reg [7:0] crc; integer i;
  begin
   wait(received==8); #1;
   if(response[55:0]!=={data,a,status,8'h5a}) $fatal(1,"UART reply payload %h",response);
   crc=0; for(i=0;i<7;i=i+1) crc=crc_byte(crc,response[i*8+:8]);
   if(response[63:56]!==crc) $fatal(1,"UART reply CRC");
   @(negedge clk); received=0;
  end
 endtask
 always @(negedge clk) begin ticks=ticks+1; tr=(ticks%7>2); end
 always @(posedge clk) if(rst) begin
  if(qv&&qr) requests=requests+1;
  if(tv&&tr) begin response[received*8+:8]=tx; received=received+1; end
 end
 initial begin
  #1; rst=1; #1; rst=0; repeat(3) @(negedge clk); rst=1;
  command(0,0,0,0); expect_reply(0,0,32'h49503034);
  command(1,12,32'h12345678,1);
  repeat(50) @(negedge clk);
  if(requests!=1||received) $fatal(1,"corrupt command executed");
  send_byte(8'ha5); send_byte(0); repeat(40) @(negedge clk); // partial timeout
  command(1,12,32'h12345678,0); expect_reply(12,0,0);
  command(0,12,0,0); expect_reply(12,0,32'h12345678);
  command(0,1,0,0); expect_reply(1,1,0);
  if(requests!=4) $fatal(1,"wrong command count");
  $display("PASS UART transport CRC rejection partial timeout CSR read/write errors TX backpressure");
  $finish;
 end
 initial begin #100000; $fatal(1,"transport timeout"); end
endmodule
