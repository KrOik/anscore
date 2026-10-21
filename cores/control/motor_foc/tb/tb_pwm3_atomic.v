`timescale 1ns/1ps
module tb_pwm3_atomic;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,enable=0,fault_n=1,clear=0,sv=0;
reg [15:0] p=16,u=4,v=8,w=12,dead=2;reg [31:0] id=1;
wire sr,latched,cf,pending,applied;wire [2:0] raw,hi,lo;
wire [31:0] aid,rejected;wire [15:0] counter,ap,au,av,aw,ad;
pwm3_atomic dut(clk,rst_n,enable,fault_n,clear,sv,sr,p,u,v,w,dead,id,
 raw,hi,lo,latched,cf,pending,applied,aid,rejected,counter,ap,au,av,aw,ad);
integer cycle=0;
always @(posedge clk)if(rst_n)begin
 cycle=cycle+1;
 if(hi&lo)$fatal(1,"overlap");
 if((!enable||latched||cf)&& (hi||lo))$fatal(1,"unsafe gates");
 $display("PWM %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",cycle,enable,aid,counter,ap,au,av,aw,ad,raw,hi,lo,latched||cf);
end
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task send;begin
 #1;if(!sr)$fatal(1,"command not ready");sv=1;tick;sv=0;
end endtask
task recover;begin
 enable=0;clear=1;repeat(6)tick;clear=0;
 if(latched||cf)$fatal(1,"fault recovery");enable=1;
end endtask
initial begin
 tick;rst_n=1;send;recover;
 repeat(37)tick; // Update in the middle of the old carrier.
 p=20;u=5;v=10;w=15;dead=3;id=2;send;
 if(!pending||aid!=1||ap!=16)$fatal(1,"early non-atomic apply");
 while(pending)begin tick;if(pending&&aid!=1)$fatal(1,"mixed config");end
 if(aid!=2||counter!=0||ap!=20||au!=5||av!=10||aw!=15||ad!=3)$fatal(1,"new command mismatch");
 repeat(100)tick;
 // Invalid complete command latches shutdown but retains active parameters.
 u=21;id=3;send;tick;
 if(!cf||!latched||rejected!=1||aid!=2||hi||lo)$fatal(1,"invalid command handling");
 u=0;v=20;w=10;id=4;send;enable=0;repeat(2)tick;recover;
 repeat(100)tick;
 #2;fault_n=0;#1;if(hi||lo)$fatal(1,"asynchronous shutdown");
 #1;fault_n=1;repeat(5)tick;if(!latched)$fatal(1,"fault lost");
 recover;repeat(100)tick;
 $display("PASS atomic PWM carrier/protection");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
