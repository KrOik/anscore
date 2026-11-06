// SPDX-License-Identifier: Apache-2.0
// Bounded 64-sample burst service; actual acquisition/rotation composition is in core.
module burst64_cfo(
 input wire clk,rst,c_valid,output wire c_ready,
 input wire[31:0]c_samples,c_threshold_q16,input wire[63:0]c_min_energy,input wire[7:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[23:0]s_iq,input wire s_last,
 output wire m_valid,input wire m_ready,output wire[3:0]m_status,
 output wire[23:0]m_iq,output wire[31:0]m_index,output wire m_last,
 output wire[7:0]m_tag,output wire[1:0]m_clip,
 output wire[23:0]m_phase,output wire[31:0]m_correction
);
 burst_cfo_correct #(.MAX_SAMPLES(64),.TAG_W(8)) correct(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_samples(c_samples),
   .c_threshold_q16(c_threshold_q16),.c_min_energy(c_min_energy),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_iq(s_iq),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_iq(m_iq),.m_index(m_index),
   .m_last(m_last),.m_tag(m_tag),.m_clip(m_clip),.m_phase(m_phase),.m_correction(m_correction));
endmodule
