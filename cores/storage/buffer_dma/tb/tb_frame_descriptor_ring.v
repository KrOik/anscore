`timescale 1ns/1ps
module tb_frame_descriptor_ring;
 parameter DEPTH=8;
 reg clk=0,rst_n=0,sv=0,mr=0;always #5 clk=~clk;
 reg[65:0] sd=0;wire sr,mv;wire[65:0] md;
 wire[$clog2(DEPTH):0] used,high;wire[31:0] blocked;
 frame_descriptor_ring #(.DEPTH(DEPTH)) dut(clk,rst_n,sd,sv,sr,md,mv,mr,used,high,blocked);
 reg[65:0] golden[0:8191];integer wr=0,rd=0;
 reg held=0,accepted_input=0;reg[65:0] held_data;reg check=1;
 always @(posedge clk)begin
  if(!rst_n)begin held<=0;accepted_input<=0;end
  else begin
   if(used>DEPTH)$fatal(1,"capacity exceeded");
   if(held&&(!mv||md!==held_data))$fatal(1,"descriptor changed while stalled");
   held<=mv&&!mr;held_data<=md;
   accepted_input<=sv&&sr;
   if(sv&&sr)begin golden[wr]=sd;wr=wr+1;end
   if(mv&&mr&&check)begin
    if(rd>=wr||md!==golden[rd])$fatal(1,"descriptor order mismatch index=%d",rd);
    rd=rd+1;
   end
  end
 end
 function[65:0] descriptor;
 input integer n;
 begin descriptor={n[15:0]^16'had73,n[0],n[1],(32'habcd1000+n*32'd64),n[15:0]^16'hbc71};end
 endfunction
 reg[31:0] rng=32'h9fc32a51;
 integer sent=0;
 initial begin
  #1;rst_n=1;#1;rst_n=0;repeat(3)@(negedge clk);rst_n=1;
  // Fill exactly to capacity, including the prefetched output register.
  for(integer i=0;i<DEPTH;i=i+1)begin
   @(negedge clk);sv=1;sd=descriptor(sent);sent=sent+1;
  end
  @(negedge clk);sv=1;sd=descriptor(sent);
  repeat(5)begin @(negedge clk);if(sr||used!=DEPTH)$fatal(1,"full queue accepted extra entry");end
  // Replace one entry at full occupancy while popping one on the same edge.
  mr=1;if(!sr) #1;
  @(negedge clk);sent=sent+1;sv=0;
  while(mv||used!=0)@(negedge clk);
  if(wr!=DEPTH+1||rd!=wr||high!=DEPTH||blocked==0)$fatal(1,"capacity metrics");
  // Hold source payload until accepted while both ends stall independently.
  for(integer i=0;i<12000;i=i+1)begin
   @(negedge clk);
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=rng[3]||rng[7];
   if(!sv||accepted_input)begin sv=rng[0];if(sv)begin sd=descriptor(sent);sent=sent+1;end end
  end
  @(negedge clk); // finish a pending source request before draining
  mr=1;
  if(sv&&!accepted_input)begin @(posedge clk);while(!sr)@(posedge clk);@(negedge clk);end
  sv=0;while(mv||used!=0)@(negedge clk);
  if(rd!=wr||rd<1000)$fatal(1,"random coverage");
  // Reset with a prefetched but unconsumed descriptor; RAM is not cleared.
  mr=0;sv=1;sd=descriptor(16'hbeef);@(negedge clk);sv=0;wait(mv);
  @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
  if(mv||used||high||blocked)$fatal(1,"reset queue state");
  check=0;mr=1;repeat(5)@(negedge clk);if(mv)$fatal(1,"stale descriptor after reset");
  $display("PASS descriptor ring DEPTH=%0d ordered=%0d capacity/full replacement/wrap/stalls/reset",DEPTH,rd);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
