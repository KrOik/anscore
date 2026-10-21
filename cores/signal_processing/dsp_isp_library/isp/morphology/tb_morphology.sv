`timescale 1ns/1ps
module tb_morphology;
parameter W=7,H=6,K=3,D=8,PAD=0,NF=32;
localparam NP=W*H,NT=NP*NF;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0,cb=0;
reg [1:0] cop=0;reg [K*K-1:0] cm=0;reg [D-1:0] sd=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy;wire [D-1:0] md;
morphology_stream #(.BITS(D),.WIDTH(W),.HEIGHT(H),.K(K),.PAD_MODE(PAD)) dut(
 clk,rst,sd,sv,su,sl,sr,md,mv,mu,ml,mr,cv,cr,cop,cb,cm,cd,ce,err,busy);
reg [D+1:0] inputs[0:NT-1],expected[0:NT-1];
reg [K*K+2:0] configs[0:NF-1];
integer sent,got,configured,cycles,epoch,cfgwait,firstcycle,frame_start,previousout,i;
reg [31:0] rng=32'h29062026;
reg held,prev_cfgfire,inputfire,mut_data,mut_order,mut_count,mut_sideband;
reg [D+1:0] heldword,observed;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);$readmemh("config.mem",configs);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0 || busy!==0 || err!==0)$fatal(1,"reset control");
   rst=1;
   // Empty structuring element is rejected and must not pulse cfg_done.
   cv=1;cm=0;cop=3;cb=1;@(negedge clk);
   if(!ce || cd)$fatal(1,"empty mask not rejected");cv=0;
   sent=0;got=0;configured=0;cycles=0;held=0;cfgwait=0;frame_start=0;previousout=-1;
   while(got<NT || sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     if(configured<NF && (configured==0 || sent>=(configured-1)*NP+1))begin
       cv=1;{cm,cb,cop}=configs[configured];
     end else cv=0;
     if(!sv && sent<NT && configured>sent/NP && (epoch==0 || rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv && busy && cr)$fatal(1,"configuration crossed active frame");
     if(cv && !cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;
     if(prev_cfgfire)configured=configured+1;
     if(held && (!mv || {mu,ml,md}!==heldword))$fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mut_data && got==0)observed=observed^1;
       if(mut_sideband && got==0)observed=observed^(1<<(D+1));
       if(mut_order && got==0)observed=expected[(NP>1)?1:NP];
       if(got>=NT || observed!==expected[got])$fatal(1,"morph mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
       if(epoch==0 && got%W>0 && cycles-previousout!=1)$fatal(1,"output row II mismatch");
       if(got%NP==0)begin
         $display("LATENCY epoch=%0d frame=%0d cycles=%0d",epoch,got/NP,cycles-frame_start);
         if(epoch==0 && got/NP==0 && cycles-frame_start !=
           W*(1+((K/2<H-1)?K/2:H-1))+(K-1)*(W+K-1)+K-1+5)
           $fatal(1,"single stage first latency");
       end
       // A omitted observer transaction must cause the independent count watchdog.
       if(!(mut_count && got==NT-1))got=got+1;
       previousout=cycles;
     end
     inputfire=sv&&sr;
     if(inputfire)begin if(sent%NP==0)frame_start=cycles;sent=sent+1;end
     @(negedge clk);
     if(inputfire)sv=0;
     if(cd!==prev_cfgfire || ce)$fatal(1,"configuration acknowledgement");
     cycles=cycles+1;if(cycles>NT*180+20000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err || configured!=NF || cfgwait==0 || busy)$fatal(1,"terminal state/config coverage");
   // Leave output held mid-frame before next epoch's reset.
   sent=0;mr=0;cycles=0;
   while(!mv)begin
     if(sent<NP)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>NP*100+1000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;
 @(negedge clk);sv=0;if(!err)$fatal(1,"marker error absent");
 $display("PASS morphology W=%0d H=%0d K=%0d D=%0d PAD=%0d frames=%0d epochs=3",W,H,K,D,PAD,NF);$finish;
end
endmodule
