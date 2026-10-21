`timescale 1ns/1ps
module tb_frame_word_dma;
 parameter WRITE=1;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,start=0,sv=0,mr=0,dr=0;
 reg [31:0] base=0,sd=0;
 reg [15:0] count=0;
 reg [3:0] keep=15;
 reg last=0;
 wire sr,ready,mv,ml,qv,qr,qw,pv,pr,pe,dv,de;
 wire [31:0] md,qa,qd,pd,words,cycles,stalls;
 wire [3:0] mk,qs;
 reg [31:0] tick=0;
 wire gate=(tick%7)!=2&&(tick%7)!=3;
 wire memory_ready;
 frame_word_dma #(.WRITE(WRITE)) dut(clk,rst,start,ready,base,count,
  sv,sr,sd,keep,last,mv,mr,md,mk,ml,qv,qr,qw,qa,qd,qs,pv,pr,pd,pe,dv,dr,de,words,cycles,stalls);
 mem_port_bram #(.DEPTH(64)) ram(clk,rst,qv&&gate,qw,qa,qd,qs,memory_ready,pv,pd,pe,pr,,,);
 assign qr=gate&&memory_ready;
 integer i,n,j,received,requests;
 reg [31:0] held;
 reg holding=0;
 always @(posedge clk)begin
  tick<=tick+1;
  if(qv&&qr)requests<=requests+1;
  if(mv&&!mr)begin
   if(holding&&md!==held)$fatal(1,"output changed under stall");
   held<=md;holding<=1;
  end else holding<=0;
  if(mv&&mr)begin
   if(md!==(32'hac000000+received)||mk!=15||ml!=(received==count-1))$fatal(1,"read mismatch");
   received<=received+1;
  end
 end
 task launch(input integer length,input integer addr);
 begin
  @(negedge clk);base=addr;count=length;start=1;
  while(!ready)@(negedge clk);
  @(negedge clk);start=0;
 end endtask
 task finish(input integer error_expected,input integer word_expected);
 begin
  wait(dv);@(negedge clk);
  if(de!=error_expected||words!=word_expected)$fatal(1,"completion error=%d words=%d",de,words);
  repeat(5)begin @(negedge clk);if(!dv||de!=error_expected)$fatal(1,"completion unstable");end
  dr=1;@(negedge clk);dr=0;
 end endtask
 initial begin
  requests=0;received=0;
  for(i=0;i<64;i=i+1)ram.mem[i]=32'hac000000+i;
  repeat(3)@(negedge clk);rst=1;
  for(n=1;n<=64;n=n*2)begin
   received=0;launch(n,0);
   if(WRITE)begin
    for(j=0;j<n;j=j+1)begin
     repeat(j%3)@(negedge clk);
     sv=1;sd=32'hac000000+j;last=j==n-1;
     do @(posedge clk);while(!sr);
     @(negedge clk);sv=0;
    end
   end else begin
    while(!dv)begin @(negedge clk);mr=(tick%5)==0;end
    mr=0;
    if(received!=n)$fatal(1,"early read completion");
   end
   finish(0,n);
   if(WRITE)for(j=0;j<n;j=j+1)if(ram.mem[j]!==32'hac000000+j)$fatal(1,"write mismatch");
  end
  launch(0,0);finish(1,0);
  launch(1,2);finish(1,0);
  launch(2,32'hfffffffc);finish(1,0);
  launch(1,256);
  if(WRITE)begin
   @(negedge clk);sv=1;last=1;
   do @(posedge clk);while(!sr);
   @(negedge clk);sv=0;
  end
  finish(1,0);
  if(WRITE)begin
   launch(2,0);@(negedge clk);sv=1;last=1;
   do @(posedge clk);while(!sr);
   @(negedge clk);sv=0;finish(1,0);
   launch(1,0);@(negedge clk);sv=1;last=1;keep=7;
   do @(posedge clk);while(!sr);
   @(negedge clk);sv=0;finish(1,0);keep=15;
  end
  $display("PASS word DMA WRITE=%0d words=127 requests=%0d",WRITE,requests);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
