`timescale 1ns/1ps
// ISP-08 regression bench: mem-driven frames, per-frame atomic configs,
// randomized ready/valid fuzz, stall stability, marker checks, AWB stat
// checks, negative mutations.  Geometry is STATIC (WIDTH x HEIGHT) because
// the DPC window foundation is fixed-parameter.
module tb_basic_isp;
parameter BITS=8,CH=3,W=32,H=24,NF=8,NT=1024;
localparam PW=CH*BITS;
localparam MAXPIX=(1<<BITS)-1;
localparam FP=W*H;
localparam SUMW=$clog2(FP*MAXPIX+1);
localparam CWX=(W<1)?1:$clog2(W+1);
localparam CWY=(H<1)?1:$clog2(H+1);
localparam CFGW=CWX+CWY+3*BITS+36+BITS+2;
localparam AWW=3*SUMW;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [PW-1:0] sd=0;
reg [CWX-1:0] cwi=0;reg [CWY-1:0] chh=0;
reg [3*BITS-1:0] cblc=0;reg [35:0] cwb=0;
reg [BITS-1:0] cthr=0;reg [1:0] cgs=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy,anew;
wire [PW-1:0] md;
wire [SUMW-1:0] as0,as1,as2;wire [7:0] afrm;
basic_isp_top #(.BITS(BITS),.CH(CH),.WIDTH(W),.HEIGHT(H)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_img_w(cwi),.cfg_img_h(chh),
 .cfg_blc(cblc),.cfg_wb(cwb),.cfg_dpc_thr(cthr),.cfg_gamma_sel(cgs),
 .cfg_done(cd),.cfg_error(ce),
 .awb_sum0(as0),.awb_sum1(as1),.awb_sum2(as2),.awb_new(anew),
 .awb_frame(afrm),.marker_error(err),.busy(busy));
reg [PW+1:0] inputs[0:NT-1];
reg [PW+1:0] expected[0:NT-1];
reg [CFGW-1:0] configs[0:NF-1];
reg [AWW-1:0] awbs[0:NF-1];
reg [31:0] sched[0:NF];
integer sent,got,configured,cycles,epoch,cfgwait,awb_seen;
integer fi,fo;
reg [31:0] rng=32'h08262026;
reg held,prev_cfgfire,inputfire,mut_data,mut_order,mut_count,mut_sideband;
reg [PW+1:0] heldword,observed;
reg [AWW-1:0] awbword;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("config.mem",configs);$readmemh("awb.mem",awbs);
 $readmemh("sched.mem",sched);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0||busy!==0||err!==0)$fatal(1,"reset control");
   rst=1;
   // Illegal geometry/gamma fields must pulse cfg_error, never cfg_done.
   cv=1;{cwi,chh,cblc,cwb,cthr,cgs}=configs[0];cgs=2'd3;@(negedge clk);
   if(!ce||cd)$fatal(1,"illegal gamma_sel not rejected");
   cwi=cwi+1'b1;@(negedge clk);
   if(!ce||cd)$fatal(1,"illegal img_w not rejected");cv=0;
   sent=0;got=0;configured=0;cycles=0;held=0;cfgwait=0;awb_seen=0;
   while(got<NT||sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     fo=0;for(fi=0;fi<NF;fi=fi+1)if(sent>=sched[fi+1])fo=fi+1;
     if(configured<NF && sent>=sched[configured])begin
       cv=1;{cwi,chh,cblc,cwb,cthr,cgs}=configs[configured];
     end else cv=0;
     if(!sv&&sent<NT&&fo<configured&&(epoch==0||rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv&&busy&&cr)$fatal(1,"configuration crossed active frame");
     if(cv&&!cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;
     if(prev_cfgfire)configured=configured+1;
     if(held&&(!mv||{mu,ml,md}!==heldword))
       $fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     if(anew)begin
       awbword={as2,as1,as0};
       if(awb_seen>=NF||awbword!==awbs[awb_seen])
         $fatal(1,"awb mismatch frame=%0d got=%h expected=%h",
                awb_seen,awbword,awbs[awb_seen>0?awb_seen-1:0]);
       if(afrm!=awb_seen[7:0]+8'd1)
         $fatal(1,"awb frame seq %0d != %0d",afrm,awb_seen+1);
       awb_seen=awb_seen+1;
     end
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mut_data&&got==0)observed=observed^1;
       if(mut_sideband&&got==0)observed=observed^(1<<(PW+1));
       if(mut_order&&got==0)begin
         if(NT>1&&expected[1]!==expected[0])observed=expected[1];
         else observed=expected[0]^1;
       end
       if(got>=NT||observed!==expected[got])
         $fatal(1,"basic_isp mismatch index=%0d got=%h expected=%h",
                got,observed,expected[got]);
       if(!(mut_count&&got==NT-1))got=got+1;
     end
     inputfire=sv&&sr;
     if(inputfire)sent=sent+1;
     @(negedge clk);
     if(inputfire)sv=0;
     if(cd!==prev_cfgfire||ce)$fatal(1,"configuration acknowledgement");
     cycles=cycles+1;if(cycles>NT*200+60000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err||configured!=NF||cfgwait==0||busy||awb_seen!=NF)
     $fatal(1,"terminal state err=%0d cfg=%0d/%0d wait=%0d busy=%0d awb=%0d/%0d",
            err,configured,NF,cfgwait,busy,awb_seen,NF);
   // Leave an output held mid-frame before the next epoch reset.
   sent=0;mr=0;cycles=0;
   while(!mv)begin
     if(sent<sched[1])begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>sched[1]*400+2000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;
 sd=inputs[0][PW-1:0];
 @(negedge clk);sv=0;repeat(10)@(negedge clk);
 if(!err)$fatal(1,"marker error absent");
 $display("PASS basic_isp BITS=%0d CH=%0d W=%0d H=%0d frames=%0d out=%0d epochs=3",
          BITS,CH,W,H,NF,NT);$finish;
end
endmodule
