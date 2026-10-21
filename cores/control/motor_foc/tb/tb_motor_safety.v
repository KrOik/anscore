`timescale 1ns/1ps
module tb_motor_safety;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,enable=0,ext=1,encoder=0,control=0,clear=0,sv=0,fake_heartbeat=0;
reg [1:0] phase=0;always @(posedge clk)if(!rst_n)phase<=0;else phase<=phase+1'b1;
wire monitor_tick=phase==0;
wire fault_n,safe_latched,pwm_latched,ready,pending,applied,cf;
wire [7:0] cause,good,early,late,tout;wire [63:0] time_first;wire [31:0] faults,aid,rejected;
wire [2:0] hi,lo,raw;wire [15:0] counter,p,u,v,w,dead;
reg [31:0] id=1;
motor_safety #(.WMIN(2),.WMAX(12)) supervisor(clk,rst_n,enable,ext,encoder,control,
 monitor_tick,applied||fake_heartbeat,clear,fault_n,safe_latched,cause,time_first,faults,good,early,late,tout);
pwm3_atomic drive(clk,rst_n,enable,fault_n,clear,sv,ready,16'd16,16'd4,16'd8,16'd12,16'd2,id,
 raw,hi,lo,pwm_latched,cf,pending,applied,aid,rejected,counter,p,u,v,w,dead);
integer n;
always @(posedge clk)if(rst_n)begin
 #1;if(hi&lo)$fatal(1,"safety overlap");if(!fault_n&&(hi||lo))$fatal(1,"unsafe gates");
end
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task send;begin #1;if(!ready)$fatal(1,"PWM busy");sv=1;tick;sv=0;id=id+1;end endtask
task recover;begin enable=0;clear=1;repeat(20)tick;clear=0;
 if(safe_latched||pwm_latched||!fault_n)$fatal(1,"recovery failed");end endtask
task report;input [7:0] expected;begin
 repeat(2)tick;if(!safe_latched||!pwm_latched||cause!=expected||hi||lo)$fatal(1,"cause wanted%0d got%0d",expected,cause);
 $display("FAULT %0d %0d %0d %0d %0d %0d %0d",cause,time_first,faults,good,early,late,tout);
end endtask
initial begin
 tick;rst_n=1;send;recover;enable=1;
 for(n=0;n<224;n=n+1)begin if(n%32==0)send;else tick;end
 if(safe_latched||good<4)$fatal(1,"healthy applied heartbeat lost");
 repeat(80)tick;report(3);
 encoder=1;repeat(3)tick;if(cause!=3)$fatal(1,"first cause overwritten");
 clear=1;repeat(3)tick;if(cause!=3)$fatal(1,"enabled clear accepted");
 enable=0;repeat(3)tick;if(!safe_latched)$fatal(1,"encoder fault clear accepted");
 encoder=0;recover;enable=1;send;repeat(8)tick;
 encoder=1;#1;if(hi||lo)$fatal(1,"encoder fault not propagated");report(2);
 encoder=0;recover;enable=1;send;repeat(8)tick;
 #2;ext=0;#1;if(hi||lo)$fatal(1,"external fault shutdown");#1;ext=1;report(1);
 recover;enable=1;
 // Arm tick,then a heartbeat between ticks must be retained and classified early.
 while(!monitor_tick)tick;tick;fake_heartbeat=1;tick;fake_heartbeat=0;
 repeat(6)tick;report(4);
 recover;enable=1;send;repeat(8)tick;control=1;report(5);
 control=0;recover;
 if(faults!=5)$fatal(1,"fault accounting %0d",faults);
 // Single-clock clear outside monitor beat must not re-latch the old timeout.
 enable=1;repeat(80)tick;report(3);enable=0;
 while(phase!=1)tick;
 clear=1;tick;clear=0;
 repeat(12)begin tick;if(safe_latched||cause!=0)$fatal(1,"stale watchdog relatched after pulse clear");end
 if(!fault_n||tout!=0||faults!=6)$fatal(1,"pulse clear watchdog/accounting");
 recover;
 $display("PASS single-clock disabled clear retained across monitor beat");
 $display("PASS motor safety applied watchdog/firstcause/encoder/gates/recovery");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
