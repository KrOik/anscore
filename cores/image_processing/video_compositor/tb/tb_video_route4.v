`timescale 1ns/1ps
module tb_video_route4;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,setup=1;
wire [95:0] rgb,mrgb;wire [127:0] frame,mframe,wd,versions;
wire [63:0] user,muser;wire [31:0] error,merror,count;
wire [3:0] sof,eol,last,valid,ready,wv,wr,cv,cr,pending,fe,ms,me,ml,mv;
reg [3:0] mr=0;
video_route4 dut(clk,rst_n,rgb,frame,user,error,sof,eol,last,valid,ready,
 wv,wr,4'd0,wd,16'hffff,cv,cr,pending,fe,versions,
 mrgb,mframe,muser,merror,ms,me,ml,mv,mr,count);
reg [31:0] rng=32'h778899aa;integer n,o,total=0;
always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[3:0]|rng[7:4];end
genvar g;
generate for(g=0;g<4;g=g+1)begin: sources
 integer sent=0;reg sv=0,accepted=0,changed=0,commit=0;
 reg [31:0] prng=32'hcafefeed+g*777;
 assign valid[g]=sv;
 assign rgb[g*24+:24]=(g<<20)|sent;
 assign frame[g*32+:32]=32'h80000000+g*256+sent/(9+g);
 assign user[g*16+:16]=sent;
 assign error[g*8+:8]=g<<4;
 assign sof[g]=sent%(9+g)==0;
 assign eol[g]=sent%3==2;
 assign last[g]=sent%(9+g)==8+g;
 assign cv[g]=rst_n&&(setup||commit);
 assign wv[g]=cv[g];
 assign wd[g*32+:32]=setup?(g%2):((g+1)%4);
 always @(posedge clk)if(rst_n)begin accepted=sv&&ready[g];if(accepted)sent<=sent+1;end
 always @(negedge clk)if(rst_n&&!setup)begin
  prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
  if(!sv||accepted)sv=sent<8*(9+g)&&prng[2:0]!=0;
  commit=0;
  if(!changed&&sent>=5)begin commit=1;changed=1;end
 end
end endgenerate
generate for(g=0;g<4;g=g+1)begin: sink_checks
 reg stalled=0;reg [82:0] held;
 always @(posedge clk)if(rst_n)begin
  if(stalled&&(!mv[g]||{mrgb[g*24+:24],mframe[g*32+:32],muser[g*16+:16],merror[g*8+:8],ms[g],me[g],ml[g]}!==held))
   $fatal(1,"route output changed under stall");
  stalled=mv[g]&&!mr[g];
  held={mrgb[g*24+:24],mframe[g*32+:32],muser[g*16+:16],merror[g*8+:8],ms[g],me[g],ml[g]};
 end
end endgenerate
// Sample before source counters update at the edge.
always @(posedge clk)if(rst_n)begin
 for(o=0;o<4;o=o+1)if(mv[o]&&mr[o])begin
  $display("PIX %0d %0d %0d %0d %0d %0d %0d %0d %0d",o,mrgb[o*24+:24],mframe[o*32+:32],muser[o*16+:16],merror[o*8+:8],ms[o],me[o],ml[o],total);
  total=total+1;
 end
end
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 @(negedge clk);setup=0;
 repeat(2000)@(negedge clk);
 if(total!=336||count!=32||fe||pending)$fatal(1,"route completion %0d frames%0d fe%b",total,count,fe);
 $display("PASS video route4");$finish;
end
endmodule
