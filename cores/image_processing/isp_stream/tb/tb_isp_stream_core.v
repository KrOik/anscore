`timescale 1ns/1ps
module tb_isp_stream_core;
 parameter RAW_BITS=10;
 localparam MAX=(1<<RAW_BITS)-1;
 reg clk=0,rst=0,cv=0,sv=0,sof=0,eol=0,mr=0,rr=0;always #5 clk=~clk;
 reg [15:0] cw=0,ch=0,cf=0;reg [1:0] pattern=0;
 reg [RAW_BITS*4-1:0] levels=0;reg [RAW_BITS-1:0] target=0,data=0;
 wire cr,sr,mv,ms,me,mf,rv;wire [23:0] md;wire [15:0] frame_id,ow,oh;wire [3:0] error;
 reg [47:0] gains=0;reg [191:0] matrix=0;reg gamma_enable=0,lv=0;
 reg [1:0] channel=0;reg [7:0] address=0,value=0;wire lr;
 isp_stream_core #(.RAW_BITS(RAW_BITS)) dut(clk,rst,cv,cr,cw,ch,cf,pattern,levels,target,1'b0,
 gains,matrix,gamma_enable,lv,lr,channel,address,value,
 sv,sr,data,sof,eol,mv,mr,md,ms,me,mf,frame_id,rv,rr,error,ow,oh,1'b0);
 reg [31:0] rng=32'h13579bdf;reg held=0;reg [42:0] held_word;
 integer fd,received=0,expected=0;reg [1023:0] outfile;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[0]||rng[3];end
 always @(posedge clk)if(rst)begin
  if(held&&(!mv||{frame_id,ms,me,mf,md}!==held_word))$fatal(1,"RGB changed under stall");
  held<=mv&&!mr;held_word<={frame_id,ms,me,mf,md};
  if(mv&&mr)begin
   $fwrite(fd,"%c%c%c%c%c%c",md[7:0],md[15:8],md[23:16],frame_id[7:0],frame_id[15:8],{5'd0,mf,me,ms});received=received+1;
  end
 end
 task command(input integer f,input integer w,input integer h);
 integer coefficient;
 begin
  @(negedge clk);cv=1;cw=w;ch=h;cf=f;pattern=f%4;target=MAX/8;
  for(integer p=0;p<4;p=p+1)levels[p*RAW_BITS+:RAW_BITS]=(p*13+f*7)&MAX;
  gains[15:0]=256+f*16;gains[31:16]=256-f*8;gains[47:32]=256+f*12;gamma_enable=f%2;
  for(integer i=0;i<12;i=i+1)begin
   coefficient=0;
   if(i<9)begin
    if(i==0||i==4||i==8)coefficient=1024;
    else if(f%2)case(i)1:coefficient=128;2:coefficient=-64;3:coefficient=-128;5:coefficient=128;6:coefficient=64;7:coefficient=-128;endcase
   end else if(f%2)case(i)9:coefficient=-5;10:coefficient=3;11:coefficient=7;endcase
   matrix[i*16+:16]=coefficient;
  end
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;cw=1;ch=1;cf=65535;pattern=~pattern;levels=~levels;target=0;gains=0;matrix=0;gamma_enable=~gamma_enable;
 end endtask
 task table_load(input integer f);
 begin
  for(integer c=0;c<3;c=c+1)for(integer a=0;a<256;a=a+1)begin
   @(negedge clk);lv=1;channel=c;address=a;value=c==0?(a*a+127)/255:c==1?255-a:(a+f*7)&255;
   do @(posedge clk);while(!lr);
  end
  @(negedge clk);lv=0;
 end endtask
 task response(input integer expected_error,input integer w,input integer h);
 begin
  wait(rv);@(negedge clk);
  repeat(5)begin
   if(error!=expected_error||ow!=w||oh!=h||!rv)$fatal(1,"response mismatch");
   @(negedge clk);
  end
  rr=1;@(negedge clk);rr=0;
 end endtask
 integer width,height;
 initial begin
  if(!$value$plusargs("output=%s",outfile))$fatal(1,"output required");fd=$fopen(outfile,"wb");
  repeat(4)@(negedge clk);rst=1;
  for(integer f=0;f<7;f=f+1)begin
   width=f==4?320:f==5?640:f==6?3:5;height=f==4?240:f==5?480:f==6?3:5;
   if(f==6)begin command(99,2,3);response(1,0,0);end
   if(f%2)table_load(f);
   command(f,width,height);expected=expected+(width-2)*(height-2);
   for(integer y=0;y<height;y=y+1)for(integer x=0;x<width;x=x+1)begin
    if(!rng[7])@(negedge clk);
    @(negedge clk);sv=1;data=(x*23+y*37+f*57)&MAX;sof=x==0&&y==0;eol=x==width-1;
    do @(posedge clk);while(!sr);
    @(negedge clk);sv=0;
   end
   // Extra data must not enter the next frame while the current frame drains.
   sv=1;data=0;sof=1;eol=1;
   repeat(3)begin @(posedge clk);if(sr)$fatal(1,"accepted beyond configured frame");@(negedge clk);end
   sv=0;
   response(0,width-2,height-2);
  end
  if(received!=expected)$fatal(1,"pixel count mismatch");$fclose(fd);
  $display("PASS ISP core bits=%0d pixels=%0d",RAW_BITS,received);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
