`timescale 1ns/1ps
// ISP-12 regression bench: mem-driven frames, per-frame atomic configs,
// randomized valid fuzz, ping-pong result readout checking, held-output and
// marker checks, mid-frame resets, illegal config and checker mutations.
//
// Read pacing contract under test: a completed frame's record bank stays
// valid until the NEXT-next frame starts, so the bench may start frame i+2
// only after frame i's records are fully read (gate on qhead).  Reads then
// overlap the following frame's streaming, exercising the dual-port result
// RAM concurrently with engine writes.
module tb_ispstats;
parameter BITS=8,CH=3,MAXW=32,MAXH=24,NF=8,NT=1024,NR=64;
localparam MPX=(1<<BITS)-1;
localparam FP=MAXW*MAXH;
localparam CNTW=$clog2(FP+1);
localparam SUMW=$clog2(FP*MPX+1);
localparam ENW=$clog2(FP*2*MPX+1);
localparam RW=2*CNTW+3*SUMW+ENW;
localparam IW=CH*BITS;
localparam CWX=$clog2(MAXW+1);
localparam CWY=$clog2(MAXH+1);
localparam CFGW=BITS+4+4+CWY+CWX;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,cv=0;
reg [IW-1:0] sd=0;
reg [CWX-1:0] cwi=0;reg [CWY-1:0] chh=0;reg [3:0] czx=0,czy=0;reg [BITS-1:0] cth=0;
reg [5:0] raddr=0;reg rbank=0;
wire sr,cr,cd,ce,err,busy,rnew,rnb;
wire [RW-1:0] rdata;
wire [1:0] rdone;wire [15:0] rframe;wire [13:0] rcount;
ispstats_stream #(.BITS(BITS),.CH(CH),.MAX_W(MAXW),.MAX_H(MAXH)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .res_addr(raddr),.res_bank(rbank),.res_data(rdata),
 .res_new(rnew),.res_new_bank(rnb),.res_done(rdone),
 .res_frame(rframe),.res_count(rcount),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_img_w(cwi),.cfg_img_h(chh),
 .cfg_zx(czx),.cfg_zy(czy),.cfg_thresh(cth),
 .cfg_done(cd),.cfg_error(ce),.marker_error(err),.busy(busy));
reg [IW+1:0] inputs[0:NT-1];
reg [RW-1:0] expected[0:NR-1];
reg [CFGW-1:0] configs[0:NF-1];
reg [31:0] sched[0:NF],rsched[0:NF];
reg [6:0] qnrec[0:NF-1];reg qbank[0:NF-1];
integer sent,got,configured,cycles,epoch,cfgwait,fcompleted,qhead,qtail,rd_idx,fi,fo;
integer fsel,csel,cfgpoint,reps,rsen,bi,ri;
reg [31:0] rng=32'h12032026;
reg rd_wait,inputfire,prev_cfgfire,prev_rnew;
reg mut_data,mut_order,mut_count,mut_sideband;
reg [RW-1:0] obs;
reg [6:0] last_rq;reg rq_stab;reg [RW-1:0] last_rd;reg [7:0] last_fsel;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",configs);$readmemh("sched.mem",sched);
 $readmemh("rsched.mem",rsched);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;repeat(3)@(negedge clk);
   if(rdone!==0||rnew!==0||busy!==0||err!==0)$fatal(1,"ispstats reset control");
   rst=1;
   // Illegal configs must pulse cfg_error, never cfg_done, keep old config.
   cv=1;{cth,czy,czx,chh,cwi}=configs[0];czx=0;@(negedge clk);
   if(!ce||cd)$fatal(1,"ispstats illegal zones_x not rejected");cv=0;
   cv=1;{cth,czy,czx,chh,cwi}=configs[0];cwi=0;@(negedge clk);
   if(!ce||cd)$fatal(1,"ispstats illegal img_w not rejected");cv=0;
   sent=0;got=0;configured=0;cycles=0;cfgwait=0;fcompleted=0;
   qhead=0;qtail=0;rd_idx=0;rd_wait=0;rq_stab=0;prev_rnew=0;last_fsel=0;
   while(sent<NT||qhead<qtail||rd_wait||configured<NF||fcompleted<NF)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     fo=0;for(fi=0;fi<NF;fi=fi+1)if(sent>=sched[fi+1])fo=fi+1;
     // Present config[i] only once frame i-1 is open (>=1 pixel sent), so a
     // held request provably waits through busy and lands in the gap before
     // frame i -- never early enough to be consumed by frame i-1.
     cfgpoint=(configured==0)?0:(sched[configured-1]+1);
     if(configured<NF&&sent>=cfgpoint)begin
       cv=1;{cth,czy,czx,chh,cwi}=configs[configured];
     end else cv=0;
     // SOF gate: a frame may start only if the frame before last is fully
     // read (its result bank is about to be overwritten by this frame).
     if(!sv&&sent<NT&&fo<configured&&(epoch==0||rng[2])&&
        !(sent==sched[fo]&&fo>qhead+1))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv&&busy&&cr)$fatal(1,"ispstats config crossed frame");
     if(cv&&!cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;
     if(prev_cfgfire)configured=configured+1;
     if(sr!==(rst&&!(cv&&cr)))$fatal(1,"ispstats ready contract");
     // res_new may legitimately fire on consecutive cycles when two small
     // frames complete one cycle apart; the per-frame bookkeeping below
     // verifies exactly one pulse per completed frame in order.
     if(rnew)begin
       if(rnb!==(fcompleted&1))$fatal(1,"ispstats bank mismatch");
       if(!rdone[rnb])$fatal(1,"ispstats done missing");
       fsel=rnb?rframe[15:8]:rframe[7:0];
       csel=rnb?rcount[13:7]:rcount[6:0];
       if(fsel!=fcompleted+(mut_sideband?1:0))
         $fatal(1,"ispstats frame-id mismatch got=%0d exp=%0d",fsel,fcompleted);
       if(csel!=rsched[fcompleted+1]-rsched[fcompleted])
         $fatal(1,"ispstats count mismatch got=%0d",csel);
       qbank[qtail]=rnb;qnrec[qtail]=csel;qtail=qtail+1;
       fcompleted=fcompleted+1;
     end
     // Held readout: with res_addr/res_bank held on a bank whose frame-id is
     // unchanged, res_data must not change between consecutive cycles.
     // Skip cycles whose previous sample is unknown (X->valid transition
     // right after the record write edge is expected read behavior).
     if(rq_stab&&last_rq=={rbank,raddr}&&rdone[rbank]&&(^last_rd)!==1'bx&&
        (rbank?rframe[15:8]:rframe[7:0])==last_fsel&&rdata!==last_rd)
       $fatal(1,"ispstats held output changed rq=%h rdata=%h last=%h rdone=%b rframe=%h got=%0d",
            {rbank,raddr},rdata,last_rd,rdone,rframe,got);
     rq_stab<=(last_rq=={rbank,raddr});last_rq<={rbank,raddr};last_rd<=rdata;
     last_fsel<=(rbank?rframe[15:8]:rframe[7:0]);
     inputfire=sv&&sr;
     if(inputfire)sent=sent+1;
     @(negedge clk);
     if(inputfire)sv=0;
     // Result readout engine: one-cycle-late sample of the issued address.
     if(rd_wait)begin
       obs=rdata;
       if(mut_data&&got==0)obs=obs^1;
       if(mut_order&&got==0)
         obs=(NR>1&&expected[1]!==expected[0])?expected[1]:(expected[0]^1);
       if(got>=NR||obs!==expected[got])
         $fatal(1,"ispstats record mismatch index=%0d got=%h expected=%h",
                got,obs,expected[got]);
       if(!(mut_count&&got==NR-1))got=got+1;
       rd_idx=rd_idx+1;
       if(rd_idx==qnrec[qhead])begin qhead=qhead+1;rd_idx=0;end
       rd_wait=0;
     end
     if(!rd_wait&&qhead<qtail)begin
       raddr=rd_idx[5:0];rbank=qbank[qhead];rd_wait=1;
     end
     cycles=cycles+1;
     if(cycles>NT*100+NR*200+60000)$fatal(1,"ispstats count timeout");
   end
   sv=0;cv=0;
   repeat(8)begin @(posedge clk);if(rnew)$fatal(1,"ispstats extra res_new");@(negedge clk);end
   if(err||configured!=NF||cfgwait==0||busy||fcompleted!=NF||qhead!=NF||qtail!=NF)
     $fatal(1,"ispstats terminal state err=%0d cfg=%0d/%0d wait=%0d busy=%0d fc=%0d q=%0d/%0d",
            err,configured,NF,cfgwait,busy,fcompleted,qhead,qtail);
   if(got!=NR)$fatal(1,"ispstats record count mismatch got=%0d expected=%0d",got,NR);
   // Back-to-back replay of the last frame WITHOUT reconfiguration: the SOF
   // take can coincide with the previous frame's last-pixel commit (no
   // config cycle interposes), exercising the ~wbank done-clearing path.
   sent=sched[NF-1];reps=0;rsen=0;
   while(reps<2)begin
     if(!sv)begin sv=1;{su,sl,sd}=inputs[sent];end
     @(posedge clk);
     if(sv&&sr)begin
       sent=sent+1;
       if(sent==sched[NF])begin reps=reps+1;sent=sched[NF-1];end
     end
     if(rnew)rsen=rsen+1;
     @(negedge clk);if(sv&&sr)sv=0;
   end
   // Wait for both replay frames' res_new pulses.
   cycles=0;
   while(rsen<2)begin
     @(posedge clk);if(rnew)rsen=rsen+1;@(negedge clk);
     cycles=cycles+1;if(cycles>2000)$fatal(1,"ispstats replay timeout");
   end
   // Bank of replay frame 1 = NF&1 (fseq NF), replay frame 2 = ~NF&1 (NF+1).
   if(!rdone[0]||!rdone[1])$fatal(1,"ispstats replay done flags");
   if(((NF&1)==0)?(rframe[7:0]!=(NF&255)):(rframe[15:8]!=(NF&255)))
     $fatal(1,"ispstats replay frame-id A");
   if(((NF&1)==0)?(rframe[15:8]!=((NF+1)&255)):(rframe[7:0]!=((NF+1)&255)))
     $fatal(1,"ispstats replay frame-id B");
   if((rcount[6:0]!=(rsched[NF]-rsched[NF-1]))||
      (rcount[13:7]!=(rsched[NF]-rsched[NF-1])))
     $fatal(1,"ispstats replay record count");
   for(bi=0;bi<2;bi=bi+1)begin
     rbank=((NF&1)==0)?bi:(bi^1);
     for(ri=0;ri<rsched[NF]-rsched[NF-1];ri=ri+1)begin
       raddr=ri[5:0];@(negedge clk);@(negedge clk);
       if(rdata!==expected[rsched[NF-1]+ri])
         $fatal(1,"ispstats replay record mismatch bank=%0d idx=%0d",rbank,ri);
     end
   end
   // Partial frame held mid-stream, then abandoned by the next epoch reset.
   sent=0;cycles=0;
   while(sent<4&&sent<sched[1])begin
     sv=1;{su,sl,sd}=inputs[sent];
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;
     if(cycles>sched[1]*100+1000)$fatal(1,"ispstats reset setup timeout");
   end
   sv=0;
   repeat(4)begin
     @(posedge clk);
     if(!busy)$fatal(1,"ispstats frame-open lost");
     if(rnew)$fatal(1,"ispstats res_new on partial frame");
     @(negedge clk);
   end
 end
 // Malformed marker: missing SOF on the first pixel must stick marker_error.
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;sd=0;
 @(negedge clk);sv=0;if(!err)$fatal(1,"ispstats marker error absent");
 $display("PASS ispstats BITS=%0d CH=%0d MAXW=%0d MAXH=%0d frames=%0d recs=%0d epochs=3",
          BITS,CH,MAXW,MAXH,NF,NR);$finish;
end
endmodule
