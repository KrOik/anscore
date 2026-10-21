`timescale 1ns/1ps
module tb;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,clk_en=1,cfg_valid=0,stats_valid=0,update_ready=0;
 wire cfg_ready,cfg_error,stats_ready,update_valid,update_error;
 reg [15:0] cfg_target=128,cfg_deadband=3,cfg_exposure_min=1,cfg_exposure_max=200;
 reg [15:0] cfg_gain_min=256,cfg_gain_max=1024,cfg_exposure_step=8,cfg_gain_step=16;
 reg [3:0] cfg_attack_shift=2,cfg_release_shift=2;
 reg [31:0] cfg_saturation_limit=10;
 reg [47:0] stats_luma_sum=0;
 reg [31:0] stats_count=0,stats_saturated=0,stats_frame_id=0;
 reg stats_overflow=0;
 wire [15:0] exposure_lines,gain_q8,measured_mean;
 wire [31:0] update_frame_id;
 integer checks=0;
 img_ae_controller dut(.*);
 task configure(input bit error_expected);
 begin
  @(negedge clk); cfg_valid=1;
  if(!cfg_ready) $fatal(1,"config not ready");
  @(posedge clk); #1;
  if(cfg_error!==error_expected) $fatal(1,"configuration validation");
  @(negedge clk); cfg_valid=0;
  if(!error_expected) begin
   if(!update_valid || update_frame_id!==32'hffffffff || update_error) $fatal(1,"config update");
   update_ready=1;@(posedge clk);#1;
   @(negedge clk);update_ready=0;
  end
 end endtask
 task frame_check(input [47:0] s,input [31:0] n,sat,input bit overflow,
                  input [15:0] ee,gg,mm,input bit err);
 reg [64:0] held;
 integer cycles;
 begin
  @(negedge clk); stats_valid=1;stats_luma_sum=s;stats_count=n;
  stats_saturated=sat;stats_overflow=overflow;stats_frame_id=checks;
  if(!stats_ready) $fatal(1,"stats not ready");
  @(posedge clk); #1;
  @(negedge clk); stats_valid=0; stats_luma_sum=48'hffffffffffff; stats_count=0;
  cycles=0;
  while(!update_valid) begin
   clk_en=(cycles%5!=1); @(posedge clk); #1;
   cycles=cycles+1;
   if(cycles>100) $fatal(1,"timeout");
   @(negedge clk);
  end
  clk_en=1;
  if(exposure_lines!==ee || gain_q8!==gg || measured_mean!==mm || update_error!==err || update_frame_id!==checks)
   $fatal(1,"case %0d got e=%0d g=%0d m=%0d err=%0d expected %0d %0d %0d %0d",checks,exposure_lines,gain_q8,measured_mean,update_error,ee,gg,mm,err);
  held={exposure_lines,gain_q8,measured_mean,update_error,update_frame_id[15:0]};
  repeat(4) begin
   @(negedge clk); clk_en=~clk_en; stats_valid=1; cfg_valid=1;
   @(posedge clk); #1;
   if(!update_valid || stats_ready || cfg_ready || held!=={exposure_lines,gain_q8,measured_mean,update_error,update_frame_id[15:0]}) $fatal(1,"backpressure");
  end
  @(negedge clk); stats_valid=0;cfg_valid=0;clk_en=0;update_ready=1;
  @(posedge clk); #1;if(!update_valid) $fatal(1,"CE ignored");
  @(negedge clk);clk_en=1;
  @(posedge clk); #1;if(update_valid) $fatal(1,"update not consumed");
  @(negedge clk);update_ready=0;checks=checks+1;
 end endtask
 initial begin
  repeat(3) @(posedge clk);
  @(negedge clk);rst_n=1;
  if(stats_ready) $fatal(1,"unconfigured ready");
  `include "vectors.vh"
  // Asynchronous reset while a frame is in flight cancels the transaction.
  @(negedge clk);stats_valid=1;stats_count=100;stats_luma_sum=5000;
  @(posedge clk); @(negedge clk);stats_valid=0;rst_n=0;
  #1;if(update_valid || exposure_lines!=1 || gain_q8!=256) $fatal(1,"reset");
  @(negedge clk);rst_n=1;
  repeat(60) @(posedge clk);
  if(update_valid || stats_ready) $fatal(1,"reset cancellation");
  $display("AE PASS checks=%0d",checks);$finish;
 end
 initial begin #10000000; $fatal(1,"global timeout"); end
endmodule
