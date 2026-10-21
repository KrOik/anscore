`timescale 1ns/1ps
module tb_stream_fabric4;
 parameter S_HALF=5,M_HALF=7,PACKETS=64,SEED=32'h317edcad;
 reg sc=0,mc=0,rst=0;
 always #S_HALF sc=~sc;
 always #M_HALF mc=~mc;
 reg [127:0] sd=0;
 reg [15:0] sk=0;
 reg [31:0] su=0;
 reg [3:0] sl=0,sv=0;
 wire [3:0] sr;
 wire [23:0] md;
 wire [2:0] mk;
 wire [7:0] mu;
 wire ml,mv;
 reg mr=0;
 wire [31:0] frames,drops;
 integer packet[0:3],offset[0:3],next_packet[0:3];
 integer i,j,n,len,received=0,out_bytes=0,cycles=0,stalls=0;
 integer source,seq,remaining,output_offset=0,active_user=-1;
 reg [31:0] rng=SEED;
 reg held=0;
 reg [35:0] held_data;
 wire [35:0] current={ml,mu,mk,md};
 function integer length;
  input integer source_id,sequence_id;
  begin length=(source_id*17+sequence_id*13)%61; end
 endfunction
 function [7:0] value;
  input integer source_id,sequence_id,index;
  begin value=(source_id*73+sequence_id*31+index*7)&255; end
 endfunction
 stream_fabric4 dut(sc,mc,rst,sd,sk,su,sl,sv,sr,md,mk,mu,ml,mv,mr,frames,drops);
 initial begin
  for(i=0;i<4;i=i+1) begin packet[i]=0; offset[i]=0; next_packet[i]=0; end
  #1; rst=1; #1; rst=0;
  repeat(4) @(negedge sc); rst=1;
  wait(received==4*PACKETS);
  #1;
  repeat(20) begin @(posedge mc); if(mv) $fatal(1,"extra trailing fabric output"); end
  $finish;
 end
 always @(negedge sc) if(rst) begin
  for(i=0;i<4;i=i+1) if(!sv[i]&&packet[i]<PACKETS&&((cycles+i)%5!=0)) begin
   len=length(i,packet[i]); n=len-offset[i]; if(n>4) n=4;
   sd[i*32+:32]=0; sk[i*4+:4]=(1<<n)-1;
   for(j=0;j<n;j=j+1) sd[i*32+j*8+:8]=value(i,packet[i],offset[i]+j);
   su[i*8+:8]=(i<<6)|packet[i]; sl[i]=(offset[i]+n==len); sv[i]=1;
  end
 end
 always @(posedge sc) if(rst) begin
  // Defer source updates to avoid races with RTL input sampling.
  #1;
  cycles=cycles+1;
  if(cycles>100000) $fatal(1,"fabric timeout");
 end
 reg [3:0] accepted;
 always @(posedge sc) if(rst) begin
  accepted=sv&sr;
  #1;
  for(integer k=0;k<4;k=k+1) if(accepted[k]) begin
   if(sl[k]) begin packet[k]=packet[k]+1; offset[k]=0; end
   else offset[k]=offset[k]+4;
   sv[k]=0;
  end
 end
 always @(negedge mc) if(rst) begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  mr=rng[0]&&(cycles%101>25);
 end
 always @(posedge mc) if(rst) begin
  if(held&&(!mv||current!==held_data)) $fatal(1,"stalled fabric output changed");
  held=mv&&!mr; held_data=current;
  if(mv&&!mr) stalls=stalls+1;
  if(mv&&mr) begin
   source=mu>>6; seq=mu&63;
   if(seq!=next_packet[source]) $fatal(1,"source packet order");
   if(active_user!=-1&&active_user!=mu) $fatal(1,"packet interleaving");
   active_user=mu;
   remaining=length(source,seq)-output_offset;
   n=remaining; if(n>3) n=3;
   if(mk!==((1<<n)-1)) $fatal(1,"keep mismatch");
   if(ml!==(remaining<=3)) $fatal(1,"packet boundary mismatch");
   for(integer b=0;b<n;b=b+1)
    if(md[b*8+:8]!==value(source,seq,output_offset+b)) $fatal(1,"byte mismatch");
   out_bytes=out_bytes+n;
   if(ml) begin
    next_packet[source]=seq+1; received=received+1;
    output_offset=0; active_user=-1;
   end else output_offset=output_offset+n;
   if(received==4*PACKETS) begin
    if(drops!=0||frames!=4*PACKETS||stalls==0) $fatal(1,"metrics frames=%d drops=%d",frames,drops);
    for(integer a=0;a<4;a=a+1) if(next_packet[a]!=PACKETS) $fatal(1,"missing source frames");
    $display("PASS fabric4 packets=%0d bytes=%0d s_cycles=%0d m_stalls=%0d clock_half_ns=%0d/%0d",received,out_bytes,cycles,stalls,S_HALF,M_HALF);
   end
  end
 end
endmodule
