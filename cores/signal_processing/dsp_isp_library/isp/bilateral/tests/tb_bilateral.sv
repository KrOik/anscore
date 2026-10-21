`timescale 1ns/1ps
// Streaming 3x3 bilateral (edge-preserving denoise) testbench.
// Fixture files (written by tests/test_bilateral.py):
//   input.mem    : NT words  {tuser<<(BITS+1) | tlast<<BITS | pixel}
//   expected.mem : NT words  same packing
//   config.mem   : NC*3 tokens {trig[31:0], cfgword[7:0], exp[1:0]}
//                  cfgword={rsvd[7:2],lswap[1],bypass[0]}
//                  exp bit0 = expect cfg_done, bit1 = expect cfg_error
//   luts.mem     : NL*2 tokens {trig[31:0], entry[15:0]}
//                  entry={exp_lt_error[15],addr[14:8],data[7:0]}
// Plusarg mutations (+data/+sideband/+order/+count) corrupt the expectation
// stream to prove checker sensitivity.  Three epochs: full rate, sink
// stalls, sparse source; each ends with a mid-stream synchronous reset.
// Output II is NOT asserted cycle-exact: the reused padded window engine
// emits in capture/replay bursts (see SPEC.md); order/data/held-stability
// are checked instead.
module tb_bilateral;
parameter BITS=8,NT=64,NC=8,NL=8,NP=16,WIDTH=32,HEIGHT=24;
// WCFG/WLT: number of config / lut-write entries that must be consumed
// before the first pixel of frame 0 is released (pre-frame table loads).
parameter WCFG=0,WLT=0;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0,lv=0;
reg [BITS-1:0] sd=0;
reg cbp=0,cls=0;reg [5:0] crs=0;
reg [6:0] la=0;reg [7:0] ltd=0;
wire sr,mv,mu,ml,cr,cd,ce,lr,le,oe;
wire [BITS-1:0] md;
bilateral_stream #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_bypass(cbp),.cfg_lswap(cls),
 .cfg_rsvd(crs),.cfg_done(cd),.cfg_error(ce),
 .lt_valid(lv),.lt_ready(lr),.lt_addr(la),.lt_data(ltd),.lt_error(le),
 .o_error(oe));
reg [BITS+1:0] inputs[0:NT-1],expected[0:NT-1];
reg [31:0] cfgm[0:3*NC-1];
reg [31:0] ltm[0:2*NL-1];
integer sent,got,cfgi,ln,cycles,epoch,cfgwait,firstcyc,errcount,i;
reg [31:0] rng=32'h1807_2026;
reg held,inputfire,prev_cfgfire,prev_ltfire;
reg mut_data,mut_order,mut_count,mut_sideband;
reg [BITS+1:0] heldword,observed;
reg [15:0] le_word;
task unpack_cfg;input [7:0] w;begin cbp=w[0];cls=w[1];crs=w[7:2];end endtask
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",cfgm);$readmemh("luts.mem",ltm);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
  @(negedge clk);rst=0;sv=0;cv=0;lv=0;mr=0;repeat(3)@(negedge clk);
  if(mv!==0 || oe!==0)$fatal(1,"reset control");
  rst=1;
  sent=0;got=0;cfgi=0;ln=0;cycles=0;held=0;cfgwait=0;firstcyc=-1;errcount=0;
  while(got<NT || sent<NT)begin
   rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   mr=(epoch==0)?1'b1:((cycles%83<27)?1'b0:rng[0]);
   if(!cv && cfgi<NC && sent>=cfgm[cfgi*3])begin
    cv=1;unpack_cfg(cfgm[cfgi*3+1][7:0]);
   end
   if(!lv && ln<NL && sent>=ltm[ln*2])begin
    lv=1;le_word=ltm[ln*2+1][15:0];
    la=le_word[14:8];ltd=le_word[7:0];
   end
   if(!sv && sent<NT && cfgi>=WCFG && ln>=WLT && (epoch==0 || rng[2]))begin
    sv=1;{su,sl,sd}=inputs[sent];
   end
   @(posedge clk);
   if(oe)errcount=errcount+1;
   if(held && (!mv || {mu,ml,md}!==heldword))$fatal(1,"stall changed output");
   held=mv&&!mr;heldword={mu,ml,md};
   if(cv && !cr)cfgwait=cfgwait+1;
   if(mv&&mr)begin
    observed={mu,ml,md};
    if(mut_data && got==0)observed=observed^1;
    if(mut_sideband && got==0)observed=observed^(1<<(BITS+1));
    if(mut_order && got==0)observed=expected[(NT>1)?1:0];
    if(got>=NT || observed!==expected[got])
     $fatal(1,"bilateral mismatch index=%0d got=%h expected=%h",
      got,observed,expected[got]);
    if(got==0)firstcyc=cycles;
    if(!(mut_count && got==NT-1))got=got+1;
   end
   inputfire=sv&&sr;
   prev_cfgfire=cv&&cr;
   prev_ltfire=lv&&lr;
   if(inputfire)sent=sent+1;
   @(negedge clk);
   if(inputfire)sv=0;
   if(prev_cfgfire)begin
    if(cd!==cfgm[cfgi*3+2][0] || ce!==cfgm[cfgi*3+2][1])
     $fatal(1,"config status idx=%0d done=%b/%b err=%b/%b",
      cfgi,cd,cfgm[cfgi*3+2][0],ce,cfgm[cfgi*3+2][1]);
    cfgi=cfgi+1;cv=0;
   end else if(cd || ce)$fatal(1,"unsolicited config status");
   if(prev_ltfire)begin
    if(le!==ltm[ln*2+1][15])$fatal(1,"lut write status idx=%0d",ln);
    ln=ln+1;lv=0;
   end else if(le)$fatal(1,"unsolicited lut error");
   cycles=cycles+1;if(cycles>NT*400+30000)$fatal(1,"count timeout");
  end
  sv=0;cv=0;lv=0;mr=1;
  repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
  if(oe || cfgi!=NC || ln!=NL || errcount!=0)
   $fatal(1,"terminal state: oe=%b cfgi=%0d/%0d ln=%0d/%0d err=%0d",
    oe,cfgi,NC,ln,NL,errcount);
  $display("LATENCY epoch=%0d first_output_cycle=%0d cfgwait=%0d",
   epoch,firstcyc,cfgwait);
  // leave an output held mid-frame, then reset into the next epoch
  sent=0;mr=0;cycles=0;
  while(!mv)begin
   if(sent<NP)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
   @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
   cycles=cycles+1;if(cycles>NP*100+10000)$fatal(1,"reset setup timeout");
  end
  sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;lv=0;mr=0;@(negedge clk);rst=1;
 // orphan pixel without tuser: the window marker check must flag it
 @(negedge clk);sv=1;su=0;sl=0;mr=1;
 @(posedge clk);
 if(!(sv&&sr))$fatal(1,"orphan pixel not accepted");
 @(negedge clk);sv=0;
 if(oe!==1)$fatal(1,"orphan pixel not flagged");
 $display("PASS bilateral BITS=%0d NT=%0d NC=%0d NL=%0d epochs=3",
  BITS,NT,NC,NL);
 $finish;
end
endmodule
