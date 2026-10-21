`timescale 1ns/1ps
module tb_motor_plant;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,en=0,clear=0,sv=0,ack=0,qa=0,qb=0,restart=0;
reg [1:0] mode=0;reg [31:0] sid=0;
reg signed [9:0] ia=0,ib=0,ic=0;
reg signed [31:0] target=0;reg signed [15:0] ts=0;
wire ready,valid,safe,pwm_fault,applied;wire [31:0] id,faults;
wire [7:0] error,cause;wire [63:0] first_time;
wire signed [31:0] pos,vel;wire signed [11:0] md,mq,vd,vq;
wire [15:0] du,dv,dw;wire [2:0] hi,lo;
reg [5:0] divider=0;always @(posedge clk)divider<=divider+1'b1;
motor_controller #(.WMAX(64)) dut(clk,rst_n,en,1'b1,clear,divider==0,
 qa,qb,1'b0,1'b0,sv,ready,mode,restart,1'b0,
 ia,ib,ic,8'd0,target,ts,12'sd0,12'sd0,12'sd8,12'sd4,4'd4,16'd256,16'd2,sid,
 valid,ack,id,error,pos,vel,md,mq,vd,vq,du,dv,dw,hi,lo,safe,pwm_fault,cause,first_time,faults,applied);
integer cycles=0,updates=0;
always @(posedge clk)if(rst_n)begin
 cycles=cycles+1;if(applied)updates=updates+1;
 #1;if(hi&lo)$fatal(1,"plant gate overlap");
 if((!safe||!en||pwm_fault)&&(hi||lo))$fatal(1,"plant unsafe gates");
end
task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
integer n,pa=0,pb=0,va,vb,pq=0,mv=0,encoder_position=0,gray=0;
integer wanted,start,load_q8;
task encoder_edge;input integer direction;begin
 gray=(gray+direction+4)%4;
 case(gray)0:begin qa=0;qb=0;end 1:begin qa=1;qb=0;end
 2:begin qa=1;qb=1;end 3:begin qa=0;qb=1;end endcase
 repeat(6)tick;encoder_position=encoder_position+direction;
end endtask
initial begin
 tick;rst_n=1;
 for(n=0;n<2048;n=n+1)begin
  start=cycles;wanted=pq>>>8;
  while(encoder_position<wanted)encoder_edge(1);
  while(encoder_position>wanted)encoder_edge(-1);
  repeat(6)tick;
  mode=n<32?0:n<512?1:n<1536?2:n<1600?0:1;
  if(n==512)target=wanted+160;if(n==1024)target=target-240;
  ts=n<288?4:n<512?-3:0;restart=n==1600;sid=n;
  ia=pa;ib=(-pa*1024+pb*1774+1024)>>>11;ic=-ia-ib;
  if(!ready)$fatal(1,"plant sample ownership");sv=1;tick;sv=0;
  while(!valid)tick;
  if(error||id!=n||pos!=wanted)$fatal(1,"plant result n%0d error%h pos%0d wanted%0d",n,error,pos,wanted);
  $display("PLANT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",n,mode,pos,vel,target,ts,pa,pb,md,mq,vd,vq,du,dv,dw,pq,mv,updates);
  va=(2*$signed({1'b0,du})-$signed({1'b0,dv})-$signed({1'b0,dw}))*2048/(3*256);
  vb=($signed({1'b0,dv})-$signed({1'b0,dw}))*2048*1024/(1774*256);
  pa=pa+((va-2*pa)>>>4);pb=pb+((vb-2*pb)>>>4);
  load_q8=n>=192&&n<256?8*256:0;
  mv=mv+((pb*256-4*mv-load_q8)>>>7);pq=pq+mv;
  ack=1;tick;ack=0;
  if(n==0)begin clear=1;repeat(128)tick;clear=0;en=1;end
  if(cycles-start>1024)$fatal(1,"sample deadline exceeded");
  while(cycles-start<1024)tick;
 end
 if(updates!=2048||faults!=0)$fatal(1,"plant update/fault count");
 $display("PASS integrated PWM/current/mechanical/QEI plant 2048 fixed-cadence samples");$finish;
end
initial begin #30000000;$fatal(1,"plant timeout");end
endmodule
