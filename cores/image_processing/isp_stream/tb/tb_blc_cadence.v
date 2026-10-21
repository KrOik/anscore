`timescale 1ns/1ps
module tb_blc_cadence;
 reg clk=0,rst=0,sv=0,mr=1,sof=0,eol=0;reg [9:0] data=0;
 always #5 clk=~clk;
 wire sr,mv,ms,me;wire [9:0] md;wire [15:0] mf;
 raw_black_level_stream dut(.clk(clk),.rst_n(rst),.cfg_valid(1'b0),.cfg_pattern(2'd0),
 .cfg_levels(40'd0),.cfg_target(10'd0),.cfg_bypass(1'b0),.s_valid(sv),.s_ready(sr),
 .s_data(data),.s_sof(sof),.s_eol(eol),.s_frame_id(16'd77),.m_valid(mv),.m_ready(mr),
 .m_data(md),.m_sof(ms),.m_eol(me),.m_frame_id(mf));
 integer received=0,tick=0,previous_tick=-1;reg checking=1;
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  if(checking&&mv&&mr)begin
   if(md!=received||mf!=77||ms!=(received==0)||me!=(received%16==15))$fatal(1,"cadence payload");
   if(previous_tick>=0&&tick!=previous_tick+1)$fatal(1,"bubble in continuous output");
   previous_tick=tick;received=received+1;
  end
 end
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(integer i=0;i<128;i=i+1)begin
   @(negedge clk);sv=1;data=i;sof=i==0;eol=i%16==15;
   @(posedge clk);if(!sr)$fatal(1,"input cannot sustain II1");
  end
  @(negedge clk);sv=0;wait(received==128);@(negedge clk);checking=0;
  mr=0;sv=1;sof=1;eol=0;@(negedge clk);sv=0;
  repeat(8)@(negedge clk);
  if(!mv)$fatal(1,"lost stalled output");rst=0;@(negedge clk);
  if(mv||sr)$fatal(1,"reset did not abort stream");rst=1;
  $display("PASS BLC continuous128 pixels II1 and reset of stalled output");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
