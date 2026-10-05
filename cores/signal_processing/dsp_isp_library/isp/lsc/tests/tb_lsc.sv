`timescale 1ns/1ps
// Streaming LSC testbench. Fixture files (written by tests/test_lsc.py):
//   input.mem    : NT words  {tuser<<(BITS+1) | tlast<<BITS | pixel}
//   expected.mem : NT words  same packing
//   config.mem   : NC*3 tokens {trig[31:0], cfgword[62:0], exp[1:0]}
//                  exp bit0 = expect cfg_done, bit1 = expect cfg_error
//   gains.mem    : NG*2 tokens {trig[31:0], entry[27:0]}
//                  entry = {exp_gerr[27],phase[26:25],row[24:21],col[20:16],data[15:0]}
// Plusarg mutations (+data/+sideband/+order/+count) corrupt expectations to
// prove checker sensitivity. Three epochs: full rate, sink stalls, sparse
// source; each ends with a mid-stream synchronous reset.
module tb_lsc;
parameter BITS=8,NT=64,NC=8,NG=32,NP=16;
localparam GWM=17,GHM=13;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0,gv=0;
reg [BITS-1:0] sd=0;
reg [12:0] cw=0,chh=0;reg [4:0] cgw=0;reg [3:0] cgh=0,ckx=0,cky=0;
reg cb=0,cgs=0;reg [1:0] co=0;reg [15:0] cgm=0;
reg [1:0] gp=0;reg [3:0] gr=0;reg [4:0] gc=0;reg [15:0] gd=0;
wire sr,mv,mu,ml,cr,cd,ce,grr,ge,oe;wire [BITS-1:0] md;
lsc_stream #(.BITS(BITS),.GW_MAX(GWM),.GH_MAX(GHM)) dut(
 clk,rst,sd,sv,su,sl,sr,md,mv,mu,ml,mr,
 cv,cr,cw,chh,cgw,cgh,ckx,cky,cb,co,cgs,cgm,cd,ce,
 gv,grr,gp,gr,gc,gd,ge,oe);
reg [BITS+1:0] inputs[0:NT-1],expected[0:NT-1];
reg [63:0] cfgm[0:3*NC-1];
reg [31:0] gm[0:2*NG-1];
integer sent,got,cfgi,gn,cycles,epoch,cfgwait,firstcyc,prevout,errcount,i;
reg [31:0] rng=32'h1307_2026;
reg held,prev_cfgfire,inputfire,prev_gfire;
reg mut_data,mut_order,mut_count,mut_sideband;
reg [BITS+1:0] heldword,observed;
reg [62:0] cw_word;
reg [27:0] ge_word;
task unpack_cfg;input [62:0] w;
begin
 cw=w[12:0];chh=w[25:13];cgw=w[30:26];cgh=w[34:31];ckx=w[38:35];
 cky=w[42:39];cb=w[43];co=w[45:44];cgs=w[46];cgm=w[62:47];
end
endtask
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",cfgm);$readmemh("gains.mem",gm);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
  @(negedge clk);rst=0;sv=0;cv=0;gv=0;mr=0;repeat(3)@(negedge clk);
  if(mv!==0 || oe!==0)$fatal(1,"reset control");
  rst=1;
  sent=0;got=0;cfgi=0;gn=0;cycles=0;held=0;cfgwait=0;firstcyc=-1;
  prevout=-1;errcount=0;
  while(got<NT || sent<NT)begin
   rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   mr=(epoch==0)?1'b1:((cycles%83<27)?1'b0:rng[0]);
   if(!cv && cfgi<NC && sent>=cfgm[cfgi*3])begin
    cv=1;unpack_cfg(cfgm[cfgi*3+1][62:0]);
   end
   if(!gv && gn<NG && sent>=gm[gn*2])begin
    gv=1;ge_word=gm[gn*2+1][27:0];
    gp=ge_word[26:25];gr=ge_word[24:21];gc=ge_word[20:16];gd=ge_word[15:0];
   end
   // first pixel waits until at least one config has been accepted
   if(!sv && sent<NT && cfgi>0 && (epoch==0 || rng[2]))begin
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
     $fatal(1,"lsc mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
    if(epoch==0 && got>0 && cycles-prevout!=1)
     $fatal(1,"output II mismatch index=%0d",got);
    if(got==0)firstcyc=cycles;
    if(!(mut_count && got==NT-1))got=got+1;
    prevout=cycles;
   end
   inputfire=sv&&sr;
   prev_cfgfire=cv&&cr;
   prev_gfire=gv&&grr;
   if(inputfire)sent=sent+1;
   @(negedge clk);
   if(inputfire)sv=0;
   if(prev_cfgfire)begin
    if(cd!==cfgm[cfgi*3+2][0] || ce!==cfgm[cfgi*3+2][1])
     $fatal(1,"config status idx=%0d done=%b/%b err=%b/%b",cfgi,cd,cfgm[cfgi*3+2][0],ce,cfgm[cfgi*3+2][1]);
    cfgi=cfgi+1;cv=0;
   end else if(cd || ce)$fatal(1,"unsolicited config status");
   if(prev_gfire)begin
    if(ge!==gm[gn*2+1][27])$fatal(1,"gain write status idx=%0d",gn);
    gn=gn+1;gv=0;
   end else if(ge)$fatal(1,"unsolicited gain error");
   cycles=cycles+1;if(cycles>NT*400+30000)$fatal(1,"count timeout");
  end
  sv=0;cv=0;gv=0;mr=1;
  repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
  if(oe || cfgi!=NC || gn!=NG || errcount!=0 || cfgwait==0)
   $fatal(1,"terminal state: oe=%b cfgi=%0d/%0d gn=%0d/%0d err=%0d cfgwait=%0d",
    oe,cfgi,NC,gn,NG,errcount,cfgwait);
  $display("LATENCY epoch=%0d first_output_cycle=%0d",epoch,firstcyc);
  // leave an output held mid-frame, then reset into the next epoch
  sent=0;mr=0;cycles=0;
  while(!mv)begin
   if(sent<NP)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
   @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
   cycles=cycles+1;if(cycles>NP*100+1000)$fatal(1,"reset setup timeout");
  end
  sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;gv=0;mr=0;@(negedge clk);rst=1;
 // Re-arm dims (pending unblocks the stream), then inject an orphan pixel
 // without tuser before any frame: o_error must pulse for one cycle.
 cv=1;unpack_cfg(cfgm[1][62:0]);i=0;
 while(!cd && i<50)begin @(posedge clk);i=i+1;@(negedge clk);end
 cv=0;if(i>=50 || ce)$fatal(1,"orphan-test config not accepted");
 @(negedge clk);sv=1;su=0;sl=0;mr=1;
 @(posedge clk);
 if(!(sv&&sr))$fatal(1,"orphan pixel not accepted");
 @(negedge clk);sv=0;
 if(oe!==1)$fatal(1,"orphan pixel not flagged");
 @(negedge clk);
 if(oe!==0)$fatal(1,"protocol error stuck");
 $display("PASS lsc BITS=%0d NT=%0d NC=%0d NG=%0d epochs=3",BITS,NT,NC,NG);
 $finish;
end
endmodule
