`timescale 1ns/1ps
module tb_video_control;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,qv=0,qw=0,rr=0;reg [9:0] addr=0;reg [31:0] data=0;
wire qr,sv,se;wire [31:0] sd;wire [2:0] pv,de,hs,vs;wire [71:0] rgb;wire [7:0] probe;
video_control dut(clk,rst_n,qv,qw,addr,data,4'hf,qr,sv,se,sd,rr,pv,de,hs,vs,rgb,probe);
integer epoch=0,g,n,base;reg [31:0] value,frame,crc,pixels,error,version,drops,produced;
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task access;input w;input [9:0] a;input [31:0] d;input expected_error;
reg [32:0] held;
begin
 #1;if(!qr)$fatal(1,"CSR not ready");qv=1;qw=w;addr=a;data=d;tick;qv=0;
 if(!sv||se!==expected_error)$fatal(1,"CSR response addr%h error%b expected%b",a,se,expected_error);
 value=sd;held={se,sd};
 repeat(2)begin tick;if(!sv||qr||{se,sd}!==held)$fatal(1,"response stall");end
 rr=1;tick;rr=0;
end endtask
task snapshots;
integer lane;
begin
 for(lane=0;lane<3;lane=lane+1)begin
  access(0,10'h40+lane*32,0,0);frame=value;
  access(0,10'h44+lane*32,0,0);crc=value;
  access(0,10'h48+lane*32,0,0);pixels=value;
  access(0,10'h4c+lane*32,0,0);error=value;
  access(0,10'h50+lane*32,0,0);version=value;
  access(0,10'ha0+lane*4,0,0);drops=value;
  access(0,(lane+1)*256+10'h60,0,0);produced=value;
  $display("SNAP %0d %0d %0d %0d %0d %0d %0d %0d %0d",epoch,lane,frame,crc,pixels,error,version,drops,produced);
 end
end endtask
initial begin
 tick;rst_n=1;access(0,0,0,0);if(value!=32'h56494431)$fatal(1,"magic");
 access(1,10'h130,1,1); // No committed layers yet.
 for(g=0;g<3;g=g+1)begin
  base=(g+1)*256;
  access(1,base,8+g,0);access(1,base+16,4,0);access(1,base+36,3,0);
  for(n=0;n<8;n=n+1)begin
   case(n)
    0:data=32'h123456+g*32'h10101;1:data=32'h654321;2:data=32'habcdef;
    3:data=32'h00400080;4:data=32'h103;default:data=0;
   endcase
   access(1,base+64+n*4,data,0);
  end
  access(1,base+56,1,0);
 end
 for(g=0;g<3;g=g+1)access(1,(g+1)*256+48,1,0);
 access(1,10'h100,7,1); // Timing locked during run.
 access(1,10'h140,32'hf0a050,0);access(1,10'h138,1,0);
 repeat(1500)tick;
 for(g=0;g<3;g=g+1)begin access(0,(g+1)*256+44,0,0);if(value!=1)$fatal(1,"not idle clean %h",value);end
 snapshots;access(1,10'h10,7,0);
 // Repeat without reset/download, with new target and retained layers.
 epoch=1;
 for(g=0;g<3;g=g+1)begin access(1,(g+1)*256+36,1,0);access(1,(g+1)*256+48,1,0);end
 repeat(800)tick;snapshots;
 access(1,10'h10,7,0);
 // Invalid geometry must terminate with error and no CRC; repair and retry.
 access(1,10'h100,0,0);access(1,10'h130,1,0);repeat(20)tick;
 access(0,10'h12c,0,0);if(value!=9)$fatal(1,"invalid geometry not explicit");
 access(0,10'h160,0,0);if(value!=0)$fatal(1,"invalid geometry produced CRC");
 access(0,4,0,0);if(value!=0)$fatal(1,"invalid geometry published result");
 access(1,10'h100,8,0);access(1,10'h124,10,0);access(1,10'h130,1,0);
 access(1,10'h130,4,0);repeat(200)tick;
 access(0,10'h12c,0,0);if(value!=9)$fatal(1,"abort not explicit");
 access(0,10'h160,0,0);if(value!=1)$fatal(1,"abort did not finish current frame only");
 access(1,10'h10,1,0);access(1,10'h124,1,0);access(1,10'h130,1,0);repeat(200)tick;
 access(0,10'h12c,0,0);if(value!=1)$fatal(1,"abort recovery not clean");
 access(0,10'h160,0,0);if(value!=1)$fatal(1,"abort recovery count");
 $display("PASS control invalid geometry/abort/recovery");
 $display("PASS video control integration");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
