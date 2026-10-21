`timescale 1ns/1ps
module tb_test_shell_csr;
 reg clk=0,rst=0;
 always #5 clk=~clk;
 reg qv=0,qw=0,rr=0,busy=0,done=0,error=0;
 reg [7:0] addr=0;
 reg [31:0] data=0;
 reg [3:0] strobe=15;
 wire qr,rv,re,start;
 wire [31:0] rd,seed,mask;
 wire [15:0] length;
 wire [2:0] page;
 integer starts=0,transactions=0;
 test_shell_csr dut(clk,rst,qv,qw,addr,data,strobe,qr,rv,rd,re,rr,
 busy,done,error,32'd71,32'd3,32'd999,start,page,seed,mask,length);
 always @(posedge clk) if(rst&&start) starts=starts+1;
 task transaction;
  input wr;
  input [7:0] a;
  input [31:0] d;
  input [3:0] strb;
  input expected_error;
  input [31:0] expected_data;
  begin
   @(negedge clk); qv=1; qw=wr; addr=a; data=d; strobe=strb; rr=0;
   @(posedge clk); if(!qr) $fatal(1,"unexpected busy endpoint");
   #1; qv=0;
   if(!rv||re!==expected_error||rd!==expected_data) $fatal(1,"CSR addr=%h rd=%h error=%b",a,rd,re);
   repeat(4) begin
    @(posedge clk); #1;
    if(!rv||re!==expected_error||rd!==expected_data||qr) $fatal(1,"stalled response changed");
   end
   @(negedge clk); rr=1;
   @(posedge clk); #1;
   if(rv) $fatal(1,"response not consumed");
   transactions=transactions+1;
  end
 endtask
 initial begin
  #1; rst=1; #1; rst=0;
  repeat(3) @(negedge clk); rst=1;
  transaction(0,0,0,0,0,32'h49503034);
  transaction(0,16,0,0,0,16);
  transaction(1,12,32'h12345678,15,0,0);
  transaction(1,12,32'haabbccdd,5,0,0);
  transaction(0,12,0,0,0,32'h12bb56dd);
  transaction(1,16,0,15,1,0);
  transaction(1,16,257,15,1,0);
  transaction(1,16,256,15,0,0);
  transaction(1,8,8,15,1,0);
  transaction(1,8,3,15,0,0);
  transaction(1,4,1,0,0,0); // byte strobe suppresses command
  transaction(1,4,1,1,0,0);
  busy=1;
  transaction(1,4,1,1,1,0);
  transaction(1,12,9,15,1,0);
  transaction(1,16,9,15,1,0);
  transaction(1,20,9,15,1,0);
  transaction(1,8,2,15,0,0); // observation page is live-configurable
  transaction(0,8,0,0,0,2);
  transaction(0,12,0,0,0,32'h12bb56dd);
  transaction(0,16,0,0,0,256);
  transaction(0,4,0,0,0,1);
  transaction(0,24,0,0,0,71);
  transaction(0,28,0,0,0,3);
  transaction(0,32,0,0,0,999);
  transaction(0,33,0,0,1,0);
  transaction(0,252,0,0,1,0);
  transaction(1,0,0,15,1,0);
  if(starts!=1) $fatal(1,"start pulse count %d",starts);
  // Consume the previous response and accept the next request on every edge.
  @(negedge clk); qv=1; qw=0; addr=0; rr=1;
  repeat(8) begin
   @(posedge clk); if(!qr) $fatal(1,"endpoint pipeline bubble");
   #1; if(!rv||re||rd!==32'h49503034) $fatal(1,"pipelined read");
   @(negedge clk);
  end
  qv=0; rr=0; // keep a response pending during asynchronous reset
  #2; rst=0; #1;
  if(rv||start||page||seed!=1||length!=16||mask) $fatal(1,"reset state");
  $display("PASS CSR transactions=%0d partial_writes busy_guard errors response_backpressure",transactions);
  $finish;
 end
 initial begin #100000; $fatal(1,"CSR timeout"); end
endmodule
