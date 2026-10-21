`timescale 1ns/1ps
// ISP-14 regression bench: mem-driven frames, interleaved shadow-config
// writes and atomic commits, randomized valid/ready fuzz, SOF-boundary
// atomicity checks, illegal-config rejections, reset epochs and output
// mutations proving checker sensitivity.
//
// cfgmem entry: {is_commit, expect_err, addr[7:0], wdata[15:0]} (26 bits)
// cfgpos entry: {pause, pos[30:0]} -- entry eligible when sent>=pos; a
// leading pause bit holds off new pixel beats while the group runs.
// doms entry:  expected stat_domain at each cfg_done, in order.
module tb_ccm;
parameter BITS=8,NCFG=1,NT=1,NDOM=1;
localparam PW=3*BITS;
localparam MPX=(1<<BITS)-1;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0,cc=0;
reg [PW-1:0] sd=0;
reg [7:0] ca=0;reg [15:0] cdw=0;
wire sr,mv,mu,ml,cr,cdone,cerr,cpend,sdom,busy;
wire [PW-1:0] md;
ccm_stream #(.BITS(BITS)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_addr(ca),.cfg_wdata(cdw),
 .cfg_commit(cc),.cfg_done(cdone),.cfg_error(cerr),
 .cfg_pending(cpend),.stat_domain(sdom),.busy(busy));
reg [PW+1:0] inputs[0:NT-1];
reg [PW+1:0] expected[0:NT-1];
reg [25:0] cfgmem[0:NCFG-1];
reg [31:0] cfgpos[0:NCFG-1];
reg [7:0] doms[0:NDOM-1];
integer sent,got,cfgi,cycles,epoch,didx;
integer pend_done;             // legal commits not yet applied (0 or 1)
integer pend_err;              // commits expecting a delayed legality error
reg fire_write,fire_commit,held,inputfire,exp_err;
reg mut_data,mut_order,mut_count,mut_sideband;
reg [PW+1:0] heldword,observed;
reg [31:0] rng=32'h14082026;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
 $readmemh("cfg.mem",cfgmem);$readmemh("cfgpos.mem",cfgpos);
 $readmemh("dom.mem",doms);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;cc=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0||busy!==0||cpend!==0||sdom!==0)$fatal(1,"reset control");
   rst=1;
   sent=0;got=0;cfgi=0;didx=0;cycles=0;held=0;pend_done=0;pend_err=0;
   while(got<NT||sent<NT||cfgi<NCFG||pend_done>0||pend_err>0)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     // ---- config script: cv/cc are recomputed every cycle from the
     // current entry; a held cv never survives into an ineligible or
     // commit cycle (that would fire a phantom write and desync cfgi).
     cv=0;
     if(cfgi<NCFG && sent>=cfgpos[cfgi][30:0])begin
       if(cfgmem[cfgi][25])begin
         if(!cc)cc=1;               // one-cycle commit pulse
       end else begin
         cv=1;ca=cfgmem[cfgi][23:16];cdw=cfgmem[cfgi][15:0];
       end
     end
     // ---- pixel source (paused inside pause groups) ----
     if(!sv&&sent<NT&&(epoch==0||rng[2])&&
        !(cfgi<NCFG&&cfgpos[cfgi][31]&&sent>=cfgpos[cfgi][30:0]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     fire_write=cv&&cr;fire_commit=cc;
     if(cfgi<NCFG)exp_err=cfgmem[cfgi][24];
     inputfire=sv&&sr;
     if(held&&(!mv||{mu,ml,md}!==heldword))
       $fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mut_data&&got==0)observed=observed^1;
       if(mut_sideband&&got==0)observed=observed^(1<<(PW+1));
       if(mut_order&&got==0)begin
         if(NT>1&&expected[1]!==expected[0])observed=expected[1];
         else observed=expected[0]^1;
       end
       if(got>=NT||observed!==expected[got])
         $fatal(1,"ccm mismatch index=%0d got=%h expected=%h",
                got,observed,expected[got]);
       if(!(mut_count&&got==NT-1))got=got+1;
     end
     if(inputfire)sent=sent+1;
     @(negedge clk);
     // pulse checks.  cfg_error sources: unmapped write (write edge),
     // header/double commit (commit edge), node legality (delayed by the
     // ~99-cycle serial scan).
     if(cerr)begin
       if(fire_commit&&!exp_err)$fatal(1,"legal commit rejected");
       else if(!fire_commit&&!fire_write)begin
         if(pend_err==0)$fatal(1,"spurious cfg_error");
         pend_err=pend_err-1;
       end
     end
     if(fire_write)begin
       if(cerr!==exp_err)
         $fatal(1,"write outcome entry=%0d err=%0d",cfgi,cerr);
       cfgi=cfgi+1;
     end
     if(fire_commit)begin
       cc=0;
       if(exp_err&&!cerr)pend_err=pend_err+1;   // scan may still reject
       if(!exp_err)pend_done=pend_done+1;
       cfgi=cfgi+1;
     end
     if(cdone)begin
       if(pend_done==0)$fatal(1,"cfg_done without legal commit");
       pend_done=pend_done-1;
       if(sdom!==doms[didx])
         $fatal(1,"stat_domain %0d != expected %0d",sdom,doms[didx]);
       didx=didx+1;
     end
     if(pend_done>0&&!cpend)$fatal(1,"pending apply lost");
     if(inputfire)sv=0;
     cycles=cycles+1;
     if(cycles>NT*400+200000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;cc=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(cpend||pend_done!=0||didx!=NDOM||busy)
     $fatal(1,"terminal state cpend=%0d pend=%0d didx=%0d/%0d busy=%0d",
            cpend,pend_done,didx,NDOM,busy);
   // leave a held output mid-frame, then reset into the next epoch
   sent=0;mr=0;cycles=0;
   while(!mv)begin
     if(sent<NT)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>NT*400+2000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 // post-reset partial frame still works (config defaults restored)
 rst=0;sv=0;cv=0;cc=0;@(negedge clk);rst=1;mr=1;
 sent=0;got=0;cycles=0;
 while(got<8)begin
   if(!sv&&sent<NT)begin sv=1;{su,sl,sd}=inputs[sent];end
   @(posedge clk);
   if(mv&&mr)begin
     if({mu,ml,md}!==expected[got])
       $fatal(1,"post-reset mismatch got=%h expected=%h",{mu,ml,md},expected[got]);
     got=got+1;
   end
   if(sv&&sr)begin sent=sent+1;sv=0;end
   @(negedge clk);
   if(cycles>99999)$fatal(1,"post-reset timeout");
   cycles=cycles+1;
 end
 $display("PASS ccm BITS=%0d frames_out=%0d cfg_entries=%0d dones=%0d epochs=3",
          BITS,NT,NCFG,NDOM);$finish;
end
endmodule
