// SPDX-License-Identifier: Apache-2.0
// One-window measurement adapter. External sample/reference phase are one beat.
module gated_tone_measure #(
 parameter integer MAX_SAMPLES=256,TAG_W=8
)(
 input wire clk,rst,c_valid,output wire c_ready,input wire [31:0] c_count,
 input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire signed [15:0] s_sample,
 input wire [23:0] s_phase,input wire s_last,
 output wire m_valid,input wire m_ready,output wire [2:0] m_status,
 output wire [31:0] m_requested,output wire [8:0] m_count,
 output wire [TAG_W-1:0] m_tag,
 output wire signed [127:0] m_i_numerator,m_q_numerator,
 output wire [111:0] m_denominator,
 output wire signed [55:0] m_gram_a,m_gram_b,m_gram_d
);
 known_phase_tone_fit #(.MAX_SAMPLES(MAX_SAMPLES),.TAG_W(TAG_W)) fit(
  .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_count(c_count),.c_tag(c_tag),
  .s_valid(s_valid),.s_ready(s_ready),.s_sample(s_sample),.s_phase(s_phase),.s_last(s_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_requested(m_requested),
  .m_count(m_count),.m_tag(m_tag),.m_i_numerator(m_i_numerator),.m_q_numerator(m_q_numerator),
  .m_denominator(m_denominator),.m_gram_a(m_gram_a),.m_gram_b(m_gram_b),.m_gram_d(m_gram_d));
endmodule
