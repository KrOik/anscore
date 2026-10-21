`timescale 1ns/1ps
module tb_csr_capture_replay;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,rv=0,rw=0,rr=1;reg[7:0] addr=0;reg[31:0] data=0;reg[3:0] strobe=15;
 wire ready,valid,err,sv,mr,active,done,error;wire[31:0] rd,sd;
 reg gate=1;integer tick=0;
 always @(posedge clk) tick<=tick+1;
 wire pass=gate&&(tick%7!=0)&&(tick%7!=1);
 reg stalled=0;reg[31:0] stalled_data;
 always @(posedge clk) begin
  if(rst_n&&stalled&&active&&(sd!==stalled_data||!sv)) $fatal(1,"stimulus changed under backpressure");
  stalled<=rst_n&&active&&sv&&!(mr&&pass);stalled_data<=sd;
 end
 csr_capture_replay #(.DEPTH(16),.TIMEOUT(200)) dut(
 clk,rst_n,rv,rw,addr,data,strobe,ready,valid,err,rd,rr,
 sd,sv,mr&&pass,sd^32'h5a39c617,sv&&pass,mr,active,done,error);
 task csr;
 input wr;input[7:0] a;input[31:0] d;input expected_error;
 begin
  @(negedge clk);rv=1;rw=wr;addr=a;data=d;
  while(!ready) @(negedge clk);
  @(negedge clk);rv=0;
  while(!valid) @(negedge clk);
  if(err!==expected_error) $fatal(1,"CSR error a=%h got=%b",a,err);
 end endtask
 integer run,i,n,received;reg[31:0] expected,held;reg held_error;
 initial begin
  repeat(3) @(negedge clk);rst_n=1;
  csr(0,8'h18,0,1);
  for(run=0;run<3;run=run+1) begin
   n=run==0?1:run==1?7:16;
   for(i=0;i<n;i=i+1) begin
    csr(1,8'h0c,i,0);csr(1,8'h10,32'h10203040+run*1009+i*73,0);
   end
   csr(1,4,n,0);csr(1,8,n,0);csr(1,0,1,0);
   csr(1,8'h10,32'hdeadbeef,1);
   wait(done);if(error) $fatal(1,"run error");
   csr(0,8'h20,0,0);if(rd!=n) $fatal(1,"issued");
   csr(0,8'h24,0,0);if(rd!=n) $fatal(1,"captured");
   for(i=0;i<n;i=i+1) begin
    csr(1,8'h14,i,0);csr(0,8'h18,0,0);
    expected=(32'h10203040+run*1009+i*73)^32'h5a39c617;
    if(rd!==expected) $fatal(1,"readback run=%d i=%d got=%h expected=%h",run,i,rd,expected);
   end
  end
  csr(1,8'h0c,16,1);csr(1,8'h14,16,1);csr(1,8'h28,1,1);
  strobe=1;csr(1,4,2,1);strobe=15;
  csr(1,4,0,0);csr(1,0,1,0);wait(done);if(!error||active) $fatal(1,"invalid length");
  csr(1,4,17,0);csr(1,0,1,0);wait(done);if(!error) $fatal(1,"oversize");
  gate=0;csr(1,4,4,0);csr(1,8,4,0);csr(1,0,1,0);
  csr(0,8'h18,0,1);wait(done);if(!error||active) $fatal(1,"timeout");
  gate=1;csr(1,4,1,0);csr(1,8,1,0);csr(1,0,1,0);wait(done);if(error) $fatal(1,"recovery");
  // Abort a stalled run through reset, then reload before replaying.
  gate=0;csr(1,0,1,0);repeat(4) @(negedge clk);rst_n=0;
  repeat(2) @(negedge clk);if(active||sv) $fatal(1,"active reset");rst_n=1;gate=1;
  csr(1,8'h0c,0,0);csr(1,8'h10,32'h12345678,0);csr(1,0,1,0);wait(done);
  if(error) $fatal(1,"reset recovery");
  // A held response must not change when the requester changes address/data.
  csr(0,8'h24,0,0);rr=0;held=rd;held_error=err;
  repeat(8) begin @(negedge clk);addr=addr+4;data=data+1;
   if(!valid||rd!==held||err!==held_error||ready) $fatal(1,"response stall");end
  rr=1;@(negedge clk);rst_n=0;@(negedge clk);
  if(valid||active) $fatal(1,"reset");
  $display("PASS CSR replay: 3 loaded datasets / 24 full words, stalls, guards, invalid lengths, timeout/recovery, held response");$finish;
 end
 initial begin #100000;$fatal(1,"test timeout");end
endmodule
