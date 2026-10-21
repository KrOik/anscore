`timescale 1ns/1ps
module tb_dual_osd_stream;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,sv=0,mr=0;wire ready,mv,sof,eol,last;wire[23:0] pixel;
 wire[15:0] user;wire[31:0] frame;wire[7:0] error;
 reg[192:0] vectors[0:1023];reg[192:0] v;
 reg[2047:0] filename;integer n,received=0;
 reg[31:0] rng=32'h12345678;
 dual_osd_stream dut(clk,rst,sv,ready,v[23:0],v[47:24],v[71:48],v[95:72],v[119:96],
  v[128:120],v[137:129],v[139:138],v[141:140],v[142],v[143],v[144],
  v[160:145],v[192:161],8'd0,mv,mr,pixel,sof,eol,last,user,frame,error);
 integer ticks=0;reg[63:0] previous_output=0;
 always @(negedge clk)begin ticks=ticks+1;rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=ticks<160||rng[2:0]!=0;end
 reg stalled=0;reg[82:0] held;
 always @(posedge clk)if(rst)begin
  if(stalled&&(!mv||{pixel,sof,eol,last,user,frame,error}!==held))$fatal(1,"OSD stall");
  stalled=mv&&!mr;held={pixel,sof,eol,last,user,frame,error};
  if(mv&&mr)begin
   if(received>0&&received<128&&$time-previous_output!=20)$fatal(1,"OSD continuous II not1");
   previous_output=$time;
   $display("OSD index=%0d rgb=%0d sof=%0d eol=%0d last=%0d user=%0d frame=%0d error=%0d",received,pixel,sof,eol,last,user,frame,error);
   received=received+1;
  end
 end
 initial begin
  if(!$value$plusargs("fixture=%s",filename))$fatal(1,"missing fixture");
  $readmemh(filename,vectors);repeat(5)@(negedge clk);rst=1;
  for(n=0;n<1024;n=n+1)begin
   if(n>=128)repeat(rng[1:0])@(negedge clk);
   @(negedge clk);sv=1;v=vectors[n];
   do @(posedge clk);while(!ready);
   if(n>=127)begin @(negedge clk);sv=0;v=0;end
  end
  wait(received==1024);repeat(10)@(negedge clk);
  $display("PASS dual OSD stream independent layers/key/alpha/metadata/stalls");$finish;
 end
 initial begin #3000000;$fatal(1,"OSD timeout");end
endmodule
