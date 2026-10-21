`timescale 1ns/1ps
// End-to-end scan bits -> CDC mailbox -> real CSR core -> packet fabric RAM.
module tb_scan_loaded_core;
 reg clk=0,tck=0,rst_n=0,selected=0,capture=0,shift=0,update=0,tdi=0;
 always #5 clk=~clk;always #7 tck=~tck;
 wire tdo,qv,qw,qr,pv,pe,pr;wire[7:0] qa,probe;wire[31:0] qd,pd;wire[3:0] qs;
 scan_csr_mailbox transport(clk,tck,rst_n,selected,capture,shift,update,tdi,tdo,
 qv,qw,qa,qd,qs,qr,pv,pd,pe,pr);
 ip_test_shell_core core(clk,rst_n,qv,qw,qa,qd,qs,qr,pv,pd,pe,pr,probe);
 function[7:0] crc;
 input[63:0] p;reg[7:0] c;integer i,j;
 begin c=0;for(i=0;i<8;i=i+1)begin c=c^p[i*8+:8];
 for(j=0;j<8;j=j+1)c=c[7]?(c<<1)^7:c<<1;end crc=c;end
 endfunction
 task scan;
 input[71:0] tx;output[71:0] rx;integer b;
 begin
  rx=0;@(negedge tck);selected=1;capture=1;
  @(negedge tck);capture=0;shift=1;
  for(b=0;b<72;b=b+1)begin tdi=tx[b];rx[b]=tdo;@(negedge tck);end
  shift=0;update=1;@(negedge tck);update=0;selected=0;
 end endtask
 reg[7:0] tag=0;reg[31:0] result;
 task access;
 input wr;input[7:0] address;input[31:0] value;input expected_error;
 reg[63:0] payload;reg[71:0] reply;integer polls;
 begin
  tag=tag+1;payload={8'ha5,tag,wr,4'hf,address,value,3'd0};
  scan({crc(payload),payload},reply);polls=0;reply=0;
  while(!reply[41]||reply[40]||reply[55:48]!=tag)begin
   scan(0,reply);polls=polls+1;if(polls>20)$fatal(1,"scan CSR poll timeout");
  end
  if(reply[71:64]!==crc(reply[63:0])||reply[63:56]!==8'h5a||
     reply[7:0]!==1||reply[43]||reply[42]!==expected_error)$fatal(1,"scan CSR response");
  result=reply[39:8];
 end endtask
 integer run,n,j,tries;reg[31:0] expected;
 initial begin
  #1;rst_n=1;#1;rst_n=0;repeat(5)@(negedge tck);rst_n=1;repeat(5)@(negedge tck);
  access(0,0,0,0);if(result!==32'h49503034)$fatal(1,"scan design ID");
  access(0,8'h68,0,1);
  for(run=0;run<3;run=run+1)begin
   n=run==0?3:run==1?31:256;
   for(j=0;j<n;j=j+1)begin
    access(1,8'h4c,j,0);access(1,8'h50,(32'hd324a519^(run*32'h710341))+(j*32'h198371),0);
   end
   access(1,8'h44,n,0);access(1,8'h48,n,0);access(1,8'h08,2,0);access(1,8'h40,1,0);
   tries=0;result=0;
   while(!result[1])begin access(0,8'h40,0,0);tries=tries+1;if(tries>100)$fatal(1,"run timeout");end
   if(result!==2)$fatal(1,"scan loaded run error");
   access(0,8'h60,0,0);if(result!=n)$fatal(1,"issued");
   access(0,8'h64,0,0);if(result!=n)$fatal(1,"captured");
   for(j=0;j<n;j=j+1)begin
    access(1,8'h54,j,0);access(0,8'h58,0,0);
    expected=(32'hd324a519^(run*32'h710341))+(j*32'h198371);
    if(result!==expected)$fatal(1,"scan loaded mismatch");
    $display("LOADED_WORD case=%0d index=%0d data=%08h",run,j,result);
   end
   $display("PASS scan loaded case=%0d words=%0d",run,n);
  end
  $display("PASS scan to real shell three datasets 290 complete words without reset");$finish;
 end
 initial begin #50000000;$fatal(1,"test timeout");end
endmodule
