// SPDX-License-Identifier: Apache-2.0
// Existing ring capture selects the trigger sample and 255 following samples.
module trigger_phase_allan256(
 input wire clk,rst,a_valid,output wire a_ready,
 input wire [31:0] a_m,input wire [7:0] a_tag,
 input wire s_valid,output wire s_ready,
 input wire signed [15:0] s_phase,input wire s_trigger,s_invalid,
 output wire m_valid,input wire m_ready,
 output wire [2:0] m_status,output wire [7:0] m_tag,
 output wire [31:0] m_samples,m_m,output wire [12:0] m_received,m_terms,
 output wire [41:0] m_sum,output wire [24:0] m_den,
 output wire [49:0] m_variance_q16
);
 reg active,capture_rst_n;
 always @(posedge clk)capture_rst_n<=!rst;
 wire capture_ready,command_ready,capture_valid,capture_last,measure_ready,capture_input_ready;
 wire [16:0] capture_data;
 wire capture_busy,capture_triggered;
 wire [15:0] capture_length;
 wire legal_m=a_m>=1&&a_m<=64;
 assign a_ready=!rst&&!active&&capture_ready&&command_ready;
 wire start=a_valid&&a_ready;
 assign s_ready=!rst&&capture_input_ready;
 always @(posedge clk)begin
  if(rst)active<=0;
  else if(start)active<=1;
  else if(m_valid&&m_ready)active<=0;
 end
 sys_trigger_window #(.DEPTH(256),.PRE(0),.POST(255),.WIDTH(17)) capture(
  .clk(clk),.rst_n(capture_rst_n),.arm(start&&legal_m),.arm_ready(capture_ready),
  .s_data({s_invalid,s_phase}),.s_trigger(s_trigger),.s_valid(s_valid&&!rst),.s_ready(capture_input_ready),
  .m_data(capture_data),.m_last(capture_last),.m_valid(capture_valid),.m_ready(measure_ready),
  .busy(capture_busy),.triggered(capture_triggered),.capture_length(capture_length));
 phase_allan_variance measure(
  .clk(clk),.rst(rst),.c_valid(start),.c_ready(command_ready),.c_samples(32'd256),.c_m(a_m),.c_tag(a_tag),
  .s_valid(capture_valid),.s_ready(measure_ready),.s_phase(capture_data[15:0]),
  .s_last(capture_last),.s_invalid(capture_data[16]),
  .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),
  .m_samples(m_samples),.m_m(m_m),.m_received(m_received),.m_terms(m_terms),
  .m_sum(m_sum),.m_den(m_den),.m_variance_q16(m_variance_q16));
endmodule
