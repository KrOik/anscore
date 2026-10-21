`timescale 1ns/1ps
module tb_gray_sobel_stream;
 reg clk=0,rst=0,cv=0,sv=0,sof=0,eol=0,mr=0,rr=0,bypass=0;
 always #5 clk=~clk;
 reg [15:0] width=0,height=0,id=0;reg [7:0] data=0;
 wire cr,sr,mv,ms,me,mf,rv;wire [7:0] md;wire [15:0] mid,ow,oh;wire [3:0] error;
 reg [31:0] rng=32'h12345678;integer fd,outputs=0;reg [1023:0] path;
 reg held=0;reg [26:0] saved;
 gray_sobel_stream dut(clk,rst,cv,cr,width,height,id,bypass,sv,sr,data,sof,eol,
 mv,mr,md,ms,me,mf,mid,rv,rr,error,ow,oh,);
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[1]||rng[3];end
 always @(posedge clk)if(rst)begin
  if(held&&(!mv||{mid,ms,me,mf,md}!==saved))$fatal(1,"stalled output changed");
  held<=mv&&!mr;saved<={mid,ms,me,mf,md};
  if(mv&&mr)begin outputs=outputs+1;$fwrite(fd,"%c%c%c%c",md,mid[7:0],mid[15:8],{5'd0,mf,me,ms});end
 end
 task command(input integer f,input integer w,input integer h,input bit mode);
 begin @(negedge clk);cv=1;width=w;height=h;id=f;bypass=mode;
 do @(posedge clk);while(!cr);@(negedge clk);cv=0;
 // Pins changing after acceptance must not change the frame.
 bypass=!mode;id=999;width=1;height=1;
 end endtask
 task response(input integer code,input integer w,input integer h);
 begin do @(posedge clk);while(!rv);repeat(5)begin @(negedge clk);if(!rv||error!=code||ow!=w||oh!=h)$fatal(1,"response mismatch valid=%0d error=%0d/%0d dimensions=%0dx%0d/%0dx%0d",rv,error,code,ow,oh,w,h);end
 rr=1;@(negedge clk);rr=0;end endtask
 integer w,h;
 initial begin
 if(!$value$plusargs("output=%s",path))$fatal(1,"output missing");fd=$fopen(path,"wb");
 repeat(4)@(negedge clk);rst=1;
 command(99,2,5,0);response(1,0,3);
 for(integer f=0;f<4;f=f+1)begin
  w=f==1?320:f==2?640:f==3?3:7;h=f==1?240:f==2?480:f==3?3:6;
  command(f,w,h,f==1||f==3);
  for(integer y=0;y<h;y=y+1)for(integer x=0;x<w;x=x+1)begin
   @(negedge clk);if(!rng[7])@(negedge clk);
   sv=1;data=(x*23+y*37+f*57)&255;sof=x==0&&y==0;eol=x==w-1;
   do @(posedge clk);while(!sr);@(negedge clk);sv=0;
  end
  response(0,w-2,h-2);
 end
 $fclose(fd);$display("PASS Sobel stream pixels=%0d",outputs);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
