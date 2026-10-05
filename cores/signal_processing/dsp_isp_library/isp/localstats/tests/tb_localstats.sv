`timescale 1ns/1ps
// ISP-10 regression bench: mem-driven frames, per-frame atomic configs,
// randomized ready/valid fuzz, stall stability, marker checks, mutations.
module tb_localstats;
parameter BITS=8,MAXW=32,MAXH=24,WWM=15,WHM=15,NF=8,NT=1024;
localparam MAXPIX=(1<<BITS)-1;
localparam IW=$clog2(MAXW*MAXH*MAXPIX+1);
localparam ISW=IW+2*BITS;
localparam WSW=$clog2(WWM*WHM*MAXPIX+1);
localparam WSSW=WSW+BITS;
localparam AW=$clog2(WWM*WHM+1);
localparam VW=2*BITS;
localparam CWX=$clog2(MAXW+1);
localparam CWY=$clog2(MAXH+1);
localparam EW=2+BITS+BITS+VW+AW+WSW+WSSW+IW+ISW;
localparam CFGW=8+4+4+CWY+CWX;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [BITS-1:0] sd=0;
reg [7:0] cc=0;reg [3:0] cwh=0,cww=0;reg [CWY-1:0] chh=0;reg [CWX-1:0] cwi=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy;wire [BITS-1:0] md;
wire [IW-1:0] oisum;wire [ISW-1:0] oisq;
wire [WSW-1:0] owsum;wire [WSSW-1:0] owsq;
wire [AW-1:0] oarea;wire [BITS-1:0] omean;wire [VW-1:0] ovar;
integral_stats #(.BITS(BITS),.MAX_W(MAXW),.MAX_H(MAXH),
                 .WIN_W_MAX(WWM),.WIN_H_MAX(WHM)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .m_isum(oisum),.m_isq(oisq),.m_wsum(owsum),.m_wsq(owsq),
 .m_area(oarea),.m_mean(omean),.m_var(ovar),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_img_w(cwi),.cfg_img_h(chh),
 .cfg_win_w(cww),.cfg_win_h(cwh),.cfg_c(cc),
 .cfg_done(cd),.cfg_error(ce),.marker_error(err),.busy(busy));
reg [BITS+1:0] inputs[0:NT-1];
reg [EW-1:0] expected[0:NT-1];
reg [CFGW-1:0] configs[0:NF-1];
reg [31:0] sched[0:NF];
integer sent,got,configured,cycles,epoch,cfgwait,frame_start,previousout,prevfgo;
integer fi,fo,fgo;
reg [31:0] rng=32'h10012026;
reg held,prev_cfgfire,inputfire,mut_data,mut_order,mut_count,mut_sideband;
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
   // Illegal window field must pulse cfg_error, never cfg_done, keep old config.
   cv=1;{cc,cwh,cww,chh,cwi}=configs[0];cww=0;@(negedge clk);
   if(!ce||cd)$fatal(1,"illegal config not rejected");cv=0;
   sent=0;got=0;configured=0;cycles=0;held=0;cfgwait=0;frame_start=0;
   previousout=-1;prevfgo=-1;
   while(got<NT||sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     fo=0;for(fi=0;fi<NF;fi=fi+1)if(sent>=sched[fi+1])fo=fi+1;
     if(configured<NF && sent>=sched[configured])begin
       cv=1;{cc,cwh,cww,chh,cwi}=configs[configured];
     end else cv=0;
     if(!sv&&sent<NT&&fo<configured&&(epoch==0||rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv&&busy&&cr)$fatal(1,"configuration crossed active frame");
     if(cv&&!cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;
     if(prev_cfgfire)configured=configured+1;
     if(held&&(!mv||{mu,ml,md,omean,ovar,oarea,owsum,owsq,oisum,oisq}!==heldword))
       $fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md,omean,ovar,oarea,owsum,owsq,oisum,oisq};
     if(mv&&mr)begin
       observed={mu,ml,md,omean,ovar,oarea,owsum,owsq,oisum,oisq};
       if(mut_data&&got==0)observed=observed^1;
       if(mut_sideband&&got==0)observed=observed^(1<<(EW-1));
       if(mut_order&&got==0)begin
         if(NT>1&&expected[1]!==expected[0])observed=expected[1];
         else observed=expected[0]^1;
       end
       if(got>=NT||observed!==expected[got])
         $fatal(1,"localstats mismatch index=%0d got=%h expected=%h",
                got,observed,expected[got]);
       fgo=0;for(fi=0;fi<NF;fi=fi+1)if(got>=sched[fi+1])fgo=fi+1;
       if(epoch==0&&fgo==prevfgo&&previousout>=0&&cycles-previousout!=1)
         $fatal(1,"output II mismatch at output %0d",got);
       prevfgo=fgo;
       if(epoch==0&&got==0&&cycles-frame_start!=2)
         $fatal(1,"first-output latency %0d",cycles-frame_start);
       if(!(mut_count&&got==NT-1))got=got+1;
       previousout=cycles;
     end
     inputfire=sv&&sr;
     if(inputfire)begin
       if(sent==sched[fo])frame_start=cycles;
       sent=sent+1;
     end
     @(negedge clk);
     if(inputfire)sv=0;
     if(cd!==prev_cfgfire||ce)$fatal(1,"configuration acknowledgement");
     cycles=cycles+1;if(cycles>NT*60+30000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err||configured!=NF||cfgwait==0||busy)
     $fatal(1,"terminal state/config coverage err=%0d cfg=%0d/%0d wait=%0d busy=%0d",
            err,configured,NF,cfgwait,busy);
   // Leave an output held mid-frame before the next epoch reset.
   sent=0;mr=0;cycles=0;
   while(!mv)begin
     if(sent<sched[1])begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>sched[1]*100+1000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;
 sd=inputs[0][BITS-1:0];
 @(negedge clk);sv=0;if(!err)$fatal(1,"marker error absent");
 $display("PASS localstats BITS=%0d MAXW=%0d MAXH=%0d WWM=%0d WHM=%0d frames=%0d out=%0d epochs=3",
          BITS,MAXW,MAXH,WWM,WHM,NF,NT);$finish;
end
endmodule
