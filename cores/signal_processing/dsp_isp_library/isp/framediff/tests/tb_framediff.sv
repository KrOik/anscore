`timescale 1ns/1ps
// Streaming frame-diff/background testbench. Fixture files (written by
// tests/test_framediff.py):
//   input.mem    : NT words  {tuser<<(BITS+1) | tlast<<BITS | pixel}
//   expected.mem : NT words  same packing
//   config.mem   : NC*3 tokens {trig[31:0], cfgword[50:0], exp[1:0]}
//                  exp bit0 = expect cfg_done, bit1 = expect cfg_error
// cfgword: [12:0]w [25:13]h [27:26]mode [37:28]thresh [41:38]alpha
//          [49:42]scn [50]scpol
// Plusarg mutations (+data/+sideband/+order/+count) corrupt expectations to
// prove checker sensitivity; +order compares against expected[OMUT] (a
// driver-chosen index whose expected word differs from expected[0]).
// Three epochs: full rate, sink stalls, sparse source; each ends with a
// mid-stream synchronous reset. NSCN = expected scn_event pulses/epoch.
module tb_framediff;
parameter BITS=8,MAXW=16,MAXH=12,NT=64,NC=8,NP=192,NSCN=0,OMUT=1,CFGWMIN=1;
localparam CWX=$clog2(MAXW+1),CWY=$clog2(MAXH+1);
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [BITS-1:0] sd=0;
reg [CWX-1:0] cw=0;reg [CWY-1:0] chh=0;
reg [1:0] cmode=0;reg [BITS-1:0] cthr=0;reg [3:0] cal=0;reg [7:0] cscn=0;
reg cpol=0;
wire sr,mv,mu,ml,cr,cd,ce,oe,se,bsy;wire [BITS-1:0] md;
framediff_stream #(.BITS(BITS),.MAX_W(MAXW),.MAX_H(MAXH)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_width(cw),.cfg_height(chh),
 .cfg_mode(cmode),.cfg_thresh(cthr),.cfg_alpha(cal),.cfg_scn(cscn),
 .cfg_scpol(cpol),.cfg_done(cd),.cfg_error(ce),.o_error(oe),
 .scn_event(se),.busy(bsy));
reg [BITS+1:0] inputs[0:NT-1],expected[0:NT-1];
reg [63:0] cfgm[0:3*NC-1];
integer sent,got,cfgi,cycles,epoch,cfgwait,firstcyc,prevout,errcount,secount,i;
integer firsttake;
reg [31:0] rng=32'h1702_2026;
reg held,prev_cfgfire,inputfire;
reg mut_data,mut_order,mut_count,mut_sideband;
reg [BITS+1:0] heldword,observed;
task unpack_cfg;input [50:0] w;
begin
 cw=w[12:0];chh=w[25:13];cmode=w[27:26];cthr=w[37:28];cal=w[41:38];
 cscn=w[49:42];cpol=w[50];
end
endtask
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",cfgm);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
  @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
  if(mv!==0 || oe!==0 || se!==0 || bsy!==0)$fatal(1,"reset control");
  rst=1;
  sent=0;got=0;cfgi=0;cycles=0;held=0;cfgwait=0;firstcyc=-1;firsttake=-1;
  prevout=-1;errcount=0;secount=0;
  while(got<NT || sent<NT)begin
   rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   mr=(epoch==0)?1'b1:((cycles%83<27)?1'b0:rng[0]);
   if(!cv && cfgi<NC && sent>=cfgm[cfgi*3])begin
    cv=1;unpack_cfg(cfgm[cfgi*3+1][50:0]);
   end
   // first pixel waits until at least one config has been accepted
   if(!sv && sent<NT && cfgi>0 && (epoch==0 || rng[2]))begin
    sv=1;{su,sl,sd}=inputs[sent];
   end
   @(posedge clk);
   if(oe)errcount=errcount+1;
   if(se)secount=secount+1;
   if(held && (!mv || {mu,ml,md}!==heldword))$fatal(1,"stall changed output");
   held=mv&&!mr;heldword={mu,ml,md};
   if(cv && !cr)cfgwait=cfgwait+1;
   if(mv&&mr)begin
    observed={mu,ml,md};
    if(mut_data && got==0)observed=observed^1;
    if(mut_sideband && got==0)observed=observed^(1<<(BITS+1));
    if(mut_order && got==0)observed=expected[OMUT];
    if(got>=NT || observed!==expected[got])
     $fatal(1,"framediff mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
    if(epoch==0 && got>0 && cycles-prevout!=1)
     $fatal(1,"output II mismatch index=%0d",got);
    if(got==0)begin
     firstcyc=cycles;
     if(epoch==0 && cycles-firsttake!=2)
      $fatal(1,"first-output latency %0d",cycles-firsttake);
    end
    if(!(mut_count && got==NT-1))got=got+1;
    prevout=cycles;
   end
   inputfire=sv&&sr;
   prev_cfgfire=cv&&cr;
   if(inputfire)begin
    if(sent==0)firsttake=cycles;
    sent=sent+1;
   end
   @(negedge clk);
   if(inputfire)sv=0;
   if(prev_cfgfire)begin
    if(cd!==cfgm[cfgi*3+2][0] || ce!==cfgm[cfgi*3+2][1])
     $fatal(1,"config status idx=%0d done=%b/%b err=%b/%b",cfgi,cd,cfgm[cfgi*3+2][0],ce,cfgm[cfgi*3+2][1]);
    cfgi=cfgi+1;cv=0;
   end else if(cd || ce)$fatal(1,"unsolicited config status");
   cycles=cycles+1;if(cycles>NT*400+30000)$fatal(1,"count timeout");
  end
  sv=0;cv=0;mr=1;
  repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
  if(oe || cfgi!=NC || errcount!=0 || cfgwait<CFGWMIN || secount!=NSCN || bsy)
   $fatal(1,"terminal state: oe=%b cfgi=%0d/%0d err=%0d cfgwait=%0d/%0d scn=%0d/%0d busy=%b",
    oe,cfgi,NC,errcount,cfgwait,CFGWMIN,secount,NSCN,bsy);
  $display("LATENCY epoch=%0d first_output_cycle=%0d scn_events=%0d",epoch,firstcyc,secount);
  // leave an output held mid-frame, then reset into the next epoch
  sent=0;mr=0;cycles=0;
  while(!mv)begin
   if(sent<NP)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
   @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
   cycles=cycles+1;if(cycles>NP*100+1000)$fatal(1,"reset setup timeout");
  end
  sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;mr=0;@(negedge clk);rst=1;
 // Re-arm dims (pending unblocks the stream), then inject an orphan pixel
 // without tuser before any frame: o_error must pulse for one cycle.
 cv=1;unpack_cfg(cfgm[1][50:0]);i=0;
 while(!cd && i<50)begin @(posedge clk);i=i+1;@(negedge clk);end
 cv=0;if(i>=50 || ce)$fatal(1,"orphan-test config not accepted");
 @(negedge clk);sv=1;su=0;sl=0;mr=1;
 @(posedge clk);
 if(!(sv&&sr))$fatal(1,"orphan pixel not accepted");
 @(negedge clk);sv=0;
 if(oe!==1)$fatal(1,"orphan pixel not flagged");
 @(negedge clk);
 if(oe!==0)$fatal(1,"protocol error stuck");
 $display("PASS framediff BITS=%0d MAXW=%0d MAXH=%0d NT=%0d NC=%0d NSCN=%0d epochs=3",
  BITS,MAXW,MAXH,NT,NC,NSCN);
 $finish;
end
endmodule
