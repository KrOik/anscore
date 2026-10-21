`timescale 1ns/1ps
module tb_rgb_color_chain;
 reg clk=0,rst=0,cmd=0,enable=0,lv=0,sv=0,mr=0,rr=0;
 always #5 clk=~clk;
 reg [47:0] gains=0;reg [191:0] matrix=0;
 reg [1:0] channel=0;reg [7:0] address=0,value=0;
 reg [23:0] data=0;reg sof=0,eol=0,eof=0;reg [15:0] fid=0;
 wire ready,lr,sr,mv,ms,me,mf,rv;wire [23:0] md;wire [15:0] mid;wire [3:0] error;
 rgb_color_chain dut(clk,rst,cmd,ready,gains,matrix,enable,lv,lr,channel,address,value,
 sv,sr,data,sof,eol,eof,fid,mv,mr,md,ms,me,mf,mid,rv,rr,error,);
 reg [31:0] rng=32'h6789abcd;reg held=0;reg [42:0] held_word;
 integer fd,received=0,expected=0,current_frame=-1,tick=0,previous=-1,burst_count=0;
 reg [1023:0] outfile;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=current_frame==0||rng[0]||rng[2];end
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  if(held&&(!mv||{mid,ms,me,mf,md}!==held_word))$fatal(1,"color metadata/data unstable");
  held<=mv&&!mr;held_word<={mid,ms,me,mf,md};
  if(mv&&mr)begin
   $fwrite(fd,"%c%c%c%c%c%c",md[7:0],md[15:8],md[23:16],mid[7:0],mid[15:8],{5'd0,mf,me,ms});received=received+1;
   if(mid==100)begin
    if(previous>=0&&tick!=previous+1)$fatal(1,"color chain bubble");
    previous=tick;burst_count=burst_count+1;
   end
  end
 end
 function integer lut(input integer c,a,f);
  lut=c==0?(a*a+127)/255:c==1?255-a:(a+f*7)&255;
 endfunction
 task table_load(input integer f);
 begin
  for(integer c=0;c<3;c=c+1)for(integer a=0;a<256;a=a+1)begin
   @(negedge clk);lv=1;channel=c;address=a;value=lut(c,a,f);
   do @(posedge clk);while(!lr);
  end
  @(negedge clk);lv=0;
 end endtask
 task command(input integer f,input bit gamma_on);
 integer coefficient;
 begin
  @(negedge clk);cmd=1;enable=gamma_on;
  gains[15:0]=f==2?256:256+f*16;gains[31:16]=f==2?256:256-f*8;gains[47:32]=f==2?256:256+f*12;
  for(integer i=0;i<12;i=i+1)begin
   coefficient=0;
   if(i<9)begin
    if(i==0||i==4||i==8)coefficient=1024;
    else if(f%2)case(i)1:coefficient=128;2:coefficient=-64;3:coefficient=-128;5:coefficient=128;6:coefficient=64;7:coefficient=-128;endcase
   end else if(f%2)case(i)9:coefficient=-5;10:coefficient=3;11:coefficient=7;endcase
   matrix[i*16+:16]=coefficient;
  end
  do @(posedge clk);while(!ready);
  @(negedge clk);cmd=0;gains=0;matrix=0;enable=~enable;
 end endtask
 task response(input integer expected_error);
 begin
  wait(rv);@(negedge clk);
  repeat(5)begin if(!rv||error!=expected_error)$fatal(1,"color response error=%0d",error);@(negedge clk);end
  rr=1;@(negedge clk);rr=0;
 end endtask
 integer width,height;
 initial begin
  if(!$value$plusargs("output=%s",outfile))$fatal(1,"output required");fd=$fopen(outfile,"wb");
  repeat(4)@(negedge clk);rst=1;
  command(0,1);response(8); // incomplete table must not start consuming pixels
  for(integer f=0;f<6;f=f+1)begin
   current_frame=f;if(f%2)table_load(f);
   command(f,f%2);
   width=f==4?320:f==5?640:f==0?16:5;height=f==4?240:f==5?480:f==0?8:3;
   expected=expected+width*height;
   for(integer y=0;y<height;y=y+1)for(integer x=0;x<width;x=x+1)begin
    if(f!=0&&!rng[7])@(negedge clk);
    sv=1;data={8'((x*19+y*31+f*43)&255),8'((x*37+y*17+f*11)&255),8'((x*7+y*53+f*29)&255)};
    sof=x==0&&y==0;eol=x==width-1;eof=eol&&y==height-1;fid=f+100;
    do @(posedge clk);while(!sr);
    @(negedge clk);sv=0;
   end
   response(0);
  end
  if(received!=expected||burst_count!=128)$fatal(1,"color count mismatch");$fclose(fd);
  $display("PASS color chain pixels=%0d isolatedII=1",received);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
