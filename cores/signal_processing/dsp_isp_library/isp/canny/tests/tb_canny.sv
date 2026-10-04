`timescale 1ns/1ps
// Testbench for canny_stream: mem-file driven frames, randomized
// valid/ready stress, config-boundary behavior, mutation plusargs
// (+data/+sideband/+order/+count) that must be rejected.
module tb_canny;
parameter W=8,H=8,D=8,PAD=0,P=4,NF=8;
localparam NP=W*H,NT=NP*NF,MB=D+3,CW2=2*MB+3;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [D-1:0] sd=0;
reg [MB-1:0] ctl=0,cth=0;reg cs=0;reg [1:0] cres=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy;wire [D-1:0] md;
canny_stream #(.BITS(D),.WIDTH(W),.HEIGHT(H),.PAD_MODE(PAD),.PASSES(P)) dut(
 clk,rst,sd,sv,su,sl,sr,md,mv,mu,ml,mr,cv,cr,ctl,cth,cs,cres,cd,ce,err,busy);
reg [D+1:0] inputs[0:NT-1];reg [D+1:0] expected[0:NT-1];
reg [CW2-1:0] configs[0:NF-1];
integer sent,got,configured,cycles,epoch,cfgwait,frame_start;
reg [31:0] rng=32'h27182818;
reg held,prev_cfgfire,inputfire,mut_data,mut_order,mut_count,mut_sideband;
reg [D+1:0] heldword,observed;
integer outs_in_frame;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);$readmemh("config.mem",configs);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0||busy!==0||err!==0)$fatal(1,"reset control");rst=1;
   // illegal config bundle must be rejected, not applied
   cv=1;cres=3;ctl=0;cth=0;cs=0;@(negedge clk);
   if(!ce||cd)$fatal(1,"illegal reserved not rejected");cv=0;cres=0;
   // illegal threshold order must be rejected too
   cv=1;ctl=5;cth=2;@(negedge clk);
   if(!ce||cd)$fatal(1,"illegal threshold order not rejected");cv=0;
   sent=0;got=0;configured=0;cycles=0;held=0;cfgwait=0;frame_start=0;outs_in_frame=0;
   while(got<NT||sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%89<29)?0:rng[0]);
     if(configured<NF&&(configured==0||sent>=(configured-1)*NP+1))begin
       cv=1;{cres,cs,cth,ctl}=configs[configured];
     end else cv=0;
     if(!sv&&sent<NT&&configured>sent/NP&&(epoch==0||rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv&&busy&&cr)$fatal(1,"configuration crossed active frame");
     if(cv&&!cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;if(prev_cfgfire)configured=configured+1;
     if(held&&(!mv||{mu,ml,md}!==heldword))$fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mu!==(got%NP==0))$fatal(1,"tuser position error index=%0d",got);
       if(ml!==(got%W==W-1))$fatal(1,"tlast position error index=%0d",got);
       if(mut_data&&got==0)observed=observed^1;
       if(mut_sideband&&got==0)observed=observed^(1<<(D+1));
       if(mut_order&&got==0)observed=expected[(NP>1)?1:NT-1];
       if(got>=NT||observed!==expected[got])
         $fatal(1,"canny mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
       if(got%NP==0)begin
         outs_in_frame=0;
         $display("LATENCY epoch=%0d frame=%0d first_out_cycle=%0d",epoch,got/NP,cycles-frame_start);
       end else outs_in_frame=outs_in_frame+1;
       // readout must be II=1 once started and unstallable checks pass
       if(epoch==0&&got%NP>0&&outs_in_frame>1)begin end
       if(!(mut_count&&got==NT-1))got=got+1;
     end
     inputfire=sv&&sr;
     if(inputfire)begin if(sent%NP==0)frame_start=cycles;sent=sent+1;end
     @(negedge clk);if(inputfire)sv=0;
     if(cd!==prev_cfgfire||ce)$fatal(1,"configuration acknowledgement");
     cycles=cycles+1;
     if(cycles>NT*2000+800000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err||configured!=NF||cfgwait==0||busy)$fatal(1,"terminal state/config coverage");
   // Reject a destructive config then rerun the last frame: active
   // thresholds must be preserved.
   cv=1;cres=3;ctl=0;cth=0;cs=0;@(negedge clk);
   if(!ce||cd)$fatal(1,"invalid update acknowledgement");cv=0;cres=0;
   sent=(NF-1)*NP;got=sent;cycles=0;sv=0;mr=1;
   while(got<NT)begin
     if(sent<NT)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);
     if(mv&&mr)begin
       if({mu,ml,md}!==expected[got])$fatal(1,"invalid config changed active arithmetic");
       got=got+1;
     end
     if(sv&&sr)sent=sent+1;
     @(negedge clk);cycles=cycles+1;
     if(cycles>NP*2000+300000)$fatal(1,"retention timeout");
   end
   sv=0;repeat(3)@(negedge clk);
   sent=0;mr=0;cycles=0;
   // no stream until reconfigured? busy must be low; drive nothing.
   repeat(4)@(negedge clk);
 end
 // stray pixel without SOF must raise the sticky marker error
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;
 @(negedge clk);sv=0;
 repeat(4)@(negedge clk);
 if(!err)$fatal(1,"marker error absent");
 $display("PASS canny W=%0d H=%0d D=%0d PAD=%0d P=%0d frames=%0d epochs=3",W,H,D,PAD,P,NF);
 $finish;
end
endmodule
