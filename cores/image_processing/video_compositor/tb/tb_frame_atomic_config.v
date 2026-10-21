`timescale 1ns/1ps
module tb_frame_atomic_config;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,wv=0,cv=0,sv=0,mr=1,sof=0,last=0;
reg [1:0] wi=0;reg [31:0] wd=0;reg [3:0] strb=15;
reg [23:0] data=0;
wire wr,cr,sr,mv,ms,ml,pending,owned,err;wire [23:0] md;
wire [127:0] active;wire [31:0] version;
frame_atomic_config dut(clk,rst_n,wv,wr,wi,wd,strb,cv,cr,active,version,pending,
 sv,sr,data,sof,last,mv,mr,md,ms,ml,owned,err);
task tick;begin @(posedge clk);#1;
 $display("TRACE t=%0t owned=%b pending=%b version=%0d valid=%b ready=%b last=%b",$time,owned,pending,version,mv,mr,last);
 @(negedge clk);end endtask
task check;input ok;begin if(!ok)$fatal(1,"frame config check failed at %0t",$time);end endtask
integer n;
initial begin
 tick;rst_n=1;
 // Same-edge write/commit while first pixel is already offered: block it.
 wv=1;wd=32'h12345678;cv=1;sv=1;sof=1;data=42;#1;
 check(!sr&&!mv);tick;check(active[31:0]==32'h12345678&&version==1);
 wv=0;cv=0;#1;check(sr&&mv&&md==42);tick;check(owned);
 sof=0;wv=1;wi=1;wd=32'habcdef01;cv=1;tick;
 check(pending&&version==1&&active[63:32]==0);
 wv=0;cv=0;mr=0;last=1;
 for(n=0;n<9;n=n+1) begin tick;check(pending&&owned&&version==1&&!wr&&!cr);end
 mr=1;tick;check(!owned&&pending&&version==1);
 // Next frame offered immediately. Pending apply must precede acceptance.
 sof=1;last=0;#1;check(!sr&&!mv);tick;
 check(!pending&&version==2&&active[63:32]==32'habcdef01);
 #1;check(sr&&mv);tick;check(owned&&!err);
 // Partial byte write and queued config cannot tear frame.
 sof=0;wv=1;wi=0;wd=32'hffffffff;strb=2;cv=1;tick;
 wv=0;cv=0;check(active[31:0]==32'h12345678);
 last=1;tick;sv=0;tick;check(active[31:0]==32'h1234ff78&&version==3);
 // Single-pixel frames and backpressure before start.
 sv=1;sof=1;last=1;mr=0;repeat(3)tick;
 check(!owned&&version==3);
 // Commit after a head pixel is exposed under stall must preserve valid/config.
 cv=1;wv=1;wi=2;wd=32'h98765432;strb=15;tick;
 check(mv&&pending&&version==3&&active[95:64]==0);
 cv=0;wv=0;repeat(3)begin tick;check(mv&&pending&&version==3);end
 mr=1;tick;check(!owned&&!err);sv=0;tick;
 check(version==4&&active[95:64]==32'h98765432);sv=1;
 // Malformed no-SOF frame holds ownership until LAST; sticky diagnostic.
 sof=0;last=0;tick;check(owned&&err);
 last=1;tick;check(!owned&&err);
 rst_n=0;tick;check(active==0&&version==0&&!pending&&!owned&&!err);
 $display("PASS frame atomic config: boundary/stall/queued/partial/single/error/reset");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
