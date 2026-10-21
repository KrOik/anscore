`timescale 1ns/1ps
module tb_udp_replay;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,cv=0,dr=0;reg[15:0] packets=5,length=37;
 reg[31:0] seed=32'h12345678,timeout=200000;reg[1:0] fault=0;
 wire ready,done,txen;wire[1:0] txd;wire[4:0] error;
 wire[31:0] cycles,tp,rp,tb,rb,tc,rc;
 udp_replay dut(clk,rst,cv,ready,packets,length,seed,timeout,fault,done,dr,error,
  cycles,tp,rp,tb,rb,tc,rc,txen,txd);
 integer run=0;
 task command;begin
  @(negedge clk);cv=1;do @(posedge clk);while(!ready);
  @(negedge clk);cv=0;
 end endtask
 task response(input[4:0] expected_error);
 reg[228:0] held;
 begin
  wait(done);if(error!==expected_error)$fatal(1,"replay error got%0d expected%0d",error,expected_error);
  if(error==0)begin
   if(tp!=packets||rp!=packets||tb!=packets*length||rb!=tb||tc!=rc)$fatal(1,"replay accounting/CRC");
   $display("REPLAY run=%0d packets=%0d length=%0d seed=%0d cycles=%0d crc=%0d",run,tp,length,seed,cycles,~tc);
  end
  if(run==4&&cycles!=5)$fatal(1,"timeout not exact");
  held={error,cycles,tp,rp,tb,rb,tc,rc};
  repeat(11)begin @(negedge clk);if(!done||ready||txen||{error,cycles,tp,rp,tb,rb,tc,rc}!==held)$fatal(1,"held replay result");end
  dr=1;@(negedge clk);dr=0;run=run+1;
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;
  command;
  packets=1;length=4;seed=0;timeout=1;fault=3;
  repeat(20)@(negedge clk);
  packets=5;length=37;seed=32'h12345678;timeout=200000;fault=0;
  response(0);
  packets=2;length=1472;seed=32'h87654321;command;response(0);
  fault=1;command;response(4);
  fault=2;packets=1;length=4;timeout=1000;command;response(2);
  fault=0;timeout=5;command;response(2);
  timeout=200000;packets=0;command;response(1);
  packets=5;length=37;seed=32'h12345678;command;response(0);
  command;repeat(30)@(negedge clk);rst=0;@(negedge clk);rst=1;
  repeat(2)@(negedge clk);if(done||!ready)$fatal(1,"global reset ownership");
  command;response(0);
  $display("PASS finite UDP replay counts/CRC/fault/timeout/abort/recovery/heldresult");$finish;
 end
 initial begin #30000000;$fatal(1,"replay bench timeout");end
endmodule
