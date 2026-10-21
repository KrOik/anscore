`timescale 1ns/1ps
module tb_frame_slots;
 parameter FIXED_PINGPONG=1;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg[3:0] sv=0,sw=0,rr=0;reg[127:0] sa=0,sd=0;reg[15:0] ss=0;
 wire[3:0] sr,rv,re;wire[127:0] rd,requests,completions,stalls;
 wire mv,mw,mready,pv,pe,pr;wire[31:0] ma,md,pd;wire[3:0] ms;
 wire[31:0] reads,writes,errors;reg gate=0;
 wire backend_ready;
 mem_port_arbiter4 arb(clk,rst_n,sv,sw,sa,sd,ss,sr,rv,rd,re,rr,
 mv,mw,ma,md,ms,mready,pv,pd,pe,pr,requests,completions,stalls);
 assign mready=backend_ready&&gate;
 mem_port_bram #(.DEPTH(64)) ram(clk,rst_n,mv&&gate,mw,ma,md,ms,
 backend_ready,pv,pd,pe,pr,reads,writes,errors);
 reg[31:0] rng=32'h37ac81f5;integer cycles=0;
 reg traffic=1,block_backend=0;reg[3:0] hold_responses=0;
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  gate=!block_backend&&(!traffic||rng[4]||rng[11]);rr=(traffic?rng[3:0]:4'hf)&~hold_responses;
 end
 reg[3:0] held=0;reg[127:0] held_data;reg[3:0] held_error;
 reg backend_held=0;reg[68:0] held_request;
 always @(posedge clk)begin
  if(!rst_n)begin held<=0;backend_held<=0;cycles<=0;end
  else begin
   cycles<=cycles+1;
   for(integer ch=0;ch<4;ch=ch+1)if(held[ch]&&
    (!rv[ch]||rd[ch*32+:32]!==held_data[ch*32+:32]||re[ch]!==held_error[ch]))$fatal(1,"response changed under stall");
   if(backend_held&&(!mv||{mw,ma,md,ms}!==held_request))$fatal(1,"backend request changed under stall");
   held<=rv&~rr;held_data<=rd;held_error<=re;
   backend_held<=mv&&!mready;held_request<={mw,ma,md,ms};
  end
 end
 task automatic transact;
 input integer ch;input wr;input[31:0] addr,value;input[3:0] mask;input expected_error;
 output[31:0] result;
 begin
  @(negedge clk);sv[ch]=1;sw[ch]=wr;sa[ch*32+:32]=addr;sd[ch*32+:32]=value;ss[ch*4+:4]=mask;
  @(posedge clk);while(!sr[ch])@(posedge clk);
  @(negedge clk);sv[ch]=0;
  @(posedge clk);while(!(rv[ch]&&rr[ch]))@(posedge clk);
  result=rd[ch*32+:32];if(re[ch]!==expected_error)$fatal(1,"response error ch=%0d addr=%h",ch,addr);
 end endtask

 reg[1:0] wv=0,wdest=0,ar=3,wdone=0,werror=0,dr=0,rdone=0,rerror=0;
 reg[31:0] wf=0,wl=0;wire[1:0] wr,av,ae,wdr,dv,rdr;wire[63:0] ab;wire[131:0] dd;
 wire[31:0] published,released,aborted,invalid;
 frame_slot_manager #(.SLOT_WORDS(16),.FIXED_PINGPONG(FIXED_PINGPONG)) manager(clk,rst_n,wv,wdest,wf,wl,wr,
 av,ae,ab,ar,wdone,werror,wdr,dv,dd,dr,rdone,rerror,rdr,published,released,aborted,invalid,,,,,,,);
 reg[3:0] owned=0;integer peak_slots=0,allocation_stalls=0;
 always @(posedge clk)if(rst_n)begin
  if((owned[0]+{2'd0,owned[1]}+{2'd0,owned[2]}+{2'd0,owned[3]})>peak_slots)
   peak_slots=owned[0]+{2'd0,owned[1]}+{2'd0,owned[2]}+{2'd0,owned[3]};
  if(|(wv&~wr))allocation_stalls=allocation_stalls+1;
  for(integer c=0;c<2;c=c+1)if(wdone[c]&&wdr[c]&&!werror[c])
   $display("PUBLISH sink=%0d source=%0d frame=%0d",wdest[c],c,wf[c*16+:16]);
 end
 function[31:0] pixel_word;
 input integer source,frame,offset;
 begin pixel_word=32'h512a309b^(source*32'h17351)^(frame*32'h103397)+(offset*32'h71a3);end
 endfunction
 task automatic writer;
 input integer source;integer frame,i,n,slot;reg[31:0] result,base;
 begin for(frame=0;frame<32;frame=frame+1)begin
  n=(frame%16)+1;
  @(negedge clk);wv[source]=1;wdest[source]=source^(frame&1);wf[source*16+:16]=frame;wl[source*16+:16]=n;
  @(posedge clk);while(!wr[source])@(posedge clk);
  @(negedge clk);wv[source]=0;
  @(posedge clk);while(!av[source])@(posedge clk);
  if(ae[source])$fatal(1,"allocation rejected");base=ab[source*32+:32];slot=base/64;
  if(slot>3||base%64!=0||owned[slot])$fatal(1,"duplicate/invalid slot allocation");owned[slot]=1;
  if(FIXED_PINGPONG&&slot!=source*2+(frame&1))$fatal(1,"ping-pong bank order");
  for(i=0;i<n;i=i+1)transact(source,1,base+i*4,pixel_word(source,frame,i),15,0,result);
  @(negedge clk);wdone[source]=1;
  @(posedge clk);while(!wdr[source])@(posedge clk);
  @(negedge clk);wdone[source]=0;
 end end endtask
 reg seen[0:63];
 task automatic reader;
 input integer sink;integer f,source,n,i,slot;reg[31:0] result,base;reg[65:0] desc;
 begin
  repeat(300)@(negedge clk);
  for(integer block=0;block<32;block=block+1)begin
   @(negedge clk);dr[sink]=1;
   @(posedge clk);while(!dv[sink])@(posedge clk);
   desc=dd[sink*66+:66];f=desc[65:50];source=desc[49];n=desc[15:0];base=desc[47:16];slot=base/64;
   if(desc[48]!=sink||sink!=(source^(f&1))||f>31||n!=(f%16)+1||seen[source*32+f]||!owned[slot])$fatal(1,"bad descriptor ownership/routing");
   seen[source*32+f]=1;
   @(negedge clk);dr[sink]=0;
   for(i=0;i<n;i=i+1)begin
    transact(sink+2,0,base+i*4,0,0,0,result);
    if(result!==pixel_word(source,f,i))$fatal(1,"slot payload mismatch");
    $display("SLOT_READ sink=%0d source=%0d frame=%0d offset=%0d data=%08h",sink,source,f,i,result);
   end
   @(negedge clk);rdone[sink]=1;
   @(posedge clk);while(!rdr[sink])@(posedge clk);
   owned[slot]=0;
   @(negedge clk);rdone[sink]=0;
  end
 end endtask
 task automatic allocate_req;
 input integer source,tag,length,destination;input expected_error;output[31:0] base;
 begin
  @(negedge clk);wv[source]=1;wdest[source]=destination;wf[source*16+:16]=tag;wl[source*16+:16]=length;
  @(posedge clk);while(!wr[source])@(posedge clk);
  @(negedge clk);wv[source]=0;
  @(posedge clk);while(!av[source])@(posedge clk);
  base=ab[source*32+:32];if(ae[source]!==expected_error)$fatal(1,"allocation error response");
  @(negedge clk);
 end endtask
 task automatic commit;
 input integer source;input error;
 begin @(negedge clk);wdone[source]=1;werror[source]=error;
  @(posedge clk);while(!wdr[source])@(posedge clk);
  @(negedge clk);wdone[source]=0;werror[source]=0;end
 endtask
 reg[31:0] aux_base,held_base;
 initial begin
  for(integer i=0;i<64;i=i+1)seen[i]=0;
  #1;rst_n=1;#1;rst_n=0;repeat(4)@(negedge clk);rst_n=1;
  fork writer(0);writer(1);reader(0);reader(1);join
  for(integer i=0;i<64;i=i+1)if(!seen[i])$fatal(1,"missing descriptor");
  if(owned||published!=64||released!=64||aborted||invalid||reads!=544||writes!=544||errors||peak_slots!=4||allocation_stalls==0)$fatal(1,"slot accounting");
  $display("PASS RTL slot manager + BRAM:64 frames,544 words,two writers/two readers,all4 slots pressure,cycles=%0d",cycles);
  // Hold an allocation response and attempt an early completion.
  ar[0]=0;
  @(negedge clk);wv[0]=1;wf[15:0]=100;wl[15:0]=1;wdest[0]=0;
  @(posedge clk);while(!wr[0])@(posedge clk);
  @(negedge clk);wv[0]=0;wait(av[0]);held_base=ab[31:0];wdone[0]=1;werror[0]=1;
  repeat(5)begin @(negedge clk);if(!av[0]||ab[31:0]!==held_base||wdr[0]||aborted)$fatal(1,"allocation response guard");end
  ar[0]=1;@(posedge clk);@(posedge clk);while(!wdr[0])@(posedge clk);
  @(negedge clk);wdone[0]=0;werror[0]=0;
  if(aborted!=1||published!=64)$fatal(1,"write abort publication");
  allocate_req(0,101,0,0,1,aux_base);allocate_req(1,102,17,1,1,aux_base);
  if(invalid!=2)$fatal(1,"invalid length accounting");
  allocate_req(0,103,1,0,0,aux_base);commit(0,0);
  @(negedge clk);dr[0]=1;@(posedge clk);while(!dv[0])@(posedge clk);
  if(dd[65:50]!=103)$fatal(1,"aborted/invalid descriptor leaked");
  @(negedge clk);dr[0]=0;rdone[0]=1;rerror[0]=1;
  @(posedge clk);while(!rdr[0])@(posedge clk);
  @(negedge clk);rdone[0]=0;rerror[0]=0;
  if(aborted!=2||released!=65||published!=65)$fatal(1,"reader error release");
  // Reset queued and partially written slots together; no stale publications.
  allocate_req(0,104,1,0,0,aux_base);commit(0,0);
  allocate_req(1,105,2,1,0,aux_base);
  @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
  repeat(5)@(negedge clk);
  if(av||dv||published||released||aborted||invalid)$fatal(1,"slot reset state");
  allocate_req(0,106,1,0,0,aux_base);commit(0,1);
  if(aborted!=1||published)$fatal(1,"slot reset recovery");
  $display("PASS slot allocation-response stalls/early completion guard, invalid lengths, writer abort, reader error, queued/partial reset recovery");
  $finish;
 end
 initial begin #2000000;$fatal(1,"slot test timeout");end
endmodule
