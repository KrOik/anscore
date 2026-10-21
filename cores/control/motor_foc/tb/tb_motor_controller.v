`timescale 1ns/1ps
module tb_motor_controller;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,en=0,ext=1,clear=0,sv=0,ack=0,qa=0,qb=0;
reg [1:0] mode=0;reg [31:0] sid=0;
wire ready,valid,safe,pwm_fault,applied;wire [31:0] id,faults;
wire [7:0] error,cause;wire [63:0] first_time;
wire signed [31:0] pos,vel;wire signed [11:0] md,mq,vd,vq;
wire [15:0] du,dv,dw;wire [2:0] hi,lo;
reg [3:0] divider=0;always @(posedge clk)divider<=divider+1'b1;
motor_controller #(.WMAX(64)) dut(clk,rst_n,en,ext,clear,divider==0,
 qa,qb,1'b0,1'b0,sv,ready,mode,1'b0,1'b0,
 10'sd0,10'sd0,10'sd0,8'd0,32'sd80,16'sd4,
 12'sd0,12'sd0,12'sd8,12'sd4,4'd4,16'd64,16'd2,sid,
 valid,ack,id,error,pos,vel,md,mq,vd,vq,du,dv,dw,hi,lo,safe,pwm_fault,cause,first_time,faults,applied);
integer updates=0,n;reg [87:0] held;
always @(posedge clk)if(rst_n)begin
 if(applied)updates=updates+1;
 #1;if(hi&lo)$fatal(1,"overlap");if((!safe||!en||pwm_fault)&&(hi||lo))$fatal(1,"gate inhibit");
end
task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
task run;input [7:0] expected;begin
 #1;if(!ready)$fatal(1,"owner busy");sv=1;tick;sv=0;
 // Change live command after acceptance: stored mode and ID must prevail.
 sid=sid+1;mode=3;
 while(!valid)tick;
 if(id!=sid-1||error!=expected)$fatal(1,"result id/error %0d %h",id,error);
 held={id,error,du,dv,dw};
 repeat(4)begin tick;if(!valid||ready||{id,error,du,dv,dw}!==held)$fatal(1,"held result");end
 ack=1;tick;ack=0;
end endtask
task recover;begin en=0;clear=1;repeat(32)tick;clear=0;
 if(!safe||pwm_fault||cause)$fatal(1,"recovery");end endtask
initial begin
 tick;rst_n=1;mode=0;run(0);recover;en=1;
 // Legal Gray revolution through the synchronizers and canonical QEI.
 qa=1;qb=0;repeat(6)tick;qb=1;repeat(6)tick;
 qa=0;repeat(6)tick;qb=0;repeat(6)tick;
 mode=1;run(0);
 if(pos!=4||vel!=4)$fatal(1,"QEI snapshot %0d %0d",pos,vel);
 mode=2;run(0);if(vel!=0)$fatal(1,"coherent zero velocity");
 if(updates!=3)$fatal(1,"applied heartbeat count %0d",updates);
 // Illegal Gray transition trips supervisor and physical carrier.
 qa=1;qb=1;repeat(8)tick;
 if(cause!=2||!pwm_fault||hi||lo)$fatal(1,"encoder shutdown");
 recover;mode=0;run(0);en=1;
 // Invalid outer mode must terminate without submitting another PWM update.
 n=updates;mode=3;run(8'h20);repeat(3)tick;
 if(cause!=5||updates!=n||!pwm_fault)$fatal(1,"outer error ownership");
 recover;mode=0;run(0);en=1;
 #2;ext=0;#1;if(hi||lo)$fatal(1,"async external shutdown");ext=1;
 repeat(4)tick;if(cause!=1)$fatal(1,"external first cause");recover;
 $display("PASS controller QEI/three modes/applied ownership/held results/encoder/control/external recovery");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
