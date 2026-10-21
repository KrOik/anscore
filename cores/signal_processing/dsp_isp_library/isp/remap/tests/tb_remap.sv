`timescale 1ns/1ps
// Geometric-remap testbench.  Fixture files (written by
// tests/test_remap.py):
//   input.mem    : NTI words  {tuser<<(BITS+1) | tlast<<BITS | pixel}
//   expected.mem : NTO words  same packing, on the OUTPUT raster
//   config.mem   : NC*3 tokens {trig[31:0], cfgword[319:0], exp[1:0]}
//                  exp bit0 = expect cfg_done, bit1 = expect cfg_error
//   mesh.mem     : NM*4 tokens {trig, row[4:0], col[4:0], data[53:0], exp}
//                  (5 tokens per entry; exp bit0 = expect l_error)
// cfgword layout: [12:0]iw [25:13]ih [38:26]ow [51:39]oh [54:52]mode
//   [56:55]fill [66:57]border [71:67]lx [76:72]ly [80:77]kx [84:81]ky
//   [85+26k +:26] a_k   [319]clr_mesh
// Plusarg mutations (+data/+sideband/+order/+count) corrupt expectations
// to prove checker sensitivity.  Three epochs: full rate, sink stalls,
// sparse source; each ends with a mid-stream synchronous reset.
// Source offers are additionally gated while a due mesh write is pending
// so mesh data is always committed before the lens drain that needs it.
module tb_remap;
parameter BITS=8,MAXW=16,MAXH=12,LXMAX=17,LYMAX=17,
          NTI=64,NTO=64,NC=8,NM=4,NP=64,OMUT=1,CFGWMIN=1;
localparam CWX=$clog2(MAXW+1),CWY=$clog2(MAXH+1);
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0,lv=0;
reg [BITS-1:0] sd=0;
reg [319:0] cdd=0;
reg [4:0] lrw=0,lcl=0;
reg [53:0] ldd=0;
wire sr,mv,mu,ml,cr,cd,ce,lrdy,le,oe,bsy;
wire [BITS-1:0] md;
remap_stream #(.BITS(BITS),.MAX_W(MAXW),.MAX_H(MAXH),
 .LXMAX(LXMAX),.LYMAX(LYMAX)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_data(cdd),.cfg_done(cd),.cfg_error(ce),
 .l_valid(lv),.l_ready(lrdy),.l_row(lrw),.l_col(lcl),.l_data(ldd),
 .l_error(le),.o_error(oe),.busy(bsy));
reg [BITS+1:0] inputs[0:NTI-1],expected[0:NTO-1];
reg [511:0] cfgm[0:3*NC-1];
reg [63:0] meshm[0:5*NM-1];
integer sent,got,cfgi,lmi,cycles,epoch,cfgwait,firstcyc,errcount,i;
integer firsttake;
reg [31:0] rng=32'h1902_2026;
reg held,prev_cfgfire,prev_lfire,inputfire,svok;
reg mut_data,mut_order,mut_count,mut_sideband;
reg [BITS+1:0] heldword,observed;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",cfgm);$readmemh("mesh.mem",meshm);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
  @(negedge clk);rst=0;sv=0;cv=0;lv=0;mr=0;repeat(3)@(negedge clk);
  if(mv!==0 || oe!==0 || le!==0 || bsy!==0)$fatal(1,"reset control");
  rst=1;
  sent=0;got=0;cfgi=0;lmi=0;cycles=0;held=0;cfgwait=0;firstcyc=-1;
  firsttake=-1;errcount=0;
  while(got<NTO || sent<NTI)begin
   rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   mr=(epoch==0)?1'b1:((cycles%83<27)?1'b0:rng[0]);
   // hold cfg offers and the source while a due mesh write is pending:
   // a lens apply must see a complete mesh at its accept edge
   svok=!(lmi<NM && meshm[lmi*5][31:0]<=sent);
   if(!cv && cfgi<NC && svok && sent>=cfgm[cfgi*3][31:0])begin
    cv=1;cdd=cfgm[cfgi*3+1][319:0];
   end
   if(!lv && lmi<NM && sent>=meshm[lmi*5][31:0])begin
    lv=1;lrw=meshm[lmi*5+1][4:0];lcl=meshm[lmi*5+2][4:0];
    ldd=meshm[lmi*5+3][53:0];
   end
   if(!sv && sent<NTI && cfgi>0 && svok && (epoch==0 || rng[2]))begin
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
    if(mut_order && got==0)observed=expected[OMUT];
    if(got>=NTO || observed!==expected[got])
     $fatal(1,"remap mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
    if(got==0)firstcyc=cycles;
    if(!(mut_count && got==NTO-1))got=got+1;
   end
   inputfire=sv&&sr;
   prev_cfgfire=cv&&cr;
   prev_lfire=lv&&lrdy;
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
   if(prev_lfire)begin
    if(le!==meshm[lmi*5+4][0])
     $fatal(1,"mesh status idx=%0d lerr=%b/%b",lmi,le,meshm[lmi*5+4][0]);
    lmi=lmi+1;lv=0;
   end else if(le)$fatal(1,"unsolicited mesh error");
   cycles=cycles+1;
   if(cycles>NTI*64+NTO*1024+200000)$fatal(1,"count timeout");
  end
  sv=0;cv=0;lv=0;mr=1;
  repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
  if(oe || cfgi!=NC || lmi!=NM || errcount!=0 || cfgwait<CFGWMIN || bsy)
   $fatal(1,"terminal state: oe=%b cfgi=%0d/%0d lmi=%0d/%0d err=%0d cfgwait=%0d/%0d busy=%b",
    oe,cfgi,NC,lmi,NM,errcount,cfgwait,CFGWMIN,bsy);
  $display("LATENCY epoch=%0d first_output_cycle=%0d",epoch,firstcyc);
  // leave an output held mid-drain, then reset into the next epoch.
  // NP = pixel count of the LAST frame (the active config); raw pixels
  // with a single SOF suffice -- marker violations here are ignored.
  sent=0;mr=0;cycles=0;
  while(!mv)begin
   if(sent<NP && !sv)begin sv=1;su=(sent==0);sl=0;sd=sent[BITS-1:0];end
   @(posedge clk);
   inputfire=sv&&sr;
   if(inputfire)sent=sent+1;
   @(negedge clk);
   if(inputfire)sv=0;
   cycles=cycles+1;if(cycles>NTI*64+NTO*1024+200000)$fatal(1,"reset setup timeout");
  end
  sv=0;su=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;lv=0;mr=0;@(negedge clk);rst=1;
 // Re-arm a config (pending unblocks the stream), then inject an orphan
 // pixel without tuser before any frame: o_error must pulse for one cycle.
 cv=1;cdd=cfgm[1][319:0];i=0;
 while(!cd && i<50)begin @(posedge clk);i=i+1;@(negedge clk);end
 cv=0;if(i>=50 || ce)$fatal(1,"orphan-test config not accepted");
 @(negedge clk);sv=1;su=0;sl=0;mr=1;
 @(posedge clk);
 if(!(sv&&sr))$fatal(1,"orphan pixel not accepted");
 @(negedge clk);sv=0;
 if(oe!==1)$fatal(1,"orphan pixel not flagged");
 @(negedge clk);
 if(oe!==0)$fatal(1,"protocol error stuck");
 $display("PASS remap BITS=%0d MAXW=%0d MAXH=%0d NTI=%0d NTO=%0d NC=%0d NM=%0d epochs=3",
  BITS,MAXW,MAXH,NTI,NTO,NC,NM);
 $finish;
end
endmodule
