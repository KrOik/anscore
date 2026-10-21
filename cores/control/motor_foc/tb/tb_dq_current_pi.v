`timescale 1ns/1ps
module tb_dq_current_pi;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,restart=0,freeze=0;
reg signed [11:0] rd=0,rq=0,cd=0,cq=0;
reg [31:0] sid=0;wire sr,mv;wire signed [11:0] ud,uq,integd,integq;
wire [11:0] fd,fq;wire [1:0] fault,clip;wire [31:0] mid;
dq_current_pi dut(clk,rst_n,sv,sr,rd,rq,cd,cq,12'sd8,12'sd4,4'd4,restart,freeze,sid,
 mv,mr,ud,uq,integd,integq,fd,fq,fault,clip,mid);
integer n,plant_d=0,plant_q=0,dist_d=0,dist_q=0;
reg [31:0] rng=32'h2509cafe;reg stalled=0;reg [115:0] held;
always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[2:0]!=0;end
always @(posedge clk)if(rst_n)begin
 if(stalled&&(!mv||{ud,uq,integd,integq,fd,fq,fault,clip,mid}!==held))$fatal(1,"PI output stall");
 stalled=mv&&!mr;held={ud,uq,integd,integq,fd,fq,fault,clip,mid};
end
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 for(n=0;n<1024;n=n+1)begin
  rd=n<64?0:n<384?120:n<512?-80:n<576?1500:n<832?0:100;
  rq=n<64?0:n<384?-160:n<512?90:n<576?-1500:n<832?0:-100;
  dist_d=n>=256&&n<384?80:0;dist_q=n>=256&&n<384?-64:0;
  restart=n==0||n==832;freeze=n>=320&&n<336;
  cd=plant_d;cq=plant_q;sid=n;sv=1;
  @(posedge clk);while(!sr)@(posedge clk);
  @(negedge clk);sv=0;
  @(posedge clk);while(!(mv&&mr))@(posedge clk);
  $display("PI %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",mid,rd,rq,plant_d,plant_q,ud,uq,integd,integq,fd,fq,fault,clip);
  plant_d=plant_d+(($signed(ud)-2*plant_d+dist_d)>>>4);
  plant_q=plant_q+(($signed(uq)-2*plant_q+dist_q)>>>4);
  @(negedge clk);
 end
 // Explicit signed error saturation at the interface.
 rd=-2048;rq=2047;cd=2047;cq=-2048;sid=1024;sv=1;restart=1;
 @(posedge clk);while(!sr)@(posedge clk);@(negedge clk);sv=0;
 @(posedge clk);while(!(mv&&mr))@(posedge clk);
 if(clip!=3||mid!=1024)$fatal(1,"error clipping");
 @(negedge clk);$display("PASS dq current PI numerical plant");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
