`timescale 1ns/1ps
module tb_rmii_frame_stream;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,crs=0,ready=0,blocked=0;reg[1:0] rxd=0;
 wire valid,keep,last;wire[7:0] data;wire[95:0] user;
 wire[31:0] good,bad,overflow,frames,bytes;
 reg[31:0] rng=32'h1badb002;
 rmii_frame_stream dut(clk,rst,crs,rxd,valid,ready,data,keep,last,user,good,bad,overflow,frames,bytes);
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ready=!blocked&&rng[2:0]!=0;
 end
 function[31:0] crcbyte(input[31:0] c,input[7:0] d);
 reg[31:0] x;integer i;
 begin x=c;for(i=0;i<8;i=i+1)x=(x[0]^d[i])?(x>>1)^32'hedb88320:x>>1;crcbyte=x;end endfunction
 task sendbyte(input[7:0] b);integer k;
 begin for(k=0;k<4;k=k+1)begin @(negedge clk);crs=1;rxd=b>>(2*k);end end endtask
 task packet(input integer length,input integer seed,input bit corrupt);
 integer j;reg[31:0] crc;reg[7:0] b;
 begin
  repeat(48)@(negedge clk);
  repeat(7)sendbyte(8'h55);sendbyte(8'hd5);crc=32'hffffffff;
  for(j=0;j<length;j=j+1)begin b=(seed+j*17)&255;sendbyte(b);crc=crcbyte(crc,b);end
  crc=~crc;if(corrupt)crc=crc^1;
  for(j=0;j<4;j=j+1)sendbyte(crc>>(8*j));
  @(negedge clk);crs=0;rxd=0;
 end endtask
 integer observed=0,index=0;
 reg[105:0] held;reg stalled=0;reg[95:0] metadata;reg[63:0] prev_time=0;
 always @(posedge clk)begin
  if(!rst)begin observed=0;index=0;stalled=0;prev_time=0;end
  else begin
   if(stalled&&(!valid||{data,keep,last,user}!==held))$fatal(1,"stream changed under stall");
   stalled=valid&&!ready;held={data,keep,last,user};
   if(valid&&ready)begin
    if(!keep)$fatal(1,"byte keep");
    if(index==0)begin
     metadata=user;if(user[31:0]!=observed||user[95:32]<=prev_time)$fatal(1,"sequence/time");
     prev_time=user[95:32];
    end else if(user!==metadata)$fatal(1,"metadata changed in packet");
    $display("FRAME_BYTE frame=%0d index=%0d data=%0d last=%0d",observed,index,data,last);
    if(last)begin observed=observed+1;index=0;end else index=index+1;
   end
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;
  packet(60,3,0);wait(observed==1);
  packet(257,9,0);wait(observed==2);
  packet(1514,23,0);wait(observed==3);
  packet(60,99,1);repeat(20)@(negedge clk);
  if(bad!=1||observed!=3)$fatal(1,"bad FCS published");
  // Fill both banks, including a held output; third frame must be discarded.
  blocked=1;packet(60,41,0);packet(61,57,0);packet(62,72,0);
  repeat(20)@(negedge clk);
  if(overflow!=1||good!=5||frames!=3)$fatal(1,"bank overflow accounting");
  blocked=0;wait(observed==5);
  repeat(10)@(negedge clk);
  if(bytes!=1952||frames!=5)$fatal(1,"delivered counts %0d",bytes);
  packet(64,81,0);wait(observed==6);
  if(overflow!=1||bad!=1||good!=6)$fatal(1,"recovery counters");
  $display("PASS RMII frame stream:FCS,60..1514byte frames,randomstall,heldbank,overflow,recovery,metadata");$finish;
 end
 initial begin #3000000;$fatal(1,"timeout");end
endmodule
