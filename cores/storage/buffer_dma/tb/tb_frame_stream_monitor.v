`timescale 1ns/1ps
module tb_frame_stream_monitor;
 reg clk=0,rst=0,v=0,r=0,last=0;reg [31:0] data=0;reg [3:0] keep=0;
 always #5 clk=~clk;
 wire [31:0] bytes,frames,stalls,duration,crc,last_crc;
 frame_stream_monitor dut(clk,rst,v,r,data,keep,last,bytes,frames,stalls,duration,crc,last_crc);
 integer tick=0,first_tick=-1,last_tick=0,expected_stalls=0;
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  if(v&&!r)expected_stalls=expected_stalls+1;
  if(v&&r)begin
   if(first_tick<0)first_tick=tick;
   if(last)last_tick=tick;
  end
 end
 task beat(input [31:0] word_data,input [3:0] mask,input tail,input integer delay_cycles);
 begin
  @(negedge clk);v=1;r=0;data=word_data;keep=mask;last=tail;
  repeat(delay_cycles)@(negedge clk);
  r=1;@(negedge clk);v=0;r=0;
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;
  // Known CRC32 vector "123456789", little-endian bytes.
  beat(32'h34333231,15,0,3);
  repeat(4)@(negedge clk);
  beat(32'h38373635,15,0,2);
  beat(32'hffffff39,1,1,5);
  if(bytes!=9||frames!=1||stalls!=expected_stalls||crc!=32'hcbf43926||last_crc!=32'hcbf43926||duration!=last_tick-first_tick+1)
   $fatal(1,"CRC/keep/latency/stall mismatch");
  beat(32'hdeadbeef,0,1,0);
  if(bytes!=9||frames!=2||last_crc!=0||duration!=1||crc!=32'hcbf43926)$fatal(1,"empty keep/single beat mismatch");
  @(negedge clk);rst=0;@(negedge clk);rst=1;
  if(bytes!=0||frames!=0||crc!=0||stalls!=0)$fatal(1,"reset mismatch");
  $display("PASS stream monitor known CRC, byte masks, frame duration, stalls, reset");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
