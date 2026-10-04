`timescale 1ns/1ps
// ISP-07 regression bench: mem-driven Bayer frames, per-frame atomic configs,
// randomized ready/valid fuzz, stall stability, marker checks, mutations.
module tb_bayer;
parameter W=32,H=24,D=8,NF=16;
localparam NP=W*H,NT=NP*NF,EW=3*D+2;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [3:0] cres=0;reg [1:0] ccfa=0;reg cox=0,coy=0;reg [D-1:0] sd=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy;wire [3*D-1:0] md;
bayer_demosaic #(.BITS(D),.WIDTH(W),.HEIGHT(H)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_cfa(ccfa),.cfg_ox(cox),.cfg_oy(coy),
 .cfg_reserved(cres),.cfg_done(cd),.cfg_error(ce),
 .marker_error(err),.busy(busy));
reg [D+1:0] inputs[0:NT-1];reg [EW-1:0] expected[0:NT-1];
reg [7:0] configs[0:NF-1];
integer sent,got,configured,cycles,epoch,cfgwait,frame_start,macstart,service;
reg [31:0] rng;
reg held,prev_cfgfire,inputfire,mac_pending,mut_data,mut_order,mut_count,mut_sideband;
reg [EW-1:0] heldword,observed;
initial begin
 rng=32'h0BA7E10 ^ (W*65536+H*256+D);
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);$readmemh("config.mem",configs);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0 || busy!==0 || err!==0)$fatal(1,"reset control");rst=1;
   // Illegal reserved field must pulse cfg_error, never cfg_done.
   cv=1;{cres,ccfa,coy,cox}=configs[0];cres=4'hF;@(negedge clk);
   if(!ce || cd)$fatal(1,"illegal reserved not rejected");cv=0;cres=0;
   sent=0;got=0;configured=0;cycles=0;held=0;cfgwait=0;frame_start=0;mac_pending=0;
   while(got<NT || sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     if(configured<NF && (configured==0 || sent>=(configured-1)*NP+1))begin
       cv=1;{cres,ccfa,coy,cox}=configs[configured];
     end else cv=0;
     if(!sv && sent<NT && configured>sent/NP && (epoch==0 || rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv && busy && cr)$fatal(1,"configuration crossed active frame");
     if(cv && !cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;if(prev_cfgfire)configured=configured+1;
     if(held && (!mv || {mu,ml,md}!==heldword))$fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     // Window-accept -> output latency is exactly one registered stage.
     if(mv && mac_pending)begin
       if(cycles-macstart!=service)$fatal(1,"demosaic service latency");
       mac_pending=0;
     end
     if(dut.wv && dut.wadvance)begin macstart=cycles;mac_pending=1;service=1;end
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mut_data && got==0)observed=observed^1;
       if(mut_sideband && got==0)observed=observed^(1<<(EW-1));
       if(mut_order && got==0)observed=expected[(NT>1)?1:0]^((NT>1)?0:1);
       if(got>=NT || observed!==expected[got])
         $fatal(1,"bayer mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
       if(epoch==0 && got%NP==0)
         $display("LATENCY epoch=%0d frame=%0d cycles=%0d",epoch,got/NP,cycles-frame_start);
       if(!(mut_count && got==NT-1))got=got+1;
     end
     inputfire=sv&&sr;
     if(inputfire)begin if(sent%NP==0)frame_start=cycles;sent=sent+1;end
     @(negedge clk);if(inputfire)sv=0;
     if(cd!==prev_cfgfire || ce)$fatal(1,"configuration acknowledgement");
     cycles=cycles+1;if(cycles>NT*80+30000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err || configured!=NF || cfgwait==0 || busy)
     $fatal(1,"terminal state/config coverage err=%0d cfg=%0d/%0d wait=%0d busy=%0d",
            err,configured,NF,cfgwait,busy);
   // Reject a destructive proposed config, then repeat the last frame without
   // another legal config: numeric oracle proves active settings preserved.
   cv=1;cres=4'hA;ccfa=configs[NF-1][3:2]^2'b11;coy=~configs[NF-1][1];cox=~configs[NF-1][0];
   @(negedge clk);
   if(!ce || cd)$fatal(1,"invalid update acknowledgement");cv=0;cres=0;
   sent=(NF-1)*NP;got=sent;cycles=0;sv=0;mr=1;
   while(got<NT)begin
     if(sent<NT)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);
     if(mv&&mr)begin
       if({mu,ml,md}!==expected[got])
         $fatal(1,"invalid config changed active arithmetic");
       got=got+1;
     end
     if(sv&&sr)sent=sent+1;
     @(negedge clk);cycles=cycles+1;
     if(cycles>NP*150+1000)$fatal(1,"retention timeout");
   end
   sv=0;repeat(3)@(negedge clk);
   // Leave an output held mid-frame before the next epoch reset.
   sent=0;mr=0;cycles=0;
   while(!mv)begin
     if(sent<NP)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>NP*100+1000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;
 sd=inputs[0][D-1:0];
 @(negedge clk);sv=0;if(!err)$fatal(1,"marker error absent");
 $display("PASS bayer W=%0d H=%0d D=%0d frames=%0d out=%0d epochs=3",W,H,D,NF,NT);$finish;
end
endmodule
