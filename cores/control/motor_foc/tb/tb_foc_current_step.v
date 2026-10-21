`timescale 1ns/1ps
module tb_foc_current_step;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,enable=0,fault_n=1,clear=0,sv=0,ack=0,restart=0;
reg signed [9:0] ia=0,ib=0,ic=0;reg [7:0] theta=0;
reg signed [11:0] rd=0,rq=0;reg [15:0] period=256;reg [31:0] sid=0;
wire sr,done,latched;wire [7:0] error;wire [31:0] id;wire [39:0] diagnostics;
wire signed [11:0] md,mq,ud,uq;wire [15:0] du,dv,dw;wire [2:0] hi,lo;
foc_current_step dut(clk,rst_n,enable,fault_n,clear,sv,sr,ia,ib,ic,theta,rd,rq,12'sd8,12'sd4,4'd4,restart,1'b0,period,16'd2,sid,
 done,ack,error,id,md,mq,ud,uq,du,dv,dw,hi,lo,latched,diagnostics,);
integer n,pa=0,pb=0,va,vb,da,db;reg [175:0] held;
always @(posedge clk)if(rst_n)begin
 if(hi&lo)$fatal(1,"FOC shoot-through");
 if((latched||!fault_n||!enable)&&(hi||lo))$fatal(1,"FOC fault gate");
end
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task issue;begin
 #1;if(!sr)$fatal(1,"sample owner busy");sv=1;tick;sv=0;
 while(!done)tick;
 if(id!=sid)$fatal(1,"FOC result ID");
 held={error,id,md,mq,ud,uq,du,dv,dw,diagnostics};
 repeat(3)begin tick;if(!done||{error,id,md,mq,ud,uq,du,dv,dw,diagnostics}!==held)$fatal(1,"FOC result not held");end
end endtask
task release_result;begin ack=1;tick;ack=0;end endtask
task clear_drive;begin enable=0;clear=1;repeat(8)tick;clear=0;if(latched)$fatal(1,"FOC fault did not clear");end endtask
initial begin
 tick;rst_n=1;
 for(n=0;n<512;n=n+1)begin
  ia=pa;ib=(-pa*1024+pb*1774+1024)>>>11;ic=-ia-ib;
  theta=n<128?0:n<256?32:64;
  rd=n<16?0:n<256?80:n<384?-60:0;rq=n<16?0:n<256?-60:n<384?80:0;
  restart=n==0||n==384;sid=n;
  issue;if(error)$fatal(1,"FOC error n%0d code%h",n,error);
  $display("FOC %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",id,pa,pb,ia,ib,ic,md,mq,ud,uq,du,dv,dw,diagnostics);
  va=(2*$signed({1'b0,du})-$signed({1'b0,dv})-$signed({1'b0,dw}))*2048/(3*$signed({1'b0,period}));
  vb=($signed({1'b0,dv})-$signed({1'b0,dw}))*2048*1024/(1774*$signed({1'b0,period}));
  da=n>=192&&n<256?40:0;db=n>=192&&n<256?-32:0;
  pa=pa+((va-2*pa+da)>>>4);pb=pb+((vb-2*pb+db)>>>4);
  release_result;
  if(n==0)begin clear_drive;enable=1;end
 end
 // Broken three-shunt consistency trips the actual connected gate block.
 ia=100;ib=100;ic=100;sid=9000;issue;
 if(error!=2||!latched||hi||lo)$fatal(1,"sensor trip");release_result;
 clear_drive;ia=0;ib=0;ic=0;rd=0;rq=0;restart=1;sid=9001;
 issue;if(error)$fatal(1,"sensor recovery");release_result;enable=1;
 // Fault during an owned operation flushes arithmetic and holds an error.
 sid=9002;sv=1;tick;sv=0;#2;fault_n=0;#1;if(hi||lo)$fatal(1,"external fault latency");
 while(!done)tick;if(error!=8||id!=9002)$fatal(1,"owned fault result");
 fault_n=1;release_result;clear_drive;
 period=3;sid=9003;issue;if(error!=1)$fatal(1,"invalid PWM config");release_result;
 $display("PASS phase FOC applied PWM/plant/fault ownership");$finish;
end
initial begin #10000000;$fatal(1,"timeout");end
endmodule
