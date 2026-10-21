`timescale 1ns/1ps
module tb;
 `include "geometry.vh"
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0,cfg_valid=0;
 reg [BITS-1:0] cfg_threshold=0,input_score=0;
 reg input_valid=0,input_sof=0,input_eol=0;
 wire cfg_ready,cfg_done,s_ready,m_valid,m_corner,m_sof,m_eol,done_valid,done_error;
 wire [BITS-1:0] m_score;
 wire [1:0] m_reason,error_code;
 reg m_ready=0,done_ready=0,link_gate=0;
 wire [BITS-1:0] fast_score;
 wire fast_valid,fast_sof,fast_eol,fast_ready,fast_error,fast_done;
 wire [BITS-1:0] s_score=USE_FAST?fast_score:input_score;
 wire s_valid=USE_FAST?(fast_valid&&link_gate):input_valid;
 wire s_sof=USE_FAST?fast_sof:input_sof;
 wire s_eol=USE_FAST?fast_eol:input_eol;
 wire input_ready=USE_FAST?fast_ready:s_ready;
 img_corner_nms #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.KEEP_BORDER(KEEP_BORDER)) dut(.*);
 generate if(USE_FAST) begin: fast_chain
  img_fast9_frame #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) detector(
   .clk(clk),.rst_n(rst_n),.ce(clk_en),.cfg_valid(1'b0),.cfg_ready(),.cfg_threshold({BITS{1'b0}}),
   .s_data(input_score),.s_valid(input_valid),.s_ready(fast_ready),.s_sof(input_sof),.s_eol(input_eol),
   .m_score(fast_score),.m_corner(),.m_valid(fast_valid),.m_ready(s_ready&&link_gate),.m_sof(fast_sof),.m_eol(fast_eol),
   .done_valid(fast_done),.done_ready(1'b1),.frame_error(fast_error));
 end else begin: direct
  assign fast_score=0;assign fast_valid=0;assign fast_sof=0;assign fast_eol=0;
  assign fast_ready=0;assign fast_error=0;assign fast_done=0;
 end endgenerate
 reg [BITS-1:0] inputs[0:CASES*WIDTH*HEIGHT-1],thresholds[0:CASES-1];
 integer frame=0,pixels=0,i;
 reg checking=1,randomize=1;
 reg [31:0] rng=32'h42c19b67;
 always @(negedge clk) if(randomize) begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  clk_en=rng[2:0]!=0;m_ready=rng[5:3]!=0;link_gate=rng[8:6]!=0;
 end
 reg [BITS+5:0] held;
 reg stalled;
 always @(posedge clk) begin
  if(rst_n&&checking&&clk_en&&m_valid&&m_ready) begin
   if(m_sof!==(pixels==0)||m_eol!==((pixels%WIDTH)==WIDTH-1)||m_corner!==(m_reason==0)) $fatal(1,"output markers/flag");
   $display("P %0d %0d %0d %0d",frame,pixels,m_score,m_reason);pixels=pixels+1;
  end
  held={m_valid,m_corner,m_sof,m_eol,m_reason,m_score};stalled=rst_n&&m_valid&&(!clk_en||!m_ready);
  #1;if(stalled&&held!=={m_valid,m_corner,m_sof,m_eol,m_reason,m_score}) $fatal(1,"output unstable");
  if(rst_n&&USE_FAST&&fast_error) $fatal(1,"FAST chain frame error");
 end
 task configure(input [BITS-1:0] value);
 begin
  @(negedge clk);#1;cfg_threshold=value;cfg_valid=1;
  do begin @(posedge clk);end while(!cfg_ready);
  #1;if(!cfg_done) $fatal(1,"configuration ack");
  @(negedge clk);#1;cfg_valid=0;
 end endtask
 task send(input [BITS-1:0] value,input bit sof,eol);
 begin
  @(negedge clk);#1;input_score=value;input_valid=1;input_sof=sof;input_eol=eol;
  do begin @(posedge clk);end while(!input_ready);
  @(negedge clk);#1;input_valid=0;
  repeat(rng[10:9]) begin @(negedge clk);#1;end
 end endtask
 task finish(input bit bad);
 reg [2:0] status;
 begin
  while(!done_valid) begin @(posedge clk);#2;end
  if(done_error!==bad||error_code!==(bad?1:0)||pixels!=(bad?0:WIDTH*HEIGHT)) $fatal(1,"frame completion");
  status={done_error,error_code};repeat(5) begin @(posedge clk);#2;if(!done_valid||status!=={done_error,error_code}||s_ready||cfg_ready) $fatal(1,"completion unstable");end
  @(negedge clk);#1;cfg_valid=0;done_ready=1;
  do begin @(posedge clk);end while(!clk_en);
  @(negedge clk);#1;done_ready=0;
 end endtask
 task reset_dut;
 begin
  @(negedge clk);#1;rst_n=0;input_valid=0;cfg_valid=0;
  // FAST has synchronous reset; give its clocked state a reset edge too.
  @(posedge clk);#1;if(m_valid||done_valid||s_ready||cfg_ready) $fatal(1,"reset abort");
  @(negedge clk);#1;rst_n=1;
 end endtask
 initial begin
  $readmemh("input.mem",inputs);$readmemh("thresholds.mem",thresholds);
  repeat(3) @(negedge clk);#1;rst_n=1;
  for(frame=0;frame<CASES;frame=frame+1) begin
   pixels=0;configure(thresholds[frame]);
   send(inputs[frame*WIDTH*HEIGHT],1,WIDTH==1);
   if(!USE_FAST) begin cfg_valid=1;cfg_threshold=~thresholds[frame];end
   for(i=1;i<WIDTH*HEIGHT;i=i+1) send(inputs[frame*WIDTH*HEIGHT+i],0,i%WIDTH==WIDTH-1);
   finish(0);
  end
  if(!USE_FAST) begin
   pixels=0;send(0,0,WIDTH==1);finish(1);
   pixels=0;send(0,1,WIDTH!=1);finish(1);
   frame=frame+1;pixels=0;configure(0);
   for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
   finish(0);
  end
  checking=0;randomize=0;clk_en=1;m_ready=0;link_gate=1;
  if(WIDTH*HEIGHT>1) begin send(0,1,WIDTH==1);reset_dut();end
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  repeat(3) @(posedge clk);reset_dut();
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  while(!m_valid) begin @(posedge clk);#2;end
  reset_dut();repeat(15) @(posedge clk);#2;if(m_valid||done_valid) $fatal(1,"stale frame");
  $display("NMS PASS %0dx%0d BITS=%0d BORDER=%0d FAST=%0d",WIDTH,HEIGHT,BITS,KEEP_BORDER,USE_FAST);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
