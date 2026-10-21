`timescale 1ns/1ps
module tb_lockin_config;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,w=0,c=0,idle=1,ready=0;
 reg [3:0] idx=0,strb=15;reg [31:0] data=0;
 wire wr,cr,valid,pending;wire [511:0] active;wire [31:0] version;
 integer launches=0;
 lockin_config dut(clk,rst_n,w,wr,idx,data,strb,c,cr,idle,ready,valid,active,version,pending);
 always @(posedge clk)if(rst_n&&valid&&ready)launches<=launches+1;
 task tick;begin @(posedge clk);#1;end endtask
 task put(input [3:0] n,input [31:0] v,input [3:0] s);begin
  @(negedge clk);idx=n;data=v;strb=s;w=1;tick;
  @(negedge clk);w=0;
 end endtask
 initial begin
  repeat(2)tick;@(negedge clk);rst_n=1;tick;
  if(valid||version) $fatal(1,"reset launch");
  put(0,32'h12345678,15);
  // Same-edge last write is part of the committed snapshot.
  @(negedge clk);idx=1;data=32'h11223344;w=1;c=1;tick;
  @(negedge clk);w=0;c=0;tick;
  if(!valid||version!=1||active[63:0]!=64'h1122334412345678)$fatal(1,"atomic apply");
  repeat(4)begin tick;if(!valid||version!=1)$fatal(1,"stalled command");end
  // Commit another operation while the first command itself is stalled.
  put(0,32'hffffaa00,2);
  @(negedge clk);c=1;tick;@(negedge clk);c=0;tick;
  if(!pending||wr||cr||version!=1)$fatal(1,"pending command gate");
  @(negedge clk);ready=1;idle=0;tick;
  @(negedge clk);ready=0;tick;
  if(launches!=1||valid||!pending)$fatal(1,"launch once");
  // Writes during pending cannot corrupt the committed snapshot.
  put(0,32'hdeadbeef,15);repeat(4)tick;
  if(active[31:0]!=32'h12345678||version!=1)$fatal(1,"busy config mutation");
  @(negedge clk);idle=1;tick;
  if(version!=2||active[31:0]!=32'h1234aa78||!valid||pending)$fatal(1,"deferred apply");
  @(negedge clk);ready=1;tick;
  @(negedge clk);ready=0;repeat(5)tick;
  if(launches!=2||valid)$fatal(1,"duplicate launch");
  @(negedge clk);rst_n=0;tick;
  if(valid||version||pending||active)$fatal(1,"reset recovery");
  $display("PASS atomic lockin config: stalled launch, queued commit, byte masks, isolation, exactly once, reset");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
