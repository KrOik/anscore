// SPDX-License-Identifier: Apache-2.0
`default_nettype none
// Actual capture composition: PRE=0 discards pretrigger observations; trigger
// plus the next 255 accepted ADC codes form one 256-sample measurement record.
module trigger_adc_density256 #(
 parameter integer FRAC_W=12,TAG_W=8,
 localparam integer COUNT_W=9,NUM_W=19,Q_W=FRAC_W+10
)(
 input wire clk,rst_n,
 input wire arm_valid,output wire arm_ready,
 input wire [7:0] arm_first,arm_last,input wire [TAG_W-1:0] arm_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_code,input wire s_trigger,
 output wire m_valid,input wire m_ready,
 output wire [7:0] m_code,output wire [COUNT_W-1:0] m_count,m_den,
 output wire signed [NUM_W-1:0] m_dnl_num,m_inl_num,
 output wire signed [Q_W-1:0] m_dnl_q,m_inl_q,
 output wire m_dnl_inexact,m_inl_inexact,m_zero_count,m_last,
 output wire [TAG_W-1:0] m_tag,
 output wire done_valid,input wire done_ready,output wire [1:0] done_status,
 output wire [TAG_W-1:0] done_tag,
 output wire busy,output wire capture_triggered
);
 wire capture_arm_ready,measure_cmd_ready,capture_valid,capture_ready,capture_last;
 wire [7:0] capture_data;
 wire capture_busy,measure_busy;
 wire [15:0] capture_length;
 // Both owners accept exactly the same arm. Invalid reversed ranges need no
 // capture: arm only the estimator, which immediately reports range error.
 wire legal_range=arm_first<=arm_last;
 assign arm_ready=measure_cmd_ready && (!legal_range || capture_arm_ready);
 wire arm_fire=arm_valid && arm_ready;
 sys_trigger_window #(.DEPTH(256),.PRE(0),.POST(255),.WIDTH(8)) capture(
  .clk(clk),.rst_n(rst_n),.arm(arm_fire && legal_range),.arm_ready(capture_arm_ready),
  .s_data(s_code),.s_trigger(s_trigger),.s_valid(s_valid),.s_ready(s_ready),
  .m_data(capture_data),.m_last(capture_last),.m_valid(capture_valid),.m_ready(capture_ready),
  .busy(capture_busy),.triggered(capture_triggered),.capture_length(capture_length));
 adc_code_density #(.SAMPLES(256),.FRAC_W(FRAC_W),.TAG_W(TAG_W)) measure(
  .clk(clk),.rst_n(rst_n),.cmd_valid(arm_fire),.cmd_ready(measure_cmd_ready),
  .cmd_first(arm_first),.cmd_last(arm_last),.cmd_tag(arm_tag),
  .s_valid(capture_valid),.s_ready(capture_ready),.s_code(capture_data),.s_last(capture_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_code(m_code),.m_count(m_count),.m_den(m_den),
  .m_dnl_num(m_dnl_num),.m_inl_num(m_inl_num),.m_dnl_q(m_dnl_q),.m_inl_q(m_inl_q),
  .m_dnl_inexact(m_dnl_inexact),.m_inl_inexact(m_inl_inexact),
  .m_zero_count(m_zero_count),.m_last(m_last),.m_tag(m_tag),
  .done_valid(done_valid),.done_ready(done_ready),.done_status(done_status),.done_tag(done_tag),.busy(measure_busy));
 assign busy=capture_busy || measure_busy;
endmodule
`default_nettype wire
