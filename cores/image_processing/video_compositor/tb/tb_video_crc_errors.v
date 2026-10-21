`timescale 1ns/1ps
module tb_video_crc_errors;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,v=0,r=1,sof=0,last=0;reg [23:0] rgb=0;
reg [31:0] id=0,expected=1;reg [7:0] pe=0;
wire rv;wire [31:0] rf,rc,rp;wire [7:0] re;
video_frame_crc dut(clk,rst_n,v,r,sof,last,rgb,id,expected,pe,rv,rf,rc,rp,re);
always @(posedge clk)if(rv)$display("RESULT %0d %0d %0d %0d",rf,rc,rp,re);
task send;input s,l;input [23:0] p;input [31:0] f;
begin v=1;sof=s;last=l;rgb=p;id=f;@(negedge clk);v=0;end endtask
initial begin
 repeat(2)@(negedge clk);rst_n=1;
 send(0,1,24'h030201,1); // Missing SOF.
 expected=3;send(1,0,24'h030201,2);send(0,1,24'h060504,2); // Short frame.
 expected=2;send(1,0,24'h030201,3);send(0,1,24'h060504,99); // Frame ID changed.
 expected=1;send(1,0,24'h030201,4);send(1,1,24'h060504,5); // Nested SOF resync.
 pe=8'h80;send(1,1,24'h030201,6);pe=0;
 // A stalled LAST must not publish or update partial CRC.
 send(1,0,24'h030201,7);expected=2;
 r=0;v=1;sof=0;last=1;rgb=24'h060504;id=7;
 repeat(5)begin @(negedge clk);if(rv)$fatal(1,"result while stalled");end
 r=1;@(negedge clk);v=0;
 // Reset discards incomplete frame and sticky local errors.
 expected=1;send(1,0,24'h030201,8);rst_n=0;@(negedge clk);rst_n=1;
 send(1,1,24'h060504,9);
 repeat(3)@(negedge clk);$display("PASS CRC errors");$finish;
end
endmodule
