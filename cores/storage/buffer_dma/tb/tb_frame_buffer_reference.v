`timescale 1ns/1ps
module tb_frame_buffer_reference;
 parameter FIXED_PINGPONG=1;
 reg clk=0,rst=0;always #5 clk=~clk;
 reg [1:0] wv=0,dest=0,sv=0,sl=0,cr=0,mr=0;
 reg [31:0] fid=0,len=0;
 reg [63:0] sd=0;reg [7:0] sk=8'hff;
 wire [1:0] wr,sr,cv,ce,mv,ml;wire [63:0] md;
 wire [7:0] mk;wire [131:0] desc;
 wire [31:0] published,released,aborted,invalid;
 wire [127:0] reqs,comps,stalls;
 wire [127:0] stream_bytes,stream_frames,stream_stalls,stream_crc,last_cycles,last_crc;
 wire [63:0] latency_last,latency_min,latency_max,latency_sum;
 wire [31:0] elapsed_cycles,allocation_stalls;wire [2:0] peak_occupied;
 reg csr_valid=0,csr_write=0,csr_resp_ready=0;
 reg [7:0] csr_addr=0;reg [31:0] csr_data=0;
 wire csr_ready,csr_resp_valid,csr_resp_error;wire [31:0] csr_resp_data;
 reg [1631:0] captured_metrics;
 frame_buffer_reference #(.SLOT_WORDS(16),.FIXED_PINGPONG(FIXED_PINGPONG)) dut(
 clk,rst,wv,dest,fid,len,wr,sv,sd,sk,sl,sr,cv,ce,cr,mv,mr,md,mk,ml,desc,
 published,released,aborted,invalid,reqs,comps,stalls,
 stream_bytes,stream_frames,stream_stalls,stream_crc,last_cycles,last_crc,
 latency_last,latency_min,latency_max,latency_sum,elapsed_cycles,allocation_stalls,peak_occupied,
 csr_valid,csr_write,csr_addr,csr_data,4'hf,csr_ready,csr_resp_valid,csr_resp_error,csr_resp_data,csr_resp_ready);
 task csr(input bit writing,input [7:0] address,input [31:0] value,input [31:0] expected);
 begin
  @(negedge clk);csr_valid=1;csr_write=writing;csr_addr=address;csr_data=value;
  do @(posedge clk);while(!csr_ready);
  if(writing&&address==0&&value==1)captured_metrics=dut.live_metrics;
  @(negedge clk);csr_valid=0;
  if(!csr_resp_valid||csr_resp_error||csr_resp_data!==expected)$fatal(1,"integrated CSR mismatch");
  repeat(3)begin @(negedge clk);if(!csr_resp_valid||csr_resp_data!==expected)$fatal(1,"CSR stall");end
  csr_resp_ready=1;@(negedge clk);csr_resp_ready=0;
 end endtask
 function [31:0] value(input integer source,frame,offset);
  value=32'h512a309b^(source*32'h17351)^((frame*32'h103397)+(offset*32'h71a3));
 endfunction
 integer tick=0,total=0;
 integer writer_stamp[0:1],slot_stamp[0:3];
 integer ref_last[0:1],ref_min[0:1],ref_max[0:1],ref_sum[0:1];
 integer ref_stalls=0,age,slot_index;
 reg [31:0] rng=32'h9abc1234;
 integer offsets[0:1];reg [63:0] seen=0;
 reg [1:0] held=0;reg [63:0] helddata;reg [131:0] helddesc;reg [1:0] heldlast;
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  mr=tick>300?rng[1:0]:0;
 end
 integer c,f,s,n;
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  for(c=0;c<2;c=c+1)begin
   if(wv[c]&&!wr[c])ref_stalls=ref_stalls+1;
   if(wv[c]&&wr[c])writer_stamp[c]=tick;
   if(dut.av[c]&&dut.ar[c]&&!dut.ae[c])slot_stamp[dut.ab[c*32+:32]/64]=writer_stamp[c];
   if(dut.rd[c]&&dut.rdr[c]&&!dut.re[c])begin
    slot_index=desc[c*66+16+:32]/64;
    age=tick-slot_stamp[slot_index];
    ref_last[c]=age;ref_sum[c]=ref_sum[c]+age;
    if(age<ref_min[c])ref_min[c]=age;
    if(age>ref_max[c])ref_max[c]=age;
   end
   if(held[c]&&(!mv[c]||md[c*32+:32]!==helddata[c*32+:32]||
     desc[c*66+:66]!==helddesc[c*66+:66]||ml[c]!==heldlast[c]))$fatal(1,"stalled output unstable");
   if(mv[c]&&mr[c])begin
    f=desc[c*66+50+:16];s=desc[c*66+49];n=desc[c*66+:16];
    if(f>31||desc[c*66+48]!=c||c!=(s^(f&1))||n!=(f%16)+1||
     md[c*32+:32]!==value(s,f,offsets[c])||mk[c*4+:4]!=15||ml[c]!=(offsets[c]==n-1))
     $fatal(1,"payload/metadata mismatch c=%d frame=%d off=%d",c,f,offsets[c]);
    $display("DMA_READ sink=%0d source=%0d frame=%0d offset=%0d data=%08h",c,s,f,offsets[c],md[c*32+:32]);
    total=total+1;
    if(ml[c])begin
     if(seen[s*32+f])$fatal(1,"duplicate frame");
     seen[s*32+f]=1;offsets[c]=0;
    end else offsets[c]=offsets[c]+1;
   end
  end
  held<=mv&~mr;helddata<=md;helddesc<=desc;heldlast<=ml;
 end
 task automatic writer(input integer source);
 integer frame,i,n;
 begin
  for(frame=0;frame<32;frame=frame+1)begin
   n=frame%16+1;
   @(negedge clk);wv[source]=1;dest[source]=source^(frame&1);
   fid[source*16+:16]=frame;len[source*16+:16]=n;
   do @(posedge clk);while(!wr[source]);
   @(negedge clk);wv[source]=0;
   for(i=0;i<n;i=i+1)begin
    repeat((frame+i)%3)@(negedge clk);
    sv[source]=1;sd[source*32+:32]=value(source,frame,i);sl[source]=i==n-1;
    do @(posedge clk);while(!sr[source]);
    @(negedge clk);sv[source]=0;
   end
   wait(cv[source]);if(ce[source])$fatal(1,"unexpected writer error");
   repeat(3)@(negedge clk);
   cr[source]=1;@(negedge clk);cr[source]=0;
  end
 end endtask
 initial begin
  offsets[0]=0;offsets[1]=0;
  for(integer k=0;k<2;k=k+1)begin ref_last[k]=0;ref_min[k]=32'h7fffffff;ref_max[k]=0;ref_sum[k]=0;end
  repeat(4)@(negedge clk);rst=1;
  fork writer(0);writer(1);join
  wait(released==64);@(negedge clk);
  if(seen!==64'hffffffffffffffff||total!=544||published!=64||aborted!=0||invalid!=0)
   $fatal(1,"final accounting");
  for(integer k=0;k<4;k=k+1)if(reqs[k*32+:32]!=272||comps[k*32+:32]!=272)$fatal(1,"memory accounting");
  for(integer k=0;k<4;k=k+1)begin
   if(stream_bytes[k*32+:32]!=1088||stream_frames[k*32+:32]!=32)$fatal(1,"stream accounting");
   $display("METRIC channel=%0d bytes=%0d frames=%0d stalls=%0d crc=%08h last_cycles=%0d last_crc=%08h",
    k,stream_bytes[k*32+:32],stream_frames[k*32+:32],stream_stalls[k*32+:32],
    stream_crc[k*32+:32],last_cycles[k*32+:32],last_crc[k*32+:32]);
  end
  // Invalid allocation must complete without waiting for payload or leaking a slot.
  wv[0]=1;len[15:0]=0;
  do @(posedge clk);while(!wr[0]);
  @(negedge clk);wv[0]=0;wait(cv[0]);
  if(!ce[0])$fatal(1,"invalid allocation not reported");
  @(negedge clk);cr[0]=1;@(negedge clk);cr[0]=0;
  // A malformed first beat aborts ownership without publishing stale RAM.
  wv[0]=1;len[15:0]=2;
  do @(posedge clk);while(!wr[0]);
  @(negedge clk);wv[0]=0;sv[0]=1;sl[0]=1;
  do @(posedge clk);while(!sr[0]);
  @(negedge clk);sv[0]=0;wait(cv[0]);
  if(!ce[0])$fatal(1,"malformed packet not reported");
  @(negedge clk);cr[0]=1;@(negedge clk);cr[0]=0;
  repeat(20)@(negedge clk);
  if(published!=64||released!=64||aborted!=1||invalid!=1)$fatal(1,"abort accounting");
  if(allocation_stalls!=ref_stalls||peak_occupied!=4||elapsed_cycles!=tick)$fatal(1,"occupancy/time counters");
  for(integer k=0;k<2;k=k+1)begin
   if(latency_last[k*32+:32]!=ref_last[k]||latency_min[k*32+:32]!=ref_min[k]||
     latency_max[k*32+:32]!=ref_max[k]||latency_sum[k*32+:32]!=ref_sum[k])$fatal(1,"latency scoreboard mismatch");
   $display("LATENCY sink=%0d last=%0d min=%0d max=%0d sum=%0d",k,ref_last[k],ref_min[k],ref_max[k],ref_sum[k]);
  end
  csr(1,0,1,0);
  csr(0,0,0,1);
  csr(0,16,0,64); // published
  csr(0,20,0,64); // released
  csr(0,24,0,1);  // aborted
  csr(0,28,0,1);  // invalid requests
  csr(0,216,0,4); // occupancy peak, metric word50
  csr(0,4,0,captured_metrics[48*32+:32]);
  csr(0,8,0,0);
  for(integer k=0;k<51;k=k+1)begin
   csr(0,16+4*k,0,captured_metrics[k*32+:32]);
   $display("CSRDUMP index=%0d value=%08h",k,csr_resp_data);
  end
  csr(0,0,0,1); // verify no intervening capture during the full register dump
  $display("SNAPSHOT id=1 timestamp=%0d",captured_metrics[48*32+:32]);
  $display("PASS integrated DMA fixed=%0d frames=64 words=544 cycles=%0d",FIXED_PINGPONG,tick);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
