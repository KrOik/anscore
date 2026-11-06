// SPDX-License-Identifier: Apache-2.0
// One arm owns acquisition through final measurement. The capture has dead time.
module trigger_pulse256(
 input wire clk,rst,input wire a_valid,output wire a_ready,
 input wire signed[11:0]a_baseline,input wire a_negative,
 input wire[31:0]a_fraction,input wire[11:0]a_min_peak,input wire[7:0]a_tag,
 input wire s_valid,output wire s_ready,input wire signed[11:0]s_sample,input wire s_trigger,
 output wire m_valid,input wire m_ready,output wire[3:0]m_status,output wire[7:0]m_tag,
 output wire[11:0]m_peak,output wire[7:0]m_peak_index,output wire[1:0]m_sides,
 output wire[23:0]m_left_q16,m_right_q16,m_width_q16
);
 reg capture_rst_n;
 always @(posedge clk)capture_rst_n<=!rst;
 reg owned,started;
 reg signed[11:0]baseline;
 reg negative;
 reg[31:0]fraction;
 reg[11:0]min_peak;
 reg[7:0]tag;
 wire arm_ready,capture_valid,capture_ready,core_ready,core_sample_ready,s_ready_internal;
 wire[11:0]capture_sample;
 wire capture_last,capture_busy,triggered;
 wire[15:0]capture_length;
 assign a_ready=!rst&&capture_rst_n&&!owned&&arm_ready;
 // Invalid fraction/minimum is checked by the core before arming acquisition.
 wire bad_config=a_fraction==0||a_fraction>255||a_min_peak==0;
 sys_trigger_window #(.DEPTH(256),.PRE(64),.POST(191),.WIDTH(12)) capture(
  .clk(clk),.rst_n(capture_rst_n),.arm(a_valid&&a_ready&&!bad_config),.arm_ready(arm_ready),
  .s_data(s_sample),.s_trigger(s_trigger),.s_valid(s_valid&&!rst),.s_ready(s_ready_internal),
  .m_data(capture_sample),.m_last(capture_last),.m_valid(capture_valid),.m_ready(capture_ready),
  .busy(capture_busy),.triggered(triggered),.capture_length(capture_length));
 assign s_ready=!rst&&s_ready_internal;
 wire core_command=owned&&!started&&(capture_valid||fraction==0||fraction>255||min_peak==0);
 assign capture_ready=started&&core_sample_ready&&!rst;
 pulse_fraction_timing #(.DATA_W(12),.MAX_SAMPLES(256),.TAG_W(8)) measure(
  .clk(clk),.rst(rst),.c_valid(core_command),.c_ready(core_ready),
  .c_samples((fraction==0||fraction>255||min_peak==0)?32'd256:{16'b0,capture_length}),
  .c_fraction(fraction),.c_baseline(baseline),.c_negative(negative),.c_min_peak(min_peak),.c_tag(tag),
  .s_valid(capture_valid&&started&&!rst),.s_ready(core_sample_ready),.s_sample(capture_sample),.s_last(capture_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_peak(m_peak),
  .m_peak_index(m_peak_index),.m_sides(m_sides),.m_left_q16(m_left_q16),.m_right_q16(m_right_q16),.m_width_q16(m_width_q16));
 always @(posedge clk)begin
  if(rst)begin owned<=0;started<=0;end
  else begin
   if(a_valid&&a_ready)begin
    owned<=1;started<=0;baseline<=a_baseline;negative<=a_negative;fraction<=a_fraction;min_peak<=a_min_peak;tag<=a_tag;
   end
   if(core_command&&core_ready)started<=1;
   if(m_valid&&m_ready)begin owned<=0;started<=0;end
  end
 end
endmodule
