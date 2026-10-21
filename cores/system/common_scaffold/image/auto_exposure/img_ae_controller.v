// Frame-level AE actuator controller; no camera or side-channel claims.
`timescale 1ns/1ps
module img_ae_controller (
 input wire clk, rst_n, clk_en,
 input wire cfg_valid, output wire cfg_ready, output reg cfg_error,
 input wire [15:0] cfg_target, cfg_deadband,
 input wire [3:0] cfg_attack_shift, cfg_release_shift,
 input wire [15:0] cfg_exposure_min, cfg_exposure_max, cfg_gain_min, cfg_gain_max,
 input wire [15:0] cfg_exposure_step, cfg_gain_step,
 input wire [31:0] cfg_saturation_limit,
 input wire stats_valid, output wire stats_ready,
 input wire [47:0] stats_luma_sum,
 input wire [31:0] stats_count, stats_saturated, stats_frame_id,
 input wire stats_overflow,
 output reg update_valid, input wire update_ready,
 output reg [15:0] exposure_lines, gain_q8, measured_mean,
 output reg [31:0] update_frame_id,
 output reg update_error
);
 reg configured;
 reg [1:0] state;
 reg [15:0] target, band, emin, emax, gmin, gmax, estep, gstep;
 reg [3:0] attack, release_shift;
 reg [31:0] saturation_limit, denominator;
 reg saturated;
 reg [47:0] numerator, quotient;
 reg [32:0] remainder;
 reg [5:0] bits_left;
 wire [32:0] trial = {remainder[31:0],numerator[47]};
 wire [32:0] divisor = {1'b0,denominator};
 wire cfg_ok = cfg_target != 0 && cfg_deadband < cfg_target &&
   cfg_exposure_min != 0 && cfg_exposure_min <= cfg_exposure_max &&
   cfg_gain_min != 0 && cfg_gain_min <= cfg_gain_max &&
   cfg_exposure_step != 0 && cfg_gain_step != 0;
 wire [47:0] maximum_sum = ({16'b0,stats_count} << 16)-stats_count;
 assign cfg_ready = clk_en && state == 0 && !update_valid;
 assign stats_ready = cfg_ready && configured && !cfg_valid;
 reg [16:0] distance, step_e, step_g, room;
 reg decrease;
 always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
   configured<=0; state<=0; cfg_error<=0; update_valid<=0;
   exposure_lines<=1; gain_q8<=256; measured_mean<=0; update_frame_id<=0;
   update_error<=0; target<=128; band<=2; emin<=1; emax<=65535;
   gmin<=256; gmax<=4096; estep<=16; gstep<=16; attack<=2; release_shift<=2;
   saturation_limit<=0; denominator<=0; saturated<=0; numerator<=0;
   quotient<=0; remainder<=0; bits_left<=0;
  end else if (clk_en) begin
   cfg_error<=0;
   if (update_valid && update_ready) update_valid<=0;
   if (cfg_valid && cfg_ready) begin
    if (!cfg_ok) cfg_error<=1;
    else begin
     configured<=1; target<=cfg_target; band<=cfg_deadband;
     update_valid<=1; update_frame_id<=32'hffffffff;
     update_error<=0; measured_mean<=0;
     attack<=cfg_attack_shift; release_shift<=cfg_release_shift;
     emin<=cfg_exposure_min; emax<=cfg_exposure_max;
     gmin<=cfg_gain_min; gmax<=cfg_gain_max;
     estep<=cfg_exposure_step; gstep<=cfg_gain_step;
     saturation_limit<=cfg_saturation_limit;
     if(exposure_lines<cfg_exposure_min) exposure_lines<=cfg_exposure_min;
     else if(exposure_lines>cfg_exposure_max) exposure_lines<=cfg_exposure_max;
     if(gain_q8<cfg_gain_min) gain_q8<=cfg_gain_min;
     else if(gain_q8>cfg_gain_max) gain_q8<=cfg_gain_max;
    end
   end
   if(stats_valid && stats_ready) begin
    update_frame_id<=stats_frame_id; update_error<=0;
    if(stats_overflow || stats_count==0 || stats_saturated>stats_count || stats_luma_sum>maximum_sum) begin
     update_valid<=1; update_error<=1; measured_mean<=0;
    end else begin
     numerator<=stats_luma_sum; denominator<=stats_count;
     saturated<=stats_saturated>saturation_limit;
     quotient<=0; remainder<=0; bits_left<=48; state<=1;
    end
   end
   if(state==1) begin
    numerator<={numerator[46:0],1'b0};
    if(trial>=divisor) begin remainder<=trial-divisor; quotient<={quotient[46:0],1'b1}; end
    else begin remainder<=trial; quotient<={quotient[46:0],1'b0}; end
    bits_left<=bits_left-1'b1;
    if(bits_left==1) state<=2;
   end
   if(state==2) begin
    measured_mean<=quotient[15:0];
    decrease=saturated || quotient>({1'b0,target}+band);
    distance=0;
    if(decrease) begin
     if(quotient>target) distance=quotient-target;
     else distance=1;
    end else if(quotient+band<target) distance=target-quotient;
    if(distance!=0) begin
     step_e=distance >> (decrease ? attack : release_shift);
     if(step_e==0) step_e=1;
     step_g=step_e;
     if(step_e>estep) step_e=estep;
     if(step_g>gstep) step_g=gstep;
     if(decrease) begin
      if(exposure_lines>emin) begin
       room=exposure_lines-emin;
       exposure_lines<=exposure_lines-((step_e>room)?room:step_e);
      end else begin room=gain_q8-gmin; gain_q8<=gain_q8-((step_g>room)?room:step_g); end
     end else begin
      if(exposure_lines<emax) begin
       room=emax-exposure_lines;
       exposure_lines<=exposure_lines+((step_e>room)?room:step_e);
      end else begin room=gmax-gain_q8; gain_q8<=gain_q8+((step_g>room)?room:step_g); end
     end
    end
    update_valid<=1; state<=0;
   end
  end
 end
endmodule
