`timescale 1ns/1ps
module tb;
 `include "geometry.vh"
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0,s_data=0,s_valid=0,s_sof=0,s_eol=0;
 wire s_ready,m_valid,m_sof,m_eol,stats_valid,done_valid,done_error;
 wire [LABEL_BITS-1:0] m_label,stats_label;
 wire [31:0] stats_area;
 wire [15:0] stats_xmin,stats_xmax,stats_ymin,stats_ymax;
 wire [1:0] error_code;
 reg m_ready=0,stats_ready=0,done_ready=0;
 img_connected_components #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.CONNECTIVITY(CONNECTIVITY),.LABEL_BITS(LABEL_BITS),.MAX_LABELS(MAX_LABELS)) dut(.*);
 reg inputs[0:CASES*WIDTH*HEIGHT-1];
 reg [1:0] expected_codes[0:CASES-1];
 integer frame=0,pixels=0,stats=0,i;
 reg checking=1,randomize=1;
 reg [31:0] rng=32'hc184e73b;
 always @(negedge clk) if(randomize) begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  clk_en=rng[2:0]!=0;m_ready=rng[5:3]!=0;stats_ready=rng[8:6]!=0;
 end
 reg [LABEL_BITS+2:0] held_label;
 reg [LABEL_BITS+96:0] held_stats;
 reg stalled_label,stalled_stats;
 always @(posedge clk) begin
  if(rst_n && checking && clk_en) begin
   if(m_valid && m_ready) begin
    if(m_sof!==(pixels==0) || m_eol!==((pixels%WIDTH)==WIDTH-1)) $fatal(1,"label markers");
    $display("P %0d %0d %0d",frame,pixels,m_label);pixels=pixels+1;
   end
   if(stats_valid && stats_ready) begin
    if(pixels!=WIDTH*HEIGHT) $fatal(1,"stats before raster complete");
    $display("S %0d %0d %0d %0d %0d %0d %0d",frame,stats_label,stats_area,stats_xmin,stats_xmax,stats_ymin,stats_ymax);stats=stats+1;
   end
  end
  held_label={m_valid,m_sof,m_eol,m_label};stalled_label=rst_n&&m_valid&&(!clk_en||!m_ready);
  held_stats={stats_valid,stats_label,stats_area,stats_xmin,stats_xmax,stats_ymin,stats_ymax};stalled_stats=rst_n&&stats_valid&&(!clk_en||!stats_ready);
  #1;
  if(stalled_label && held_label!=={m_valid,m_sof,m_eol,m_label}) $fatal(1,"label unstable");
  if(stalled_stats && held_stats!=={stats_valid,stats_label,stats_area,stats_xmin,stats_xmax,stats_ymin,stats_ymax}) $fatal(1,"stats unstable");
 end
 task send(input bit value,sof,eol);
 begin
  @(negedge clk);#1;s_valid=1;s_data=value;s_sof=sof;s_eol=eol;
  do begin @(posedge clk);end while(!s_ready);
  @(negedge clk);#1;s_valid=0;
  repeat(rng[10:9]) begin @(negedge clk);#1;end
 end endtask
 task finish(input [1:0] code);
 reg [2:0] held;
 begin
  while(!done_valid) begin @(posedge clk);#2;end
  if(done_error!==(code!=0) || error_code!==code) $fatal(1,"completion code %0d expected %0d",error_code,code);
  if(code!=0 && (pixels!=0 || stats!=0)) $fatal(1,"partial outputs on error");
  if(code==0 && pixels!=WIDTH*HEIGHT) $fatal(1,"missing label samples");
  held={done_error,error_code};repeat(6) begin @(posedge clk);#2;if(!done_valid||held!=={done_error,error_code}||s_ready) $fatal(1,"done unstable");end
  $display("D %0d %0d",frame,code);
  @(negedge clk);#1;done_ready=1;
  do begin @(posedge clk);end while(!clk_en);
  @(negedge clk);#1;done_ready=0;
 end endtask
 task reset_dut;
 begin
  @(negedge clk);#1;rst_n=0;s_valid=0;
  #1;if(s_ready||m_valid||stats_valid||done_valid) $fatal(1,"reset abort");
  @(negedge clk);#1;rst_n=1;
 end endtask
 initial begin
  $readmemh("input.mem",inputs);$readmemh("codes.mem",expected_codes);
  repeat(3) @(negedge clk);#1;rst_n=1;
  for(frame=0;frame<CASES;frame=frame+1) begin
   pixels=0;stats=0;
   for(i=0;i<WIDTH*HEIGHT;i=i+1) send(inputs[frame*WIDTH*HEIGHT+i],i==0,i%WIDTH==WIDTH-1);
   finish(expected_codes[frame]);
  end
  // Deliberately malformed first marker, followed by a valid all-zero frame.
  pixels=0;stats=0;send(1,1,WIDTH!=1);finish(1);
  frame=frame+1;pixels=0;stats=0;
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(0,i==0,i%WIDTH==WIDTH-1);
  finish(0);
  checking=0;randomize=0;clk_en=1;m_ready=0;stats_ready=0;
  if(WIDTH*HEIGHT>1) begin send(1,1,WIDTH==1);reset_dut();end
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(1,i==0,i%WIDTH==WIDTH-1);
  repeat(3) @(posedge clk);reset_dut();
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(1,i==0,i%WIDTH==WIDTH-1);
  while(!m_valid) begin @(posedge clk);#2;end
  reset_dut();
  m_ready=1;
  for(i=0;i<WIDTH*HEIGHT;i=i+1) send(1,i==0,i%WIDTH==WIDTH-1);
  while(!stats_valid) begin @(posedge clk);#2;end
  reset_dut();
  repeat(30) @(posedge clk);#2;if(m_valid||stats_valid||done_valid) $fatal(1,"stale after reset");
  $display("CCL PASS %0dx%0d C=%0d",WIDTH,HEIGHT,CONNECTIVITY);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
