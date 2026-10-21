`timescale 1ns/1ps
module tb_stats_ae;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0, ce=1;
 reg [7:0] pixel; reg pv=0, ps=0, pl=0, scfg=0, acfg=0;
 wire pr, scr, sdone, serr, marker, busy;
 wire [5:0] addr; wire bank;
 wire [50:0] data;
 wire rn, rb; wire [1:0] rd; wire [15:0] rf; wire [13:0] rc;
 ispstats_stream #(.BITS(8),.CH(1),.MAX_W(3),.MAX_H(2)) meter(
 .clk(clk),.rst_n(rst_n),.s_tdata(pixel),.s_tvalid(pv),.s_tready(pr),.s_tuser(ps),.s_tlast(pl),
 .res_addr(addr),.res_bank(bank),.res_data(data),.res_new(rn),.res_new_bank(rb),.res_done(rd),
 .res_frame(rf),.res_count(rc),.cfg_valid(scfg),.cfg_ready(scr),.cfg_img_w(2'd3),.cfg_img_h(2'd2),
 .cfg_zx(4'd3),.cfg_zy(4'd2),.cfg_thresh(8'd200),.cfg_done(sdone),.cfg_error(serr),
 .marker_error(marker),.busy(busy));
 wire sv,sr,ov; wire [47:0] sum; wire [31:0] count,sat,fid,drops;
 ispstats_ae_bridge #(.CNTW(3),.SUMW(11),.ENW(12)) bridge(
 .clk(clk),.rst_n(rst_n),.res_new(rn),.res_new_bank(rb),
 .frame_records(rb ? rc[13:7]:rc[6:0]),.frame_id(32'd123),.frame_error(marker),.res_done(rd),
 .res_bank(bank),.res_addr(addr),.res_data(data),.stats_valid(sv),.stats_ready(sr),
 .stats_luma_sum(sum),.stats_count(count),.stats_saturated(sat),.stats_frame_id(fid),
 .stats_overflow(ov),.overrun(),.dropped_frames(drops));
 wire acr,aerr,uv,uerr; reg ur=1;
 wire [15:0] exp,gain,mean; wire [31:0] uid;
 img_ae_controller ae(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cfg_valid(acfg),.cfg_ready(acr),.cfg_error(aerr),
 .cfg_target(16'd128),.cfg_deadband(16'd3),.cfg_attack_shift(4'd2),.cfg_release_shift(4'd2),
 .cfg_exposure_min(16'd1),.cfg_exposure_max(16'd100),.cfg_gain_min(16'd256),.cfg_gain_max(16'd1024),
 .cfg_exposure_step(16'd8),.cfg_gain_step(16'd16),.cfg_saturation_limit(32'd10),
 .stats_valid(sv),.stats_ready(sr),.stats_luma_sum(sum),.stats_count(count),.stats_saturated(sat),
 .stats_frame_id(fid),.stats_overflow(ov),.update_valid(uv),.update_ready(ur),
 .exposure_lines(exp),.gain_q8(gain),.measured_mean(mean),.update_frame_id(uid),.update_error(uerr));
 task send(input [7:0] p,input s,input l);
 begin
  @(negedge clk); pixel=p;ps=s;pl=l;pv=1;
  @(posedge clk);while(!pr) @(posedge clk);
  @(negedge clk);pv=0;
 end endtask
 initial begin
  #100000;$fatal(1,"timeout");
 end
 initial begin
  repeat(3) @(negedge clk);rst_n=1;
  @(negedge clk);scfg=1;acfg=1;
  @(negedge clk);scfg=0;acfg=0;
  repeat(3) @(negedge clk);
  ce=0;ur=0;
  send(10,1,0);send(20,0,0);send(30,0,1);
  send(40,0,0);send(250,0,0);send(255,0,1);
  wait(sv);@(negedge clk);
  if(sum!==605 || count!==6 || sat!==2 || ov || fid!==123) $fatal(1,"bad accumulated stats");
  repeat(10) begin @(negedge clk);if(!sv || sum!==605) $fatal(1,"stall stability");end
  ce=1;
  wait(uv);@(negedge clk);
  if(uerr || mean!==100 || exp!==8 || gain!==256 || uid!==123) $fatal(1,"AE result %d %d %d",mean,exp,gain);
  repeat(8) @(negedge clk);
  if(!uv || mean!==100 || exp!==8) $fatal(1,"update stall");
  ur=1;repeat(2) @(negedge clk);
  if(serr || marker || drops) $fatal(1,"unexpected diagnostics");
  $display("STATS_AE PASS sum=605 count=6 sat=2 mean=100 exposure=8");$finish;
 end
endmodule
