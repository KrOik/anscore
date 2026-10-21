`timescale 1ns/1ps
module tb_convolution;
parameter W=7,H=6,K=3,D=8,PAD=0,NF=16;
localparam NP=W*H,NT=NP*NF,N=K*K;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [N*12-1:0] cc=0;reg signed [31:0] cb=0;reg [5:0] cs=0;reg [D-1:0] sd=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy;wire [D-1:0] md;
convolution_stream #(.BITS(D),.WIDTH(W),.HEIGHT(H),.K(K),.PAD_MODE(PAD)) dut(
 clk,rst,sd,sv,su,sl,sr,md,mv,mu,ml,mr,cv,cr,cc,cb,cs,cd,ce,err,busy);
reg [D+1:0] inputs[0:NT-1],expected[0:NT-1];
reg [N*12+37:0] configs[0:NF-1];
integer sent,got,configured,cycles,epoch,cfgwait,frame_start,previousout,macstart;
reg [31:0] rng=32'h31415926;
reg held,prev_cfgfire,inputfire,mac_pending,mut_data,mut_order,mut_count,mut_sideband;
reg [D+1:0] heldword,observed;
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",expected);$readmemh("config.mem",configs);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0 || busy!==0 || err!==0)$fatal(1,"reset control");rst=1;
   cv=1;cs=63;cc=0;cb=0;@(negedge clk);
   if(!ce || cd)$fatal(1,"illegal shift not rejected");cv=0;
   sent=0;got=0;configured=0;cycles=0;held=0;cfgwait=0;frame_start=0;previousout=-1;mac_pending=0;
   while(got<NT || sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     if(configured<NF && (configured==0 || sent>=(configured-1)*NP+1))begin
       cv=1;{cc,cb,cs}=configs[configured];
     end else cv=0;
     if(!sv && sent<NT && configured>sent/NP && (epoch==0 || rng[2]))begin sv=1;{su,sl,sd}=inputs[sent];end
     @(posedge clk);
     if(cv && busy && cr)$fatal(1,"configuration crossed active frame");
     if(cv && !cr)cfgwait=cfgwait+1;
     prev_cfgfire=cv&&cr;if(prev_cfgfire)configured=configured+1;
     if(held && (!mv || {mu,ml,md}!==heldword))$fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     if(mv && mac_pending)begin
       if(cycles-macstart!=N+1)$fatal(1,"MAC exact latency");mac_pending=0;
     end
     if(dut.wv && dut.ready_window)begin macstart=cycles;mac_pending=1;end
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mut_data && got==0)observed=observed^1;
       if(mut_sideband && got==0)observed=observed^(1<<(D+1));
       if(mut_order && got==0)observed=expected[(NP>1)?1:NP];
       if(got>=NT || observed!==expected[got])$fatal(1,"convolution mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
       if(epoch==0 && got%W>0 && cycles-previousout!=N+1)$fatal(1,"row II mismatch");
       if(got%NP==0)begin
         $display("LATENCY epoch=%0d frame=%0d cycles=%0d",epoch,got/NP,cycles-frame_start);
         if(epoch==0 && cycles-frame_start != W*(1+((K/2<H-1)?K/2:H-1))+(K-1)*(W+K-1)+K-1+4+N+1)
           $fatal(1,"first result latency");
       end
       if(!(mut_count && got==NT-1))got=got+1;
       previousout=cycles;
     end
     inputfire=sv&&sr;
     if(inputfire)begin if(sent%NP==0)frame_start=cycles;sent=sent+1;end
     @(negedge clk);if(inputfire)sv=0;
     if(cd!==prev_cfgfire || ce)$fatal(1,"configuration acknowledgement");
     cycles=cycles+1;if(cycles>NT*250+20000)$fatal(1,"count timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err || configured!=NF || cfgwait==0 || busy)$fatal(1,"terminal state/config coverage");
   // Reject a destructive proposed config, then repeat the last frame without
   // another legal config: numeric oracle proves active settings were preserved.
   cv=1;cs=63;cc=0;cb=32'h7fffffff;@(negedge clk);
   if(!ce || cd)$fatal(1,"invalid update acknowledgement");cv=0;
   sent=(NF-1)*NP;got=sent;cycles=0;sv=0;mr=1;
   while(got<NT)begin
     if(sent<NT)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);
     if(mv&&mr)begin
       if({mu,ml,md}!==expected[got])$fatal(1,"invalid config changed active arithmetic");got=got+1;
     end
     if(sv&&sr)sent=sent+1;
     @(negedge clk);cycles=cycles+1;
     if(cycles>NP*150+1000)$fatal(1,"retention timeout");
   end
   sv=0;repeat(3)@(negedge clk);
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
 $display("PASS convolution W=%0d H=%0d K=%0d D=%0d PAD=%0d frames=%0d epochs=3",W,H,K,D,PAD,NF);$finish;
end
endmodule
