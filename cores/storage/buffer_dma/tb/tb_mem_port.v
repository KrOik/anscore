`timescale 1ns/1ps
module tb_mem_port;
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
 reg free_slot[0:3],published[0:3];integer slot_frame[0:3];
 function[31:0] pixel_word;
 input integer source,frame,offset;
 begin pixel_word=32'h512a309b^(source*32'h17351)^(frame*32'h103397)+(offset*32'h71a3);end
 endfunction
 task automatic writer;
 input integer source;integer frame,i,slot;reg[31:0] result;
 begin for(frame=0;frame<32;frame=frame+1)begin
  slot=source*2+(frame&1);wait(free_slot[slot]);free_slot[slot]=0;
  for(i=0;i<16;i=i+1)transact(source,1,(slot*16+i)*4,pixel_word(source,frame,i),15,0,result);
  slot_frame[slot]=frame;published[slot]=1;
 end end endtask
 task automatic reader;
 input integer source;integer frame,i,slot;reg[31:0] result;
 begin for(frame=0;frame<32;frame=frame+1)begin
  slot=source*2+(frame&1);wait(published[slot]);
  if(slot_frame[slot]!=frame)$fatal(1,"test ownership frame order");
  for(i=0;i<16;i=i+1)begin
   transact(source+2,0,(slot*16+i)*4,0,0,0,result);
   if(result!==pixel_word(source,frame,i))$fatal(1,"frame data mismatch src=%d frame=%d offset=%d",source,frame,i);
   $display("READ source=%0d frame=%0d offset=%0d data=%08h",source,frame,i,result);
  end
  published[slot]=0;free_slot[slot]=1;
 end end endtask
 reg[31:0] result;integer total;
 initial begin
  for(integer i=0;i<4;i=i+1)begin free_slot[i]=1;published[i]=0;slot_frame[i]=-1;end
  #1;rst_n=1;#1;rst_n=0;repeat(4)@(negedge clk);rst_n=1;
  fork writer(0);writer(1);reader(0);reader(1);join
  if(reads!=1024||writes!=1024||errors!=0)$fatal(1,"memory transaction counts");
  for(integer i=0;i<4;i=i+1)if(requests[i*32+:32]!=512||completions[i*32+:32]!=512||stalls[i*32+:32]==0)$fatal(1,"master metrics");
  $display("PASS memory exchange: 2 writers/2 readers,64 test-owned blocks,1024 full words,cycles=%0d",cycles);
  traffic=0;
  transact(0,1,0,32'h11223344,15,0,result);transact(1,1,0,32'haabbccdd,5,0,result);
  transact(2,0,0,0,0,0,result);if(result!==32'h11bb33dd)$fatal(1,"byte strobes");
  transact(0,1,0,0,0,0,result);transact(3,0,0,0,0,0,result);if(result!==32'h11bb33dd)$fatal(1,"zero strobe write");
  transact(0,1,1,0,15,1,result);transact(1,1,256,0,15,1,result);
  transact(2,0,32'h80000000,0,0,1,result);transact(3,0,2,0,0,1,result);
  transact(2,0,0,0,0,0,result);if(result!==32'h11bb33dd||errors!=4)$fatal(1,"bad address aliases RAM");
  // Abort an already-buffered response, without clearing memory.
  hold_responses=4'b0100;
  @(negedge clk);sv[2]=1;sw[2]=0;sa[95:64]=0;ss[11:8]=0;
  @(posedge clk);while(!sr[2])@(posedge clk);
  @(negedge clk);sv[2]=0;wait(rv[2]);repeat(3)@(negedge clk);
  rst_n=0;repeat(3)@(negedge clk);rst_n=1;hold_responses=0;
  if(rv!=0||pv)$fatal(1,"pending response survived reset");
  transact(2,0,0,0,0,0,result);if(result!==32'h11bb33dd)$fatal(1,"RAM reset persistence");
  // Reject a reset-time unaccepted write rather than leaking it after reset.
  block_backend=1;repeat(2)@(negedge clk);
  sv[0]=1;sw[0]=1;sa[31:0]=0;sd[31:0]=0;ss[3:0]=15;
  wait(mv);repeat(3)@(negedge clk);rst_n=0;sv=0;
  repeat(3)@(negedge clk);rst_n=1;block_backend=0;
  transact(3,0,0,0,0,0,result);if(result!==32'h11bb33dd)$fatal(1,"unaccepted write crossed reset");
  $display("PASS byte masks, unaligned/out-of-range rejection, no address alias, reset persistence, stalled request/response stability");$finish;
 end
 initial begin #2000000;$fatal(1,"test timeout");end
endmodule

