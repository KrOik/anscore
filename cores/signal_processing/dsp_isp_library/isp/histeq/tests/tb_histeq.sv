`timescale 1ns/1ps
// ISP-11 regression bench: mem-driven frames, per-frame atomic configs,
// randomized ready/valid fuzz, stall stability, marker checks, mutations.
module tb_histeq;
parameter BITS=8,MAXW=32,MAXH=24,NF=8,NT=1024;
localparam EW=BITS+2;
localparam CWX=$clog2(MAXW+1);
localparam CWY=$clog2(MAXH+1);
localparam CFGW=16+2+3+3+CWY+CWX;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [BITS-1:0] sd=0;
reg [CWX-1:0] cwi=0;reg [CWY-1:0] chh=0;
reg [1:0] cmode=0;reg [2:0] ctxl=0,ctyl=0;reg [15:0] cclip=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy;wire [BITS-1:0] md;
histeq_stream #(.BITS(BITS),.MAX_W(MAXW),.MAX_H(MAXH)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_img_w(cwi),.cfg_img_h(chh),
 .cfg_mode(cmode),.cfg_txl(ctxl),.cfg_tyl(ctyl),.cfg_clip(cclip),
 .cfg_done(cd),.cfg_error(ce),.marker_error(err),.busy(busy));
reg [BITS+1:0] inputs[0:NT-1];
reg [EW-1:0] expected[0:NT-1];
reg [CFGW-1:0] configs[0:NF-1];
reg [31:0] sched[0:NF];
reg [1:0] fmode[0:NF-1];
integer sent,got,configured,cycles,epoch,cfgwait,frame_start,previousout,prevfgo;
integer fi,fo,fgo,reqline;
reg [31:0] rng=32'h11072026;
reg held,prev_cfgfire,inputfire,mut_data,mut_order,mut_count,mut_sideband;
reg inopen;
reg [EW-1:0] heldword,observed;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",configs);$readmemh("sched.mem",sched);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0||busy!==0||err!==0)$fatal(1,"reset control");
   rst=1;
   // Two illegal configs must pulse cfg_error, never cfg_done.
   cv=1;{cclip,cmode,ctxl,ctyl,chh,cwi}=configs[0];cmode=3;@(negedge clk);
   if(!ce||cd)$fatal(1,"illegal mode not rejected");cv=0;
   @(negedge clk);
   cv=1;{cclip,cmode,ctxl,ctyl,chh,cwi}=configs[0];
   cmode=2;cclip=0;                // CLAHE with clip=0 is always illegal
   @(negedge clk);
   if(!ce||cd)$fatal(1,"illegal clip not rejected");cv=0;
   sent=0;got=0;configured=0;cycles=0;held=0;cfgwait=0;frame_start=0;
   previousout=-1;prevfgo=-1;inopen=0;
   while(got<NT||sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     fo=0;for(fi=0;fi<NF;fi=fi+1)if(sent>=sched[fi+1])fo=fi+1;
     // Request each frame's config up to 3 pixels early (mid-frame) so
     // cfg_ready backpressure is deterministically exercised; the config
     // can only commit at/after the frame boundary or during build/replay.
     if(configured<NF)begin
       reqline=sched[configured];
       if(configured>0)begin
         // request up to 3 inputs before the frame boundary, but never
         // before the previous frame's first input has been taken --
         // otherwise this config would leapfrog onto that frame.
         // (unsigned-safe: no negative intermediates)
         if(sched[configured]>sched[configured-1]+3)
           reqline=sched[configured]-3;
         else
           reqline=sched[configured-1]+1;
       end
     end else reqline=NT+1;
     if(configured<NF && sent>=reqline)begin
       cv=1;{cclip,cmode,ctxl,ctyl,chh,cwi}=configs[configured];
     end else cv=0;
     if(!sv&&sent<NT&&fo<configured&&(epoch==0||rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv&&cr&&inopen)$fatal(1,"configuration crossed active input frame");
     if(cv&&!cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;
     if(prev_cfgfire)begin fmode[configured]=cmode;configured=configured+1;end
     if(held&&(!mv||{mu,ml,md}!==heldword))
       $fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mut_data&&got==0)observed=observed^1;
       if(mut_sideband&&got==0)observed=observed^(1<<(EW-1));
       if(mut_order&&got==0)begin
         if(NT>1&&expected[1]!==expected[0])observed=expected[1];
         else observed=expected[0]^1;
       end
       if(got>=NT||observed!==expected[got])
         $fatal(1,"histeq mismatch index=%0d got=%h expected=%h",
                got,observed,expected[got]);
       fgo=0;for(fi=0;fi<NF;fi=fi+1)if(got>=sched[fi+1])fgo=fi+1;
       if(epoch==0&&fgo==prevfgo&&previousout>=0&&fmode[fgo]!=2&&
          cycles-previousout!=1)
         $fatal(1,"output II mismatch at output %0d",got);
       prevfgo=fgo;
       if(epoch==0&&got==0&&fmode[0]==0&&cycles-frame_start!=2)
         $fatal(1,"first-output latency %0d",cycles-frame_start);
       if(!(mut_count&&got==NT-1))got=got+1;
       previousout=cycles;
     end
     inputfire=sv&&sr;
     if(inputfire)begin
       if(sent==sched[fo])frame_start=cycles;
       sent=sent+1;
       // inopen: an input frame is partially transmitted (config must
       // never commit while it is).
       inopen=(sent<sched[fo+1])?1:0;
     end
     @(negedge clk);
     if(inputfire)sv=0;
     if(cd!==prev_cfgfire||ce)$fatal(1,"configuration acknowledgement");
     cycles=cycles+1;if(cycles>NT*200+200000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err||configured!=NF||cfgwait==0||busy)
     $fatal(1,"terminal state/config coverage err=%0d cfg=%0d/%0d wait=%0d busy=%0d",
            err,configured,NF,cfgwait,busy);
   // Leave an output held mid-frame before the next epoch reset.
   // Frame 0 is always a streamable mode-0 frame (see test_rtl.py).
   sent=0;mr=0;cycles=0;
   while(!mv)begin
     if(sent<sched[1])begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>sched[1]*100+2000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;
 sd=inputs[0][BITS-1:0];
 @(negedge clk);sv=0;if(!err)$fatal(1,"marker error absent");
 $display("PASS histeq BITS=%0d MAXW=%0d MAXH=%0d frames=%0d out=%0d epochs=3",
          BITS,MAXW,MAXH,NF,NT);$finish;
end
endmodule
