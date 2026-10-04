`timescale 1ns/1ps
// Randomized-protocol regression for chroma_420.
// input.mem    : {tuser,tlast,data} per input beat
//                SRC=0 -> data = {Y,Cb,Cr} 3D-bit 4:4:4 pixel
//                SRC=1 -> data = {Ye,Cb,Yo,Cr} 4D-bit 4:2:2 pair word
// expected.mem : {tuser,tlast,word[2D+1]} tagged beats, tag in bit 2D
// config.mem   : siting[1:0] programmed before each frame
module tb_chroma420;
parameter W=7,H=6,D=8,NF=4,SRC=0;
localparam IW=(SRC==1)?4*D:3*D;
localparam NP=(SRC==1)?(W+1)/2*H:W*H;    // input beats per frame
localparam OW=(W+1)/2;
localparam NOF=OW*(H+(H+1)/2);           // output beats per frame
localparam NT=NP*NF,NOUT=NOF*NF;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0,cv=0;
reg [IW-1:0] sd=0; reg [1:0] cs=0;
wire sr,mv,mu,ml,cr,cd,ce,err,busy;wire [2*D:0] md;
chroma_420 #(.BITS(D),.WIDTH(W),.HEIGHT(H),.SRC422(SRC)) dut(
 clk,rst,sd,sv,su,sl,sr,md,mv,mu,ml,mr,cv,cr,cs,cd,ce,err,busy);
reg [IW+1:0] inputs[0:NT-1];
reg [2*D+2:0] expected[0:NOUT-1];
reg [1:0] configs[0:NF-1];
integer sent,got,configured,cycles,epoch,fneed;
reg [31:0] rng=32'hc0ffee42;
reg held,inputfire;
reg [2*D+2:0] heldword,observed;
reg mut_data,mut_order,mut_count,mut_sideband;
initial begin
 $readmemh("input.mem",inputs);
 $readmemh("expected.mem",expected);
 $readmemh("config.mem",configs);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;cv=0;mr=0;repeat(3)@(negedge clk);
   if(mv!==0||busy!==0||err!==0)$fatal(1,"reset control");
   rst=1;sent=0;got=0;configured=0;cycles=0;held=0;
   while(got<NOUT || sent<NT)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     fneed=sent/NP;
     if(fneed<NF && configured<=fneed)begin
       cv=1;cs=configs[configured];mr=1;
     end else begin
       cv=0;mr=(epoch==0)?1:((cycles%83<27)?0:rng[0]);
     end
     if(!sv && sent<NT && configured>fneed && (epoch!=2 || rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(cv&&cr)configured=configured+1;
     if(ce)$fatal(1,"legal config rejected");
     if(held&&(!mv||{mu,ml,md}!==heldword))$fatal(1,"stall changed output");
     held=mv&&!mr;heldword={mu,ml,md};
     if(mv&&mr)begin
       observed={mu,ml,md};
       if(mut_data&&got==0)observed=observed^1;
       if(mut_sideband&&got==0)observed=observed^(1'b1<<(2*D+2));
       if(mut_order&&got==0&&NOUT>1)observed=expected[1];
       if(got>=NOUT||observed!==expected[got])
         $fatal(1,"chroma420 mismatch idx=%0d got=%h exp=%h",got,observed,expected[got]);
       if(!(mut_count&&got==NOUT-1))got=got+1;
     end
     inputfire=sv&&sr;
     if(inputfire)sent=sent+1;
     @(negedge clk);if(inputfire)sv=0;
     cycles=cycles+1;if(cycles>NT*300+20000)$fatal(1,"timeout");
   end
   sv=0;cv=0;mr=1;
   repeat(8)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
   if(err||configured!=NF||busy)$fatal(1,"terminal state/config coverage");
   // illegal siting rejection + retained-config replay
   cv=1;cs=3;@(negedge clk);
   if(!ce||cd)$fatal(1,"illegal siting not rejected");cv=0;
   sent=(NF-1)*NP;got=(NF-1)*NOF;cycles=0;mr=1;
   while(got<NOUT)begin
     if(sent<NT)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);
     if(mv&&mr)begin
       if({mu,ml,md}!==expected[got])
         $fatal(1,"illegal config changed retained arithmetic");
       got=got+1;
     end
     if(sv&&sr)sent=sent+1;
     @(negedge clk);cycles=cycles+1;
     if(cycles>NP*200+5000)$fatal(1,"retention timeout");
   end
   sv=0;repeat(3)@(negedge clk);
   sent=0;cycles=0;mr=0;
   while(!mv && sent<NP)begin
     if(sent<NP)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>NP*100+1000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 rst=0;sv=0;cv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;sd=0;
 @(negedge clk);sv=0;
 if(!err)$fatal(1,"marker error absent");
 rst=0;@(negedge clk);
 if(err||mv)$fatal(1,"diagnostic reset");
 $display("PASS chroma420 W=%0d H=%0d D=%0d SRC=%0d frames=%0d epochs=3",W,H,D,SRC,NF);
 $finish;
end
endmodule
