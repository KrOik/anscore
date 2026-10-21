`timescale 1ns/1ps
module tb;
 `include "geometry.vh"
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0,cfg_valid=0;
 reg [31:0] cfg_max_sad=32'hffffffff,cfg_min_gap=0;
 reg [BITS-1:0] s_current=0,s_reference=0;
 reg s_valid=0,s_sof=0,s_eol=0;
 wire cfg_ready,cfg_done,s_ready,m_valid,m_invalid,m_sof,m_last,done_valid,done_error;
 wire signed [15:0] m_dx,m_dy;
 wire [31:0] m_sad,m_second_sad,m_gap;
 wire [15:0] m_x,m_y,m_width,m_height;
 wire [1:0] m_reason,error_code;
 reg m_ready=0,done_ready=0;
 img_block_motion #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.BLOCK_W(BLOCK_W),.BLOCK_H(BLOCK_H),.SEARCH_RANGE(SEARCH_RANGE)) dut(.*);
 reg [2*BITS-1:0] input_values[0:CASES*WIDTH*HEIGHT-1];
 reg [63:0] thresholds[0:CASES-1];
 integer frame=0,blocks=0,i;
 reg randomize=1,checking=1;
 reg [31:0] rng=32'h9c1376a5;
 always @(negedge clk) if(randomize) begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  clk_en=rng[2:0]!=0;m_ready=rng[5:3]!=0;
 end
 reg [197:0] held;
 reg stalled;
 always @(posedge clk) begin
  if(rst_n&&checking&&clk_en&&m_valid&&m_ready) begin
   if(m_sof!==(blocks==0)||m_last!==(blocks==BLOCKS-1)||m_invalid!==(m_reason!=0)) $fatal(1,"output markers/invalid");
   $display("B %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",frame,blocks,m_x,m_y,m_width,m_height,m_dx,m_dy,m_sad,m_second_sad,m_gap,m_reason);
   blocks=blocks+1;
  end
  held={m_valid,m_sof,m_last,m_invalid,m_reason,m_x,m_y,m_width,m_height,m_dx,m_dy,m_sad,m_second_sad,m_gap};
  stalled=rst_n&&m_valid&&(!clk_en||!m_ready);
  #1;if(stalled&&held!=={m_valid,m_sof,m_last,m_invalid,m_reason,m_x,m_y,m_width,m_height,m_dx,m_dy,m_sad,m_second_sad,m_gap}) $fatal(1,"stalled result unstable");
 end
 task configure(input [63:0] value);
 begin
  @(negedge clk);#1;{cfg_max_sad,cfg_min_gap}=value;cfg_valid=1;
  do begin @(posedge clk);end while(!cfg_ready);
  #1;if(!cfg_done) $fatal(1,"config ack");
  @(negedge clk);#1;cfg_valid=0;
 end endtask
 task send(input [2*BITS-1:0] value,input bit sof,eol);
 begin
  @(negedge clk);#1;{s_current,s_reference}=value;s_valid=1;s_sof=sof;s_eol=eol;
  do begin @(posedge clk);end while(!s_ready);
  @(negedge clk);#1;s_valid=0;
  repeat(rng[8:7]) begin @(negedge clk);#1;end
 end endtask
 task finish(input bit bad);
 reg [2:0] status;
 begin
  while(!done_valid) begin @(posedge clk);#2;if(cfg_ready) $fatal(1,"busy config");end
  if(done_error!==bad||error_code!==(bad?1:0)||blocks!=(bad?0:BLOCKS)) $fatal(1,"completion count/status");
  status={done_error,error_code};repeat(5) begin @(posedge clk);#2;if(!done_valid||status!=={done_error,error_code}||s_ready||cfg_ready) $fatal(1,"completion unstable");end
  $display("D %0d %0d",frame,bad);
  @(negedge clk);#1;cfg_valid=0;done_ready=1;
  do begin @(posedge clk);end while(!clk_en);
  @(negedge clk);#1;done_ready=0;
 end endtask
 task reset_dut;
 begin
  @(negedge clk);#1;rst_n=0;s_valid=0;cfg_valid=0;
  #1;if(m_valid||done_valid||s_ready||cfg_ready) $fatal(1,"reset abort");
  @(negedge clk);#1;rst_n=1;
 end endtask
 initial begin
  $readmemh("input.mem",input_values);$readmemh("thresholds.mem",thresholds);
  repeat(3) @(negedge clk);#1;rst_n=1;
  for(frame=0;frame<CASES;frame=frame+1) begin
   blocks=0;configure(thresholds[frame]);
   send(input_values[frame*WIDTH*HEIGHT],1,WIDTH==1);
   cfg_valid=1;cfg_max_sad=0;cfg_min_gap=32'hffffffff;
   for(i=1;i<WIDTH*HEIGHT;i=i+1) send(input_values[frame*WIDTH*HEIGHT+i],0,i%WIDTH==WIDTH-1);
   finish(0);
  end
  blocks=0;send(0,0,WIDTH==1);finish(1);
  blocks=0;send(0,1,WIDTH!=1);finish(1);
  frame=frame+1;blocks=0;configure({32'hffffffff,32'b0});
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  finish(0);
  checking=0;randomize=0;clk_en=1;m_ready=0;
  if(WIDTH*HEIGHT>1) begin send(0,1,WIDTH==1);reset_dut();end
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  repeat(3) @(posedge clk);reset_dut();
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  while(!m_valid) begin @(posedge clk);#2;end
  reset_dut();repeat(15) @(posedge clk);#2;if(m_valid||done_valid) $fatal(1,"stale frame");
  $display("MOTION PASS %0dx%0d BITS=%0d BLOCK=%0dx%0d R=%0d",WIDTH,HEIGHT,BITS,BLOCK_W,BLOCK_H,SEARCH_RANGE);$finish;
 end
 initial begin #200000000;$fatal(1,"timeout");end
endmodule
