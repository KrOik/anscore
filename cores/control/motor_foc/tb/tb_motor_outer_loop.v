`timescale 1ns/1ps
module tb_motor_outer_loop;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,restart=0,vvalid=1;
reg [1:0] mode=0;reg signed [31:0] pos=0,vel=0,tp=0;reg signed [15:0] ts=0;
reg signed [11:0] dq=0;reg [31:0] sid=0;
wire sr,mv,reset_echo;wire signed [11:0] rd,rq;wire signed [15:0] speed;
wire [31:0] mid;wire [7:0] error;wire [3:0] clip;
motor_outer_loop dut(clk,rst_n,sv,sr,mode,restart,vvalid,pos,vel,tp,ts,12'sd0,dq,sid,
 mv,mr,rd,rq,speed,mid,error,clip,reset_echo);
integer n,position_q8=0,velocity_q8=0,previous_position=0,load_q8=0,target=0;
reg [84:0] held;
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task issue;begin
 #1;if(!sr)$fatal(1,"outerloop busy");sv=1;tick;sv=0;while(!mv)tick;
 held={rd,rq,speed,mid,error,clip,reset_echo};
 repeat(3)begin tick;if(!mv||{rd,rq,speed,mid,error,clip,reset_echo}!==held)$fatal(1,"outerloop held result");end
end endtask
task ack;begin mr=1;tick;mr=0;end endtask
initial begin
 tick;rst_n=1;
 for(n=0;n<1024;n=n+1)begin
  pos=position_q8>>>8;vel=pos-previous_position;previous_position=pos;
  mode=n<32?0:n<256?1:n<768?2:n<832?0:1;
  if(n==256)target=pos+400;if(n==512)target=target-600;
  tp=target;ts=n<160?12:n<256?-8:0;dq=0;sid=n;restart=n==832;
  load_q8=n>=96&&n<128?32*256:0;
  issue;if(error||mid!=n)$fatal(1,"outerloop result");
  $display("OUTER %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",n,mode,pos,vel,tp,ts,speed,rq,clip,reset_echo,velocity_q8);
  velocity_q8=velocity_q8+(($signed(rq)*256-4*velocity_q8-load_q8)>>>5);
  position_q8=position_q8+velocity_q8;
  ack;
 end
 mode=3;sid=2000;issue;if(error!=1)$fatal(1,"invalid mode");ack;
 mode=1;vvalid=0;sid=2001;issue;if(error!=2)$fatal(1,"invalid speed baseline");ack;
 vvalid=1;vel=32'h80000000;sid=2002;issue;if(!clip[0])$fatal(1,"speed error overflow");ack;
 $display("PASS motor outer modes/plant/ownership");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
