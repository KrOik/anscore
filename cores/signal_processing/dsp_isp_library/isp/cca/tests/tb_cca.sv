`timescale 1ns/1ps
// Streaming CCA testbench. Fixture files (written by tests/test_cca.py):
//   input.mem    : NT words {fe,tuser,tlast,pix}; fe marks the last pixel
//                  of a frame (used only for the in-frame II check)
//   expected.mem : NE words {tuser,tlast,rdata[RW-1:0]}
//   config.mem   : NC*3 tokens {trig[31:0], cfgword[CW-1:0], exp[1:0]}
//                  cfgword = {conn8, height[YW:0], width[XW:0]}
//                  exp bit0 = expect cfg_done, bit1 = expect cfg_error
// Plusarg mutations (+data/+sideband/+order/+count) corrupt expectations to
// prove checker sensitivity. Three epochs: full rate, sink stalls, sparse
// source; a mid-stream reset separates epochs; orphan-pixel protocol check
// at the end.
module tb_cca;
parameter NT=64,NE=8,NC=4,W_MAX=256,H_MAX=256,NL=128,EQT=256,TW=16,TH=12;
localparam XW=(W_MAX>1)?$clog2(W_MAX):1;
localparam YW=(H_MAX>1)?$clog2(H_MAX):1;
localparam LBLW=$clog2(NL+2),AW=$clog2(W_MAX*H_MAX)+1,SW=AW+XW;
localparam RW=LBLW+AW+2*SW+2*XW+2*YW;
localparam CW=XW+YW+3;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,sd=0,mr=0,cv=0;
reg [XW:0] cw=0;reg [YW:0] chh=0;reg cc8=0;
wire sr,mv,mu,ml,cd,ce,oe,bsy;wire [RW-1:0] md;
cca_stream #(.W_MAX(W_MAX),.H_MAX(H_MAX),.NL(NL),.EQT(EQT)) dut(
 .clk(clk),.rst_n(rst),.s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),
 .s_tready(sr),.m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),
 .m_tready(mr),.cfg_valid(cv),.cfg_ready(cr),.cfg_width(cw),
 .cfg_height(chh),.cfg_conn8(cc8),.cfg_done(cd),.cfg_error(ce),
 .o_error(oe),.busy(bsy));
reg [3:0] inputs[0:NT-1];
reg [RW+1:0] expected[0:NE-1];
reg [31:0] cfgm[0:3*NC-1];
integer sent,got,cfgi,cycles,epoch,cfgwait,firstcyc,prevfire,errcount,i;
integer resolve_wait,resolve_max;
reg [31:0] rng=32'h0CCA_2026;
reg held,inputfire,prev_cfgfire,last_fe,fired_once;
reg mut_data,mut_order,mut_count,mut_sideband;
reg [RW+1:0] heldword,observed;
task unpack_cfg;input [CW-1:0] w;
begin
 cw=w[XW:0];chh=w[XW+YW+1:XW+1];cc8=w[XW+YW+2];
end
endtask
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",cfgm);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 resolve_max=0;
 for(epoch=0;epoch<3;epoch=epoch+1)begin
  @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
  if(mv!==0 || oe!==0)$fatal(1,"reset control");
  rst=1;
  sent=0;got=0;cfgi=0;cycles=0;held=0;cfgwait=0;firstcyc=-1;
  errcount=0;prevfire=-1;last_fe=0;fired_once=0;resolve_wait=-1;
  while(got<NE || sent<NT)begin
   rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   mr=(epoch==0)?1'b1:((cycles%83<27)?1'b0:rng[0]);
   if(!cv && cfgi<NC && sent>=cfgm[cfgi*3])begin
    cv=1;unpack_cfg(cfgm[cfgi*3+1][CW-1:0]);
   end
   // first pixel waits until at least one config has been accepted
   if(!sv && sent<NT && cfgi>0 && (epoch!=2 || rng[2]))begin
    sv=1;{su,sl,sd}=inputs[sent][2:0];
   end
   @(posedge clk);
   if(oe)errcount=errcount+1;
   if(held && (!mv || {mu,ml,md}!==heldword))$fatal(1,"stall changed output");
   held=mv&&!mr;heldword={mu,ml,md};
   if(cv && !cr)cfgwait=cfgwait+1;
   if(mv&&mr)begin
    observed={mu,ml,md};
    if(mut_data && got==0)observed=observed^1;
    if(mut_sideband && got==0)observed=observed^(1<<(RW+1));
    if(mut_order && got==0)observed=expected[(NE>1)?1:0];
    if(got>=NE || observed!==expected[got])
     $fatal(1,"cca mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
    if(got==0)firstcyc=cycles;
    if(!(mut_count && got==NE-1))got=got+1;
   end
   inputfire=sv&&sr;
   prev_cfgfire=cv&&cr;
   // in-frame input II check at full rate: consecutive accepts of one
   // frame must be exactly one cycle apart (no bubble inside a frame)
   if(inputfire && epoch==0)begin
    if(fired_once && !last_fe && cycles-prevfire!=1)
     $fatal(1,"input II mismatch pixel=%0d",sent);
    prevfire=cycles;last_fe=inputs[sent][3];fired_once=1;
   end else if(inputfire) begin
    prevfire=cycles;last_fe=inputs[sent][3];fired_once=1;
   end
   // measure last-pixel -> first-emit distance of frame 0 (resolve latency)
   if(last_fe && inputfire && resolve_wait<0)resolve_wait=cycles;
   if(inputfire)sent=sent+1;
   @(negedge clk);
   if(inputfire)sv=0;
   if(prev_cfgfire)begin
    if(cd!==cfgm[cfgi*3+2][0] || ce!==cfgm[cfgi*3+2][1])
     $fatal(1,"config status idx=%0d done=%b/%b err=%b/%b",cfgi,cd,cfgm[cfgi*3+2][0],ce,cfgm[cfgi*3+2][1]);
    cfgi=cfgi+1;cv=0;
   end else if(cd || ce)$fatal(1,"unsolicited config status");
   cycles=cycles+1;if(cycles>NT*400+400000)$fatal(1,"count timeout");
  end
  sv=0;cv=0;mr=1;
  repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
  if(resolve_wait>=0 && firstcyc-resolve_wait>resolve_max)
   resolve_max=firstcyc-resolve_wait;
  if(oe || cfgi!=NC || errcount!=0 || cfgwait==0 || bsy)
   $fatal(1,"terminal state: oe=%b cfgi=%0d/%0d err=%0d cfgwait=%0d busy=%b",
    oe,cfgi,NC,errcount,cfgwait,bsy);
  $display("LATENCY epoch=%0d first_output_cycle=%0d",epoch,firstcyc);
  // Mid-emit stall then reset: drive one complete synthetic frame whose
  // dims match the last legal config (the active one), stall the sink so
  // the first emit beat is held, then reset into the next epoch.
  sent=0;mr=0;cycles=0;
  while(!mv)begin
   if(sent<TW*TH)begin
    sv=1;sd=sent[0]^sent[4];su=(sent==0);sl=(sent%TW==TW-1);
   end else sv=0;
   @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
   cycles=cycles+1;if(cycles>TW*TH*200+400000)$fatal(1,"reset setup timeout");
  end
  sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;mr=0;@(negedge clk);rst=1;
 // Re-arm dims, then inject an orphan pixel without tuser before any frame:
 // o_error must pulse for one cycle.
 cv=1;unpack_cfg(cfgm[1][CW-1:0]);i=0;
 while(!cd && i<50)begin @(posedge clk);i=i+1;@(negedge clk);end
 cv=0;if(i>=50 || ce)$fatal(1,"orphan-test config not accepted");
 @(negedge clk);sv=1;su=0;sl=0;sd=1;mr=1;
 @(posedge clk);
 if(!(sv&&sr))$fatal(1,"orphan pixel not accepted");
 @(negedge clk);sv=0;
 if(oe!==1)$fatal(1,"orphan pixel not flagged");
 @(negedge clk);
 if(oe!==0)$fatal(1,"protocol error stuck");
 $display("PASS cca NT=%0d NE=%0d NC=%0d epochs=3 resolve_gap<=%0d",
          NT,NE,NC,resolve_max);
 $finish;
end
endmodule
