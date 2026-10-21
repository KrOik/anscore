`timescale 1ns/1ps
module tb_video_results_csr;
reg clk=0;always #5 clk=~clk;
reg rst_n=0;reg [2:0] rv=0;reg [95:0] rf=0,rc=0,rp=0;
reg [23:0] re=0;reg [38:0] ver=0;
reg qv=0,qw=0,rr=0;reg [7:0] addr=0;reg [31:0] data=0;reg [3:0] strobe=15;
wire qr,sv,se;wire [31:0] sd;wire [2:0] occupied;
video_results_csr #(.BUILD_ID(64'h123456789abcdef0)) dut(clk,rst_n,rv,rf,rc,rp,re,ver,
 qv,qw,addr,data,strobe,qr,sv,se,sd,rr,occupied);
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task check;input ok;begin if(!ok)$fatal(1,"mailbox check t%0t",$time);end endtask
task request;input w;input [7:0] a;input [31:0] d;input [31:0] expected;input error;
reg [32:0] held;
begin
 #1;check(qr);qv=1;qw=w;addr=a;data=d;tick;qv=0;
 check(sv&&sd===expected&&se===error);held={se,sd};
 // Hold a response while producer activity continues; no second request accepted.
 repeat(3)begin tick;check(sv&&!qr&&{se,sd}===held);end
 rr=1;tick;rr=0;check(!sv&&qr);
end endtask
initial begin
 tick;rst_n=1;
 request(0,0,0,32'h56494431,0);request(0,8,0,32'h9abcdef0,0);
 request(0,8'h40,0,0,1);
 rf={32'd30,32'd20,32'd10};rc={32'hcc,32'hbb,32'haa};rp={32'd300,32'd200,32'd100};
 re=24'h030201;ver={13'd7,13'd6,13'd5};rv=7;tick;rv=0;
 check(occupied==7);
 // Incoming overwrites are dropped, not silently substituted during host reads.
 rf=0;rc=0;rp=0;re=0;ver=0;rv=7;tick;rv=0;
 request(0,4,0,7,0);request(0,8'h40,0,10,0);request(0,8'h44,0,32'haa,0);
 request(0,8'h48,0,100,0);request(0,8'h4c,0,1,0);request(0,8'h50,0,5,0);
 request(0,8'h54,0,1,0);request(0,8'h60,0,20,0);request(0,8'h80,0,30,0);
 request(0,8'ha0,0,1,0);request(0,8'ha4,0,1,0);request(0,8'ha8,0,1,0);
 request(0,8'h41,0,0,1);request(0,8'hac,0,0,1);
 request(1,8'h10,8,0,1);check(occupied==7);
 strobe=1;request(1,8'h10,1,0,1);check(occupied==7);strobe=15;
 // ACK and new result on same cycle replaces atomically without a drop.
 rf[31:0]=11;rc[31:0]=32'hdd;rp[31:0]=101;ver[12:0]=8;rv=1;
 qv=1;qw=1;addr=8'h10;data=1;tick;qv=0;rv=0;check(sv&&!se&&occupied==7);
 rr=1;tick;rr=0;
 request(0,8'h40,0,11,0);request(0,8'h44,0,32'hdd,0);
 request(0,8'h50,0,8,0);request(0,8'h54,0,2,0);request(0,8'ha0,0,1,0);
 request(1,8'h10,7,0,0);check(occupied==0);
 request(0,8'h40,0,11,1);
 rst_n=0;tick;rst_n=1;request(0,4,0,0,0);request(0,8'ha0,0,0,0);
 $display("PASS video result mailboxes: coherent/overrun/ACKcollision/heldresponse/errors/reset");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
