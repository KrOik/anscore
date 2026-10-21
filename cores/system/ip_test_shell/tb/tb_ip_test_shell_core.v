`timescale 1ns/1ps
module tb_ip_test_shell_core;
 reg clk=0,rst=0,qv=0,qw=0,rr=0;
 always #5 clk=~clk;
 reg [7:0] addr=0;
 reg [31:0] wd=0;
 wire qr,rv,re;
 wire [31:0] rd;
 wire [7:0] probe;
 reg [31:0] result,lo,hi;
 reg [35:0] word;
 integer index,total,source,offset,n,polls;
 ip_test_shell_core dut(clk,rst,qv,qw,addr,wd,4'hf,qr,rv,rd,re,rr,probe);
 always @(posedge clk) if(rst&&dut.loaded_core.active) begin
  if(dut.loaded_core.drops!=0) $fatal(1,"loaded fabric packet drop");
  if(dut.loaded_core.mv&&dut.loaded_core.mr&&dut.loaded_core.permit)
   if(dut.loaded_core.mk!==4'hf||dut.loaded_core.mu!==0||dut.loaded_core.ml!==1)
    $fatal(1,"loaded packet metadata");
 end
 task access;
  input wr; input [7:0] a; input [31:0] data; input expect_error;
  begin
   @(negedge clk); qv=1; qw=wr; addr=a; wd=data;
   @(posedge clk); while(!qr) @(posedge clk);
   #1; qv=0;
   wait(rv); #1; result=rd;
   if(re!==expect_error) $fatal(1,"core access error addr=%h",a);
   // Request address may change while an older response is stalled.
   addr=a^8'h40;wd=~data;
   repeat(2) begin @(posedge clk); #1; if(!rv||rd!==result||re!==expect_error) $fatal(1,"core response unstable"); end
   @(negedge clk); rr=1;
   @(posedge clk); #1; rr=0;
  end
 endtask
 task run_loaded;
  input integer case_id,count;
  reg [31:0] expected;
  begin
   for(integer j=0;j<count;j=j+1) begin
    access(1,8'h4c,j,0);
    expected=(32'hd324a519^(case_id*32'h710341))+(j*32'h198371);
    access(1,8'h50,expected,0);
   end
   access(1,8'h44,count,0);access(1,8'h48,count,0);access(1,8'h40,1,0);
   access(1,8'h08,2,0);
   if(probe!==dut.loaded_core.probe) $fatal(1,"loaded probe page");
   access(1,8'h08,7,0);if(probe!==0) $fatal(1,"invalid probe page");
   access(1,8'h08,2,0);
   access(0,0,0,0);if(result!==32'h49503034) $fatal(1,"legacy ID routing");
   if(count>3) access(1,8'h50,0,1);
   polls=0;result=0;
   while(!result[1]) begin
    access(0,8'h40,0,0);polls=polls+1;
    if(polls>3000) $fatal(1,"loaded timeout");
   end
   if(result!=2) $fatal(1,"loaded run error");
   access(0,8'h60,0,0);if(result!=count) $fatal(1,"loaded issued");
   access(0,8'h64,0,0);if(result!=count) $fatal(1,"loaded captured");
   for(integer j=0;j<count;j=j+1) begin
    access(1,8'h54,j,0);access(0,8'h58,0,0);
    expected=(32'hd324a519^(case_id*32'h710341))+(j*32'h198371);
    if(result!==expected) $fatal(1,"loaded data case=%d index=%d got=%h expected=%h",case_id,j,result,expected);
    $display("LOADED_WORD case=%0d index=%0d data=%08h",case_id,j,result);
   end
   $display("PASS shell_core loaded case=%0d full_words=%0d",case_id,count);
  end
 endtask
 task run_case;
  input integer seed,length;
  input [31:0] mask,crc;
  begin
   access(1,12,seed,0); access(1,16,length,0); access(1,20,mask,0);
   access(1,4,1,0);
   polls=0; result=0;
   while(!result[1]) begin
    access(0,4,0,0); polls=polls+1;
    if(polls>2000) $fatal(1,"poll timeout");
   end
   if(result!=2) $fatal(1,"core run error");
   access(0,52,0,0); if(result!==crc) $fatal(1,"core CRC mismatch");
   access(0,56,0,0); if(result!=4*length) $fatal(1,"core byte count");
   access(0,48,0,0); total=result;
   if(total!=4*((length+2)/3)) $fatal(1,"core trace count");
   source=0; offset=0;
   for(index=0;index<total;index=index+1) begin
    access(1,36,index,0);
    access(0,40,0,0); lo=result;
    access(0,44,0,0); hi=result;
    word={hi[3:0],lo};
    n=length-offset; if(n>3) n=3;
    if(word[34:27]!=source||word[26:24]!==((1<<n)-1)||word[35]!==(offset+n==length)) $fatal(1,"host trace metadata");
    for(integer b=0;b<n;b=b+1)
     if(word[b*8+:8]!==((seed+source*73+offset+b)&8'hff)) $fatal(1,"host trace byte");
    if(word[35]) begin source=source+1; offset=0; end else offset=offset+n;
   end
   if(source!=4) $fatal(1,"host trace missing packet");
   access(1,36,total,0); access(0,40,0,1); // unwritten trace rejected
   $display("PASS shell_core runtime seed=%0d length=%0d readback_words=%0d CRC=%h",seed,length,total,crc);
  end
 endtask
 initial begin
  #1; rst=1; #1; rst=0;
  repeat(3) @(negedge clk); rst=1;
  run_case(18,7,0,32'h1d13cecd);
  run_case(189,63,32'h33333333,32'hb04bcafd);
  run_case(255,256,32'h55555555,32'h72c300ea);
  run_loaded(0,3);run_loaded(1,31);run_loaded(2,256);
  access(0,8'h68,0,1);access(0,8'h41,0,1);
  $display("PASS shell_core three CSR-controlled runs without reset plus full trace readback");
  $finish;
 end
 initial begin #2000000; $fatal(1,"core timeout"); end
endmodule
