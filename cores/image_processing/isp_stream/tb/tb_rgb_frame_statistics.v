`timescale 1ns/1ps
module tb_rgb_frame_statistics;
 parameter SUM_WIDTH=48;
 reg clk=0,rst=0,sv=0,mr=0,stats_ready=0,sof=0,eol=0,eof=0;
 always #5 clk=~clk;
 reg [23:0] data=0;reg [15:0] id=0;
 wire sr,mv,ms,me,mf,stats_valid,overflow,protocol_error;
 wire [23:0] md;wire [15:0] mid,stats_id;
 wire [SUM_WIDTH-1:0] sum_r,sum_g,sum_b;wire [31:0] pixels,lines;
 rgb_frame_statistics #(.SUM_WIDTH(SUM_WIDTH)) dut(clk,rst,sv,sr,data,sof,eol,eof,id,
 mv,mr,md,ms,me,mf,mid,stats_valid,stats_ready,sum_r,sum_g,sum_b,pixels,lines,stats_id,overflow,protocol_error);
 reg [31:0] rng=32'h1234babe;integer tick=0,received=0,snapshots=0,expected=0,fd;
 reg [1023:0] outfile;
 reg held=0,stats_held=0;
 reg [42:0] held_pixel;reg [3*SUM_WIDTH+80:0] held_stats;
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[0]||rng[3];stats_ready=tick>300&&(rng[4]||rng[7]);
 end
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  if(held&&(!mv||{mid,ms,me,mf,md}!==held_pixel))$fatal(1,"pixel unstable");
  if(stats_held&&(!stats_valid||{sum_r,sum_g,sum_b,pixels,lines,stats_id,overflow}!==held_stats))$fatal(1,"stats overwritten under stall");
  held<=mv&&!mr;held_pixel<={mid,ms,me,mf,md};
  stats_held<=stats_valid&&!stats_ready;held_stats<={sum_r,sum_g,sum_b,pixels,lines,stats_id,overflow};
  if(mv&&mr)begin
   $fwrite(fd,"%c%c%c%c%c%c",md[7:0],md[15:8],md[23:16],mid[7:0],mid[15:8],{5'd0,mf,me,ms});received=received+1;
  end
  if(stats_valid&&stats_ready)begin
   snapshots=snapshots+1;
   $display("STATS id=%0d pixels=%0d lines=%0d r=%0d g=%0d b=%0d overflow=%0d",stats_id,pixels,lines,sum_r,sum_g,sum_b,overflow);
  end
 end
 integer width,height;
 initial begin
  if(!$value$plusargs("output=%s",outfile))$fatal(1,"output required");fd=$fopen(outfile,"wb");
  repeat(4)@(negedge clk);rst=1;
  for(integer f=0;f<4;f=f+1)begin
   width=f==0?1:f==1?5:f==2?320:640;height=f==0?1:f==1?3:f==2?240:480;expected=expected+width*height;
   for(integer y=0;y<height;y=y+1)for(integer x=0;x<width;x=x+1)begin
    sv=1;id=f+200;sof=x==0&&y==0;eol=x==width-1;eof=eol&&y==height-1;
    data={8'((x*19+y*31+f*43)&255),8'((x*37+y*17+f*11)&255),8'((x*7+y*53+f*29)&255)};
    do @(posedge clk);while(!sr);@(negedge clk);sv=0;
   end
  end
  wait(snapshots==4&&received==expected);@(negedge clk);
  if(protocol_error)$fatal(1,"valid framing produced error");$fclose(fd);
  $display("PASS frame statistics SUM_WIDTH=%0d pixels=%0d snapshots=4",SUM_WIDTH,received);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
