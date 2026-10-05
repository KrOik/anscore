`timescale 1ns/1ps
module tb_median;
parameter W=7,H=6,K=3,D=8,PAD=0,NF=6,ORDER_INDEX=0;
localparam NP=W*H,NT=NP*NF,LAT=(K==3)?10:15;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0;reg[D-1:0]sd=0;
wire sr,mv,mu,ml,err;wire[D-1:0]md;
median_stream #(.BITS(D),.WIDTH(W),.HEIGHT(H),.K(K),.PAD_MODE(PAD))dut(clk,rst,sd,sv,su,sl,sr,md,mv,mu,ml,mr,err);
reg[D+1:0]inputs[0:NT-1],expected[0:NT-1],heldword,observed;
integer sent,got,cycles,epoch,i,previousout,starts[0:NF-1],tails[0:NF-1];
reg[31:0]rng=32'h70960125;reg held,fire,mut_data,mut_order,mut_count,mut_sideband;
initial begin
$readmemh("input.mem",inputs);$readmemh("expected.mem",expected);
mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
for(epoch=0;epoch<3;epoch=epoch+1)begin
 @(negedge clk);rst=0;sv=0;mr=0;repeat(3)@(negedge clk);
 if(mv!==0 || err!==0)$fatal(1,"reset control");rst=1;
 sent=0;got=0;cycles=0;held=0;previousout=-1;
 while(got<NT || sent<NT)begin
 rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
 mr=epoch==0?1:((cycles%83<27)?0:rng[0]);
 if(!sv && sent<NT && (epoch==0 || rng[2]))begin sv=1;{su,sl,sd}=inputs[sent];end
 @(posedge clk);
 if(held && (!mv || {mu,ml,md}!==heldword))$fatal(1,"held output changed");
 held=mv&&!mr;heldword={mu,ml,md};
 if(mv&&mr)begin
 observed={mu,ml,md};
 if(mut_data && got==0)observed=observed^1;
 if(mut_sideband && got==0)observed=observed^(1<<(D+1));
 if(mut_order && got==0)observed=expected[ORDER_INDEX];
 if(got>=NT || observed!==expected[got])$fatal(1,"median mismatch index=%0d got=%h expected=%h",got,observed,expected[got]);
 if(epoch==0 && got%W>0 && cycles-previousout!=1)$fatal(1,"row II");
 if(epoch==0 && got%NP==0)begin
 if(cycles-starts[got/NP]!=W*(1+((K/2<H-1)?K/2:H-1))+(K-1)*(W+K-1)+K-1+4+LAT)$fatal(1,"first output latency got=%0d",cycles-starts[got/NP]);
 end
 if(epoch==0 && got%NP==NP-1 && cycles-tails[got/NP]!=(W+K-1)*((H==1)?K:K/2+1)+4+LAT)$fatal(1,"tail latency got=%0d",cycles-tails[got/NP]);
 if(!(mut_count && got==NT-1))got=got+1;
 previousout=cycles;
 end
 fire=sv&&sr;
 if(fire)begin
 if(sent%NP==NP-1)tails[sent/NP]=cycles;
 if(sent%NP==0)begin
 starts[sent/NP]=cycles;
 if(epoch==0 && sent/NP>0 && starts[sent/NP]-starts[sent/NP-1]!=NP+(W+K-1)*(H+K-1)+4)$fatal(1,"frame input interval");
 end
 sent=sent+1;
 end
 @(negedge clk);if(fire)sv=0;
 cycles=cycles+1;if(cycles>NT*160+10000)$fatal(1,"count timeout");
 end
 sv=0;mr=1;repeat(20)begin @(posedge clk);if(mv)$fatal(1,"extra output");@(negedge clk);end
 if(err)$fatal(1,"marker error");
 // Reset next epoch with a live blocked median and retained line memories.
 sent=0;mr=0;cycles=0;
 while(!mv)begin
 if(sent<NP)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
 @(posedge clk);if(sv&&sr)sent=sent+1;@(negedge clk);
 cycles=cycles+1;if(cycles>NP*100+1000)$fatal(1,"reset setup timeout");
 end
 sv=0;repeat(3)@(negedge clk);
end
rst=0;sv=0;@(negedge clk);rst=1;sv=1;su=0;sl=0;mr=1;
@(negedge clk);sv=0;if(!err)$fatal(1,"bad marker accepted");
$display("PASS median W=%0d H=%0d K=%0d D=%0d PAD=%0d sortlat=%0d frames=%0d",W,H,K,D,PAD,LAT,NF*3);$finish;
end
endmodule
