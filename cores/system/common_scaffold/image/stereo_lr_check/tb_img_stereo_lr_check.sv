`timescale 1ns/1ps
module tb;
 `include "geometry.vh"
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0,cfg_valid=0;
 reg [DISP_BITS-1:0] cfg_threshold=0,s_left_disp=0,s_right_disp=0;
 reg s_left_invalid=0,s_right_invalid=0,s_valid=0,s_sof=0,s_eol=0;
 wire cfg_ready,cfg_done,s_ready,m_valid,m_sof,m_eol,m_invalid,done_valid,done_error;
 wire [DISP_BITS-1:0] m_left_disp;
 wire [2:0] m_reason;
 wire [1:0] error_code;
 reg m_ready=0,done_ready=0;
 img_stereo_lr_check #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DISP_BITS(DISP_BITS)) dut(.*);
 reg [2*DISP_BITS+1:0] inputs[0:CASES*WIDTH*HEIGHT-1];
 reg [DISP_BITS-1:0] thresholds[0:CASES-1];
 integer frame=0,pixels=0,i;
 reg checking=1,randomize=1;
 reg [31:0] rng=32'h71d4a6c3;
 always @(negedge clk) if(randomize) begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  clk_en=rng[2:0]!=0;m_ready=rng[5:3]!=0;
 end
 reg [DISP_BITS+6:0] held;
 reg stalled;
 always @(posedge clk) begin
  if(rst_n&&checking&&clk_en&&m_valid&&m_ready) begin
   if(m_sof!==(pixels==0)||m_eol!==((pixels%WIDTH)==WIDTH-1)) $fatal(1,"output marker");
   if(m_invalid!==(m_reason!=0)) $fatal(1,"invalid/reason mismatch");
   $display("P %0d %0d %0d %0d",frame,pixels,m_left_disp,m_reason);pixels=pixels+1;
  end
  held={m_valid,m_sof,m_eol,m_invalid,m_reason,m_left_disp};stalled=rst_n&&m_valid&&(!clk_en||!m_ready);
  #1;if(stalled&&held!=={m_valid,m_sof,m_eol,m_invalid,m_reason,m_left_disp}) $fatal(1,"output unstable");
 end
 task configure(input [DISP_BITS-1:0] value);
 begin
  @(negedge clk);#1;cfg_threshold=value;cfg_valid=1;
  do begin @(posedge clk);end while(!cfg_ready);
  #1;if(!cfg_done) $fatal(1,"configuration ack");
  @(negedge clk);#1;cfg_valid=0;
 end endtask
 task send(input [2*DISP_BITS+1:0] value,input bit sof,eol);
 begin
  @(negedge clk);#1;
  {s_left_invalid,s_right_invalid,s_left_disp,s_right_disp}=value;
  s_sof=sof;s_eol=eol;s_valid=1;
  do begin @(posedge clk);end while(!s_ready);
  @(negedge clk);#1;s_valid=0;
  repeat(rng[8:7]) begin @(negedge clk);#1;end
 end endtask
 task finish(input bit bad);
 reg [2:0] status;
 begin
  while(!done_valid) begin @(posedge clk);#2;if(cfg_ready) $fatal(1,"busy config accepted");end
  if(done_error!==bad||error_code!==(bad?1:0)) $fatal(1,"done status");
  if(pixels!=(bad?0:WIDTH*HEIGHT)) $fatal(1,"output count");
  status={done_error,error_code};repeat(6) begin @(posedge clk);#2;if(!done_valid||status!=={done_error,error_code}||s_ready||cfg_ready) $fatal(1,"completion unstable");end
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
  $readmemh("input.mem",inputs);$readmemh("thresholds.mem",thresholds);
  repeat(3) @(negedge clk);#1;rst_n=1;
  for(frame=0;frame<CASES;frame=frame+1) begin
   pixels=0;configure(thresholds[frame]);
   send(inputs[frame*WIDTH*HEIGHT],1,WIDTH==1);
   cfg_valid=1;cfg_threshold=~thresholds[frame];
   for(i=1;i<WIDTH*HEIGHT;i=i+1) send(inputs[frame*WIDTH*HEIGHT+i],0,i%WIDTH==WIDTH-1);
   finish(0);
  end
  pixels=0;send(0,1,WIDTH!=1);finish(1);
  frame=frame+1;pixels=0;configure(0);
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  finish(0);
  checking=0;randomize=0;clk_en=1;m_ready=0;
  frame=frame+1;pixels=0;send(0,0,WIDTH==1);finish(1);
  frame=frame+1;pixels=0;checking=1;
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  m_ready=1;finish(0);
  checking=0;m_ready=0;
  if(WIDTH*HEIGHT>1) begin send(0,1,WIDTH==1);reset_dut();end
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  repeat(2) @(posedge clk);reset_dut();
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  while(!m_valid) begin @(posedge clk);#2;end
  reset_dut();repeat(15) @(posedge clk);#2;if(m_valid||done_valid) $fatal(1,"stale frame");
  $display("LR PASS %0dx%0d D=%0d",WIDTH,HEIGHT,DISP_BITS);$finish;
 end
 initial begin #30000000;$fatal(1,"timeout");end
endmodule
