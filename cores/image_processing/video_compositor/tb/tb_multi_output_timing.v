`timescale 1ns/1ps
module tb_multi_output_timing;
reg clk=0;always #5 clk=~clk;
reg rst_n=0;reg [2:0] tick=0,start=0,stop=0,abort=0,dr=7;
wire [2:0] ready,run,done,err,hs,vs,de,sof,eol,eof,fe;
wire [23:0] ec;wire [47:0] x,y;wire [95:0] frames;
wire [191:0] pixels,ticks;
reg [47:0] ha={16'd5,16'd3,16'd4};
reg [47:0] hf={16'd2,16'd1,16'd1},hw={16'd1,16'd2,16'd1},hb={16'd1,16'd1,16'd2};
reg [47:0] va={16'd3,16'd4,16'd2};
reg [47:0] vf={16'd1,16'd2,16'd1},vw={16'd2,16'd1,16'd1},vb={16'd1,16'd1,16'd1};
multi_output_timing dut(clk,rst_n,tick,start,stop,abort,dr,ready,run,done,err,
 ha,hf,hw,hb,va,vf,vw,vb,3'b101,3'b010,ec,x,y,hs,vs,de,sof,eol,eof,fe,frames,pixels,ticks);
integer n,g;integer epoch[0:2];
always @(posedge clk)if(rst_n)begin
 for(g=0;g<3;g=g+1)begin
  if(start[g]&&ready[g])epoch[g]=epoch[g]+1;
  if(run[g]&&tick[g])$display("PIX %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",g,epoch[g],x[g*16+:16],y[g*16+:16],hs[g],vs[g],de[g],sof[g],eol[g],eof[g],fe[g],frames[g*32+:32],pixels[g*64+:64],ticks[g*64+:64]);
 end
end
initial begin
 for(n=0;n<3;n=n+1)epoch[n]=0;
 repeat(3)@(negedge clk);rst_n=1;start=7;
 @(negedge clk);start=0;
 for(n=0;n<5000;n=n+1)begin
  tick[0]=1;tick[1]=(n%2==0);tick[2]=(n%3==0);
  stop=(n==500)?2:0;abort=(n==1700)?4:0;
  start=0;
  if(n==1000)begin if(!ready[1])$fatal(1,"stop did not finish");start[1]=1;end
  if(n==2200)begin
   if(!ready[2]||!err[2]||ec[23:16]!=3)$fatal(1,"abort status");
   ha[47:32]=0;start[2]=1;
  end
  if(n==2202)begin if(!err[2]||ec[23:16]!=1||run[2])$fatal(1,"invalid timing status");end
  if(n==2300)begin ha[47:32]=5;start[2]=1;end
  @(negedge clk);
 end
 $display("PASS multi output timing");$finish;
end
endmodule
