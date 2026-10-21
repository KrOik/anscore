`timescale 1ns/1ps
module tb_stream_width_adapter;
 parameter IW=32, OW=24, INPUTS=1, OUTPUTS=1;
 reg clk=0,rst_n=0;
 always #5 clk=~clk;
 reg [63:0] inputs[0:INPUTS-1],expected[0:OUTPUTS-1];
 reg [IW-1:0] sd=0;
 reg [IW/8-1:0] sk=0;
 reg [7:0] su=0;
 reg sl=0,sv=0,mr=0;
 wire sr,mv,ml;
 wire [OW-1:0] md;
 wire [OW/8-1:0] mk;
 wire [7:0] mu;
 integer sent=0,received=0,cycles=0,stalls=0;
 reg [31:0] rng=32'hdeadcafe;
 reg held=0;
 reg accepted;
 reg [63:0] old_output;
 wire [63:0] observed={19'd0,ml,mu,{{(4-OW/8){1'b0}},mk},{{(32-OW){1'b0}},md}};
 stream_width_adapter #(.IN_WIDTH(IW),.OUT_WIDTH(OW)) dut(
 .clk(clk),.rst_n(rst_n),.s_data(sd),.s_keep(sk),.s_user(su),.s_last(sl),
 .s_valid(sv),.s_ready(sr),.m_data(md),.m_keep(mk),.m_user(mu),
 .m_last(ml),.m_valid(mv),.m_ready(mr));
 initial begin
  $readmemh("input.hex",inputs); $readmemh("expected.hex",expected);
  #2; rst_n=1; #1; rst_n=0;
  repeat(3) @(negedge clk);
  rst_n=1;
  while(received<OUTPUTS||sent<INPUTS) begin
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   mr=(cycles%97>20)&&rng[0];
   if(!sv&&sent<INPUTS&&rng[3]) begin
    sd=inputs[sent][31:0]; sk=inputs[sent][35:32];
    su=inputs[sent][43:36]; sl=inputs[sent][44]; sv=1;
   end
   @(posedge clk);
   accepted=sv&&sr;
   if(held&&(!mv||observed!==old_output)) $fatal(1,"stalled payload changed");
   held=mv&&!mr; old_output=observed;
   if(mv&&!mr) stalls=stalls+1;
   if(mv&&mr) begin
    if(received>=OUTPUTS||observed!==expected[received])
     $fatal(1,"output %d got %h expected %h",received,observed,expected[received]);
    received=received+1;
   end
   #1;
   if(accepted) begin sv=0; sent=sent+1; end
   cycles=cycles+1;
   if(cycles>200000) $fatal(1,"timeout");
   @(negedge clk);
  end
  sv=0; mr=1;
  repeat(10) begin @(posedge clk); if(mv) $fatal(1,"extra output"); @(negedge clk); end
  if(stalls==0) $fatal(1,"no backpressure coverage");
  $display("PASS IW=%0d OW=%0d inputs=%0d outputs=%0d cycles=%0d stalls=%0d",IW,OW,sent,received,cycles,stalls);
  $finish;
 end
endmodule
