`timescale 1ns/1ps
module tb_scan_csr_mailbox;
 parameter TCK_HALF=7;
 reg clk=0,tck=0,rst_n=0;
 always #5 clk=~clk;always #(TCK_HALF) tck=~tck;
 reg selected=0,capture=0,shift=0,update=0,tdi=0,gate=1;
 wire tdo,qv,qw,pr;wire[7:0] qa;wire[31:0] qd;wire[3:0] qs;
 reg pv=0,pe=0;reg[31:0] pd=0;integer cycles=0,delay_left=0,accepted=0;
 wire qr=gate&&!pv&&delay_left==0&&(cycles%5!=0);
 scan_csr_mailbox dut(clk,tck,rst_n,selected,capture,shift,update,tdi,tdo,
 qv,qw,qa,qd,qs,qr,pv,pd,pe,pr);
 reg held=0;reg[44:0] held_request;
 always @(posedge clk) begin
  if(!rst_n) begin pv<=0;delay_left<=0;held<=0;cycles<=0;end
  else begin
   cycles<=cycles+1;
   if(held&&{qw,qa,qd,qs}!==held_request) $fatal(1,"request changed while stalled");
   held<=qv&&!qr;held_request<={qw,qa,qd,qs};
   if(pv&&pr) pv<=0;
   if(delay_left>0) begin delay_left<=delay_left-1;if(delay_left==1) pv<=1;end
   if(qv&&qr) begin
    accepted<=accepted+1;delay_left<=7;
    pd<=qd^{qa,qa,qa,qa}^{27'd0,qw,qs};pe<=qa==8'hfc;
   end
  end
 end
 function[7:0] crc;
 input[63:0] p;reg[7:0] c;integer i,j;
 begin c=0;for(i=0;i<8;i=i+1)begin c=c^p[i*8+:8];
 for(j=0;j<8;j=j+1)c=c[7]?(c<<1)^7:c<<1;end crc=c;end
 endfunction
 function[71:0] command;
 input[7:0] tag,addr;input wr;input[3:0] strobe;input[31:0] data;
 reg[63:0] p;
 begin p={8'ha5,tag,wr,strobe,addr,data,3'd0};command={crc(p),p};end
 endfunction
 task transfer;
 input[71:0] tx;input integer count;output[71:0] rx;
 integer i;
 begin
  rx=0;@(negedge tck);selected=1;capture=1;
  @(negedge tck);capture=0;shift=1;
  for(i=0;i<count;i=i+1)begin
   tdi=i<72?tx[i]:0;if(i<72)rx[i]=tdo;@(negedge tck);
  end
  shift=0;update=1;@(negedge tck);update=0;selected=0;
 end endtask
 task poll_response;
 input[7:0] tag;output[71:0] r;integer attempts;
 begin
  r=0;attempts=0;
  while(!r[41]||r[40]||r[55:48]!=tag) begin
   transfer(0,72,r);attempts=attempts+1;
   if(attempts>10) $fatal(1,"response polling timeout");
  end
 end endtask
 task check_response;
 input[71:0] r;input[7:0] tag,addr;input wr;input[3:0] strobes;input[31:0] value;
 begin
  if(r[71:64]!==crc(r[63:0])||r[63:56]!==8'h5a||r[7:0]!==1) $fatal(1,"response frame");
  if(r[55:48]!==tag||r[41:40]!==2'b10||r[42]!== (addr==8'hfc)) $fatal(1,"response flags/tag %h",r);
  if(r[39:8]!==(value^{addr,addr,addr,addr}^{27'd0,wr,strobes})) $fatal(1,"response data");
  $display("SCAN_VECTOR request=%018h response=%018h",command(tag,addr,wr,strobes,value),r);
 end endtask
 reg[71:0] rx,cmd;integer i,before_count;
 initial begin
  #1;rst_n=1;#1;rst_n=0;repeat(5)@(negedge tck);rst_n=1;repeat(5)@(negedge tck);
  // CRC corruption, short/long scan, reserved bits and bad magic never dispatch.
  cmd=command(1,8'h24,1,15,32'h12345678);
  transfer(cmd^72'h10000000000000000,72,rx);
  transfer(cmd,71,rx);transfer(cmd,73,rx);
  cmd[2:0]=1;cmd[71:64]=crc(cmd[63:0]);transfer(cmd,72,rx);
  cmd[63:56]=8'h12;cmd[71:64]=crc(cmd[63:0]);transfer(cmd,72,rx);
  repeat(10)@(negedge tck);if(accepted!=0) $fatal(1,"invalid command dispatched");
  gate=0;cmd=command(9,8'h38,1,5,32'h78351ad6);transfer(cmd,72,rx);
  transfer(command(10,8'h40,0,0,0),72,rx);
  transfer(0,72,rx);if(!rx[40]||!rx[43]||accepted) $fatal(1,"busy reject");
  // Complete the backend in the middle of shifting a captured busy response.
  fork
   transfer(0,72,rx);
   begin repeat(9)@(negedge tck);gate=1;end
  join
  if(rx[71:64]!==crc(rx[63:0])||!rx[40]||rx[41]) $fatal(1,"capture snapshot changed during shift");
  poll_response(9,rx);
  check_response(rx,9,8'h38,1,5,32'h78351ad6);
  if(accepted!=1) $fatal(1,"busy overwrite/duplicate");
  for(i=0;i<50;i=i+1)begin
   cmd=command(i,i==49?8'hfc:i*4,i[0],i[3:0],32'h9bc83710+i*713);
   transfer(cmd,72,rx);poll_response(i,rx);
   check_response(rx,i,i==49?8'hfc:i*4,i[0],i[3:0],32'h9bc83710+i*713);
   if(rx[43]) $fatal(1,"command_error not cleared");
  end
  before_count=accepted;repeat(3)transfer(0,72,rx);
  if(accepted!=before_count) $fatal(1,"NOP repeated command");
  // Reset also aborts a backend-accepted command awaiting its response.
  transfer(command(98,0,1,15,9),72,rx);wait(dut.state==2);rst_n=0;
  before_count=accepted;repeat(5)@(negedge tck);rst_n=1;
  repeat(20)@(negedge tck);transfer(0,72,rx);
  if(accepted!=before_count||qv||rx[41:40]!=0) $fatal(1,"accepted-command reset");
  // Common reset aborts an unaccepted request; no phantom toggle on recovery.
  gate=0;transfer(command(99,0,0,0,0),72,rx);rst_n=0;
  repeat(5)@(negedge tck);rst_n=1;gate=1;repeat(20)@(negedge tck);
  transfer(0,72,rx);if(accepted!=before_count||qv||rx[41:40]!=0) $fatal(1,"reset phantom request");
  transfer(command(100,8'h18,0,7,32'h21),72,rx);poll_response(100,rx);
  check_response(rx,100,8'h18,0,7,32'h21);
  $display("PASS scan mailbox TCK_HALF=%0d: 52 transactions, CRC/length/magic/reserved rejects, busy protection, CSR stalls/errors, NOP, reset recovery",TCK_HALF);$finish;
 end
 initial begin #5000000;$fatal(1,"timeout");end
endmodule
