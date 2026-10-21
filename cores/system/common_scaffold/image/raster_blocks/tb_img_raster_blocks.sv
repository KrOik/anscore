`timescale 1ns/1ps
module tb;
 `include "geometry.vh"
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0;
 reg [BITS-1:0] s_data=0;
 reg s_valid=0,s_sof=0,s_eol=0;
 wire s_ready;
 wire [BITS-1:0] b_data,r_data;
 wire b_valid,b_ready,b_sof,b_eol,b_first,b_last,b_frame_last;
 wire r_valid,r_sof,r_eol,r_first,r_last,r_frame_last;
 reg sink_ready=0,link_gate=0;
 wire inv_ready,f_error,f_pulse,r_error,r_pulse;
 reg force_mode=0,force_valid=0;
 reg [BITS+3:0] force_word=0;
 img_raster_blocks #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TO_BLOCK(1)) fwd(
  .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),
  .s_sof(s_sof),.s_eol(s_eol),.s_block_first(1'b0),.s_block_last(1'b0),
  .m_data(b_data),.m_valid(b_valid),.m_ready(b_ready),.m_sof(b_sof),.m_eol(b_eol),
  .m_block_first(b_first),.m_block_last(b_last),.m_frame_last(b_frame_last),.protocol_error(f_error),.error_pulse(f_pulse));
 assign b_ready=inv_ready && link_gate && !force_mode;
 img_raster_blocks #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TO_BLOCK(0)) inv(
  .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
  .s_data(force_mode?force_word[BITS-1:0]:b_data),.s_valid(force_mode?force_valid:(b_valid&&link_gate)),.s_ready(inv_ready),
  .s_sof(force_mode?force_word[BITS+3]:b_sof),.s_eol(force_mode?force_word[BITS+2]:b_eol),
  .s_block_first(force_mode?force_word[BITS+1]:b_first),.s_block_last(force_mode?force_word[BITS]:b_last),
  .m_data(r_data),.m_valid(r_valid),.m_ready(sink_ready),.m_sof(r_sof),.m_eol(r_eol),
  .m_block_first(r_first),.m_block_last(r_last),.m_frame_last(r_frame_last),.protocol_error(r_error),.error_pulse(r_pulse));
 reg [BITS+1:0] raster_input[0:REAL*2-1];
 reg [BITS+4:0] block_expected[0:PADDED*2-1];
 reg [BITS+2:0] raster_expected[0:REAL*3-1];
 reg [BITS+3:0] block_force[0:PADDED-1];
 integer i,block_seen=0,raster_seen=0;
 reg checking=1,randomize=1;
 reg [31:0] rng=32'h4ca71539;
 always @(negedge clk) if(randomize) begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  clk_en=rng[2:0]!=0;link_gate=rng[5:3]!=0;sink_ready=rng[8:6]!=0;
 end
 reg [BITS+5:0] held_b;
 reg [BITS+3:0] held_r;
 reg stall_b,stall_r;
 always @(posedge clk) begin
  if(rst_n && checking && clk_en) begin
   if(b_valid && b_ready) begin
    if(block_seen>=PADDED*2 || {b_sof,b_eol,b_first,b_last,b_frame_last,b_data}!==block_expected[block_seen]) $fatal(1,"block coordinate %0d mismatch",block_seen);
    block_seen=block_seen+1;
   end
   if(r_valid && sink_ready) begin
    if(raster_seen>=REAL*3 || {r_sof,r_eol,r_frame_last,r_data}!==raster_expected[raster_seen] || r_first || r_last) $fatal(1,"raster coordinate %0d mismatch",raster_seen);
    raster_seen=raster_seen+1;
   end
  end
  held_b={b_valid,b_sof,b_eol,b_first,b_last,b_frame_last,b_data};stall_b=rst_n&&b_valid&&(!clk_en||!b_ready);
  held_r={r_valid,r_sof,r_eol,r_frame_last,r_data};stall_r=rst_n&&r_valid&&(!clk_en||!sink_ready);
  #1;
  if(stall_b && held_b!=={b_valid,b_sof,b_eol,b_first,b_last,b_frame_last,b_data}) $fatal(1,"block unstable");
  if(stall_r && held_r!=={r_valid,r_sof,r_eol,r_frame_last,r_data}) $fatal(1,"raster unstable");
 end
 task send_raster(input [BITS+1:0] word);
 begin
  @(negedge clk);#1;s_data=word[BITS-1:0];s_sof=word[BITS+1];s_eol=word[BITS];s_valid=1;
  do begin @(posedge clk);end while(!s_ready);
  @(negedge clk);#1;s_valid=0;
  repeat(rng[10:9]) begin @(negedge clk);#1;end
 end endtask
 task send_force(input [BITS+3:0] word);
 begin
  @(negedge clk);#1;force_word=word;force_valid=1;
  do begin @(posedge clk);end while(!inv_ready);
  @(negedge clk);#1;force_valid=0;
 end endtask
 task reset_dut;
 begin
  @(negedge clk);#1;rst_n=0;s_valid=0;force_valid=0;
  #1;if(b_valid || r_valid || s_ready || inv_ready || f_error || r_error) $fatal(1,"reset abort");
  @(negedge clk);#1;rst_n=1;
 end endtask
 initial begin
  $readmemh("input.mem",raster_input);$readmemh("blocks.mem",block_expected);
  $readmemh("raster.mem",raster_expected);$readmemh("force.mem",block_force);
  repeat(3) @(negedge clk);#1;rst_n=1;
  // A malformed SOF/EOL combination drops the first attempted frame.
  send_raster((1<<(BITS+1)) | ((WIDTH!=1)<<BITS));
  if(!f_error) $fatal(1,"forward malformed marker not detected");
  for(i=0;i<REAL*2;i=i+1) send_raster(raster_input[i]);
  while(raster_seen<REAL*2) begin @(posedge clk);#2;end
  if(block_seen!=PADDED*2 || r_error) $fatal(1,"roundtrip totals");
  force_mode=1;
  send_force((1<<(BITS+3)) | (1<<(BITS+1))); // correct first block sample
  send_force(1<<BITS); // illegal block-last marker at sample 1
  if(!r_error) $fatal(1,"inverse malformed marker not detected");
  for(i=0;i<PADDED;i=i+1) send_force(block_force[i]);
  while(raster_seen<REAL*3) begin @(posedge clk);#2;end
  // Partial capture reset, followed by reset of a pending forward output.
  checking=0;randomize=0;clk_en=1;link_gate=0;sink_ready=0;force_mode=0;
  if(REAL>1) begin send_raster(raster_input[0]);reset_dut();end
  else reset_dut();
  for(i=0;i<REAL;i=i+1) send_raster(raster_input[i]);
  while(!b_valid) begin @(posedge clk);#2;end
  reset_dut();repeat(20) @(posedge clk);#2;if(b_valid || r_valid) $fatal(1,"stale memory output");
  $display("RASTER PASS BITS=%0d %0dx%0d blocksamples=%0d raster=%0d",BITS,WIDTH,HEIGHT,block_seen,raster_seen);$finish;
 end
 initial begin #30000000;$fatal(1,"timeout");end
endmodule
