// Testbench for scale_poly6_stream.
// Stimulus files (hex, one word per line):
//   config.mem   - NF x 48-bit {in_w,in_h,out_w,out_h}
//   input.mem    - all frames concatenated, 26-bit {sof,eol,pix24}
//   expected.mem - all expected output beats, 26-bit {sof,eol,pix24}
// Plusargs: +stall=N (input gap probability %), +mstall=N (output stall %),
//           +seed=N, +vcd
`timescale 1ns/1ps
module tb_scale_poly6;
parameter MAXW=64, NF=1, NIN=1, NOUT=1;
reg clk=0; always #5 clk=~clk;
reg rst=0;
reg [23:0] sd=0; reg sv=0,su=0,sl=0,mr=0,cv=0;
reg [11:0] cw=0,ch=0,cow=0,coh=0;
wire sr,mv,mu,ml,cr,cd,ce,me,busy; wire [23:0] md;
scale_poly6_stream #(.MAX_W(MAXW)) dut(
 .clk(clk),.rst_n(rst),
 .s_tdata(sd),.s_tvalid(sv),.s_tuser(su),.s_tlast(sl),.s_tready(sr),
 .m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),
 .cfg_in_w(cw),.cfg_in_h(ch),.cfg_out_w(cow),.cfg_out_h(coh),
 .cfg_done(cd),.cfg_error(ce),.marker_error(me),.busy(busy));

reg [25:0] inputs[0:NIN-1], expected[0:NOUT-1];
reg [47:0] configs[0:NF-1];
integer sent=0, got=0, errors=0, f=0, i=0, cycles=0;
integer stall=20, mstall=20, seed=7;
reg [31:0] rng, rng2;
integer maxcyc, nin;

function [31:0] rnd; input [31:0] s;
 begin rnd={s[30:0],1'b0} ^ (s[31]?32'h04C11DB7:32'h0); end
endfunction

task send_beat; input [25:0] b;
 begin
   {su,sl,sd}<=b; sv<=1;
   @(posedge clk); while(!sr) @(posedge clk);
   sent=sent+1;
   sv<=0;
   rng=rnd(rng);
   while((rng%100)<stall) begin
     @(posedge clk); rng=rnd(rng);
   end
 end
endtask

initial begin
 $readmemh("config.mem",configs);
 $readmemh("input.mem",inputs);
 $readmemh("expected.mem",expected);
 if($value$plusargs("stall=%d",stall));
 if($value$plusargs("mstall=%d",mstall));
 if($value$plusargs("seed=%d",seed));
 if($test$plusargs("vcd")) begin
   $dumpfile("tb_scale_poly6.vcd"); $dumpvars(0,tb_scale_poly6);
 end
 rng=(seed|1); rng2=((seed^32'h5A5A5A5A)|1);
 maxcyc=64*(NIN+NOUT)+200000;
 rst=0; repeat(8) @(posedge clk); rst=1; repeat(4) @(posedge clk);
 for(f=0;f<NF;f=f+1) begin
   while(!cr) @(posedge clk);
   {cw,ch,cow,coh}<=configs[f]; cv<=1;
   @(posedge clk); while(!cr) @(posedge clk);
   cv<=0;
   @(posedge clk); while(!cd) @(posedge clk);
   if(ce) begin $display("FAIL cfg_error frame %0d",f); $finish; end
   nin=configs[f][47:36]*configs[f][35:24];
   for(i=0;i<nin;i=i+1) send_beat(inputs[sent]);
 end
 while(got<NOUT && cycles<maxcyc) @(posedge clk);
 if(got!=NOUT) begin
   $display("FAIL timeout/shortfall: got %0d of %0d outputs",got,NOUT);
   $finish;
 end
 if(me) begin $display("FAIL marker_error set"); errors=errors+1; end
 if(errors==0) $display("PASS frames=%0d beats_out=%0d cycles=%0d",NF,got,cycles);
 else $display("FAIL mismatches=%0d",errors);
 $finish;
end

// output stall driver (independent rng)
always @(posedge clk) begin
 if(!rst) mr<=0;
 else begin
   rng2=rnd(rng2);
   mr <= ((rng2%100)>=mstall);
 end
end

// output checker
always @(posedge clk) begin
 if(rst && mv && mr) begin
   if(got>=NOUT) begin
     $display("FAIL extra output beat %0d",got); errors=errors+1;
   end else if({mu,ml,md}!==expected[got]) begin
     errors=errors+1;
     if(errors<20)
       $display("MISMATCH beat %0d: got %h exp %h",got,{mu,ml,md},expected[got]);
   end
   got=got+1;
 end
end

// watchdog
always @(posedge clk) begin
 cycles=cycles+1;
 if(cycles>maxcyc) begin
   $display("FAIL watchdog: sent=%0d got=%0d",sent,got); $finish;
 end
end
endmodule
