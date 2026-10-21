`timescale 1ns/1ps
// Pack -> unpack chained regression.
// input.mem        : {tuser,tlast,sample[D]}   sample stream
// expected_pack.mem: {tuser,tlast,word[NW]}    packed words
// expected_unpack.mem: {tuser,tlast,sample[D]} unpacked stream (includes
//                    zero pad samples re-expanded from flushed words)
module tb_pix_pack;
parameter D=8,NS=4,SLOT=0,NIN=64,NWOUT=16,NUN=64;
localparam SLT=(SLOT==0)?D:SLOT;
localparam NW=NS*SLT;
reg clk=0;always #5 clk=~clk;
reg rst=0,sv=0,su=0,sl=0,mr=0;
reg [D-1:0] sd=0;
wire psr,usr;
wire pv,pu,pl;wire [NW-1:0] pd;wire perr;
wire uv,uu,ul;wire [D-1:0] ud;
pix_pack #(.BITS(D),.NS(NS),.SLOT(SLOT)) pk(
 clk,rst,sd,sv,su,sl,psr,pd,pv,pu,pl,usr,perr);
pix_unpack #(.BITS(D),.NS(NS),.SLOT(SLOT)) upk(
 clk,rst,pd,pv,pu,pl,usr,ud,uv,uu,ul,mr);
reg [D+1:0] inputs[0:NIN-1];
reg [NW+1:0] expack[0:NWOUT-1];
reg [D+1:0] expunp[0:NUN-1];
integer sent,gp,gu,cycles,epoch;
reg [31:0] rng=32'h0a4c1234;
reg heldp,heldu,inputfire;
reg [NW+1:0] heldpw,obsp;
reg [D+1:0] helduw,obsu;
reg mut_data,mut_order,mut_count,mut_sideband;
initial begin
 $readmemh("input.mem",inputs);
 $readmemh("expected_pack.mem",expack);
 $readmemh("expected_unpack.mem",expunp);
 mut_data=$test$plusargs("data");mut_order=$test$plusargs("order");
 mut_count=$test$plusargs("count");mut_sideband=$test$plusargs("sideband");
 for(epoch=0;epoch<3;epoch=epoch+1)begin
   @(negedge clk);rst=0;sv=0;mr=0;repeat(3)@(negedge clk);
   if(pv!==0||uv!==0||perr!==0)$fatal(1,"reset control");
   rst=1;sent=0;gp=0;gu=0;cycles=0;heldp=0;heldu=0;
   while(gu<NUN || gp<NWOUT || sent<NIN)begin
     rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
     mr=(epoch==0)?1:((cycles%67<19)?0:rng[0]);
     if(!sv && sent<NIN && (epoch!=2 || rng[2]))begin
       sv=1;{su,sl,sd}=inputs[sent];
     end
     @(posedge clk);
     if(heldp&&(!pv||{pu,pl,pd}!==heldpw))$fatal(1,"pack stall changed output");
     heldp=pv&&!usr;heldpw={pu,pl,pd};
     if(heldu&&(!uv||{uu,ul,ud}!==helduw))$fatal(1,"unpack stall changed output");
     heldu=uv&&!mr;helduw={uu,ul,ud};
     if(pv&&usr)begin
       obsp={pu,pl,pd};
       if(mut_data&&gp==0)obsp=obsp^1;
       if(mut_sideband&&gp==0)obsp=obsp^(1'b1<<(NW+1));
       if(mut_order&&gp==0&&NWOUT>1)obsp=expack[1];
       if(gp>=NWOUT||obsp!==expack[gp])
         $fatal(1,"pack mismatch idx=%0d got=%h exp=%h",gp,obsp,expack[gp]);
       if(!(mut_count&&gp==NWOUT-1))gp=gp+1;
     end
     if(uv&&mr)begin
       obsu={uu,ul,ud};
       if(gu>=NUN||obsu!==expunp[gu])
         $fatal(1,"unpack mismatch idx=%0d got=%h exp=%h",gu,obsu,expunp[gu]);
       gu=gu+1;
     end
     inputfire=sv&&psr;
     if(inputfire)sent=sent+1;
     @(negedge clk);if(inputfire)sv=0;
     cycles=cycles+1;if(cycles>NIN*400+20000)$fatal(1,"timeout");
   end
   sv=0;mr=1;
   repeat(8)begin @(posedge clk);if(pv||uv)$fatal(1,"extra output");@(negedge clk);end
   if(perr)$fatal(1,"unexpected proto_error");
   // leave mid-group state for the next epoch's reset
   sent=0;cycles=0;mr=0;
   while(!pv && sent<NIN)begin
     if(sent<NIN)begin sv=1;{su,sl,sd}=inputs[sent];end else sv=0;
     @(posedge clk);if(sv&&psr)sent=sent+1;@(negedge clk);
     cycles=cycles+1;if(cycles>NIN*100+1000)$fatal(1,"reset setup timeout");
   end
   sv=0;repeat(3)@(negedge clk);
 end
 // proto_error: SOF inside an unfinished group
 rst=0;sv=0;@(negedge clk);rst=1;mr=1;
 sv=1;su=1;sl=0;sd=0;@(negedge clk);sv=0;       // group starts, in_frame
 repeat(2)@(negedge clk);
 sv=1;su=1;sl=0;sd=1;@(negedge clk);sv=0;       // second SOF mid-group
 if(!perr)$fatal(1,"proto_error absent");
 rst=0;@(negedge clk);
 if(perr||pv||uv)$fatal(1,"diagnostic reset");
 $display("PASS pix_pack D=%0d NS=%0d SLOT=%0d epochs=3",D,NS,SLOT);
 $finish;
end
endmodule
