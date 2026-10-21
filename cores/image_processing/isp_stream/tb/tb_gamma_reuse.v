`timescale 1ns/1ps
module tb_gamma_reuse;
 reg clk=0,rst=0,cv=0,sv=0,mr=0,rr=0,sof=0,eol=0,eof=0;always #5 clk=~clk;
 reg [511:0] config_words=0;wire [47:0] gains;wire [191:0] matrix;wire ge;
 reg lv=0;reg [1:0] channel=0;reg [7:0] address=0,value=0;wire lr;
 wire cr,sr,mv,ms,me,mf,rv;wire [3:0] error;wire [23:0] md;wire [15:0] mid;
 reg [23:0] sd=0;reg [15:0] id=0;reg [31:0] rng=32'h12345678;
 isp_mode_config modes(config_words,gains,matrix,,ge,,,);
 rgb_color_chain color(clk,rst,cv,cr,gains,matrix,ge,lv,lr,channel,address,value,
 sv,sr,sd,sof,eol,eof,id,mv,mr,md,ms,me,mf,mid,rv,rr,error,);
 integer fd,count=0;reg [1023:0] path;
 reg held=0;reg [42:0] saved;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[0]||rng[3];end
 always @(posedge clk)if(rst)begin
  if(held&&(!mv||{mid,ms,me,mf,md}!==saved))$fatal(1,"mode color output under stall");
  held<=mv&&!mr;saved<={mid,ms,me,mf,md};
  if(mv&&mr)begin count=count+1;$fwrite(fd,"%c%c%c%c%c%c",md[7:0],md[15:8],md[23:16],mid[7:0],mid[15:8],{5'd0,mf,me,ms});end
 end
 integer coefficient;
 initial begin
  if(!$value$plusargs("output=%s",path))$fatal(1,"output missing");fd=$fopen(path,"wb");
  repeat(4)@(negedge clk);rst=1;
  for(integer c=0;c<3;c=c+1)for(integer a=0;a<256;a=a+1)begin
   @(negedge clk);lv=1;channel=c;address=a;value=255-a;
   do @(posedge clk);while(!lr);
  end
  @(negedge clk);lv=0;
  for(integer f=0;f<4;f=f+1)begin
   @(negedge clk);config_words=0;config_words[129]=1;config_words[134]=f[0];config_words[135]=f[1];
   config_words[303:256]={16'd400,16'd200,16'd300};
   for(integer i=0;i<12;i=i+1)begin
    coefficient=0;
    case(i)0,4,8:coefficient=1024;1,5:coefficient=128;2:coefficient=-64;3,7:coefficient=-128;6:coefficient=64;9:coefficient=-5;10:coefficient=3;11:coefficient=7;endcase
    config_words[320+i*16+:16]=coefficient;
   end
   cv=1;id=f;do @(posedge clk);while(!cr);
   @(negedge clk);cv=0;config_words=~config_words; // must not change latched frame
   for(integer p=0;p<16;p=p+1)begin
    sd={8'(f*57+p*17),8'(37+p*13),8'(93+p*9)};sv=1;sof=p==0;eol=p%4==3;eof=p==15;
    do @(posedge clk);while(!sr);@(negedge clk);sv=0;
   end
   do @(posedge clk);while(!rv);
   repeat(5)begin @(negedge clk);if(!rv||error!=0)$fatal(1,"mode color response");end
   rr=1;@(negedge clk);rr=0;
  end
  if(count!=64)$fatal(1,"mode color count");
  // A partial new table must not silently reuse the old active table.
  @(negedge clk);lv=1;channel=0;address=0;value=0;
  do @(posedge clk);while(!lr);@(negedge clk);lv=0;
  config_words=0;config_words[129]=1;cv=1;
  do @(posedge clk);while(!cr);@(negedge clk);cv=0;
  do @(posedge clk);while(!rv);
  if(error!=8||mv||count!=64)$fatal(1,"partial table enabled or lost active guard");
  @(negedge clk);rr=1;@(negedge clk);rr=0;$fclose(fd);
  $display("PASS active Gamma reuse across four frames and partial-new-table rejection;64pixels");$finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
