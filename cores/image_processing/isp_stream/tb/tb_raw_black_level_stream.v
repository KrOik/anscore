`timescale 1ns/1ps
module tb_raw_black_level_stream;
 parameter RAW_BITS=10;
 localparam MAX=(1<<RAW_BITS)-1;
 reg clk=0,rst=0,cv=0,cb=0,sv=0,sof=0,eol=0,mr=0;
 always #5 clk=~clk;
 reg [1:0] pattern=0;reg [RAW_BITS*4-1:0] levels=0;
 reg [RAW_BITS-1:0] target=0,data=0;reg [15:0] frame_id=0;
 wire cr,sr,mv,ms,me;wire [RAW_BITS-1:0] md;wire [15:0] mf;
 wire [31:0] low_clips,high_clips;
 raw_black_level_stream #(.RAW_BITS(RAW_BITS)) dut(clk,rst,cv,cr,pattern,levels,target,cb,
  sv,sr,data,sof,eol,frame_id,mv,mr,md,ms,me,mf,low_clips,high_clips);
 reg [31:0] rng=32'h129ace31;reg held=0;reg [RAW_BITS+17:0] held_word;
 integer received=0,fd,expected=0;
 reg [1023:0] outfile;
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[0]||rng[2];
 end
 always @(posedge clk)if(rst)begin
  if(held&&(!mv||{mf,ms,me,md}!==held_word))$fatal(1,"stalled pixel changed");
  held<=mv&&!mr;held_word<={mf,ms,me,md};
  if(mv&&mr)begin
   $fwrite(fd,"%c%c%c%c%c",md&255,(md>>8)&255,mf&255,(mf>>8)&255,{6'd0,me,ms});
   received=received+1;
  end
 end
 task config_frame(input integer f);
 begin
  @(negedge clk);cv=1;pattern=f%4;target=f%3==0?0:MAX/2;cb=f==5;
  for(integer p=0;p<4;p=p+1)levels[p*RAW_BITS+:RAW_BITS]=(MAX/4+p*17+f*11)&MAX;
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;
 end endtask
 integer width,height;
 initial begin
  if(!$value$plusargs("output=%s",outfile))$fatal(1,"output file required");
  fd=$fopen(outfile,"wb");if(!fd)$fatal(1,"open output");
  repeat(4)@(negedge clk);rst=1;config_frame(0);
  for(integer f=0;f<8;f=f+1)begin
   width=f==6?320:f==7?640:f==4?1:5;
   height=f==6?240:f==7?480:3;expected=expected+width*height;
   for(integer y=0;y<height;y=y+1)for(integer x=0;x<width;x=x+1)begin
    if(x==0&&y==1&&f<7)config_frame(f+1); // pending config must not affect current frame
    if(!rng[7])@(negedge clk);
    @(negedge clk);sv=1;data=(x*37+y*53+f*97)&MAX;sof=x==0&&y==0;eol=x==width-1;frame_id=f;
    do @(posedge clk);while(!sr);
    @(negedge clk);sv=0;
   end
  end
  wait(received==expected);@(negedge clk);$fclose(fd);
  $display("PASS streaming BLC RAW_BITS=%0d pixels=%0d low=%0d high=%0d",RAW_BITS,received,low_clips,high_clips);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
