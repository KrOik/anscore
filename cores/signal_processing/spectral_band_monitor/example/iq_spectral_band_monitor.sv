// SPDX-License-Identifier: Apache-2.0
// Complete fixed signed16 I/Q -> u32 power -> four band measurement chain.
module iq_spectral_band_monitor(
 input wire clk,rst,c_valid,output wire c_ready,
 input wire[31:0]c_bins,c_threshold,input wire[127:0]c_low,c_high,
 input wire[7:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[31:0]s_iq,
 output wire m_valid,input wire m_ready,output wire[1:0]m_status,
 output wire[31:0]m_band,m_low,m_high,
 output wire[41:0]m_energy,output wire[51:0]m_moment,
 output wire[31:0]m_peak_power,m_peak_bin,m_above,
 output wire m_last,output wire[7:0]m_tag
);
 reg[31:0]input_left;
 wire core_ready,power_valid,power_ready,iq_ready,unused_clip,cfg_ready,cfg_done,cfg_error;
 wire[31:0]power;
 wire iq_valid=s_valid &&core_ready &&input_left!=0;
 assign s_ready=!rst &&iq_ready &&core_ready &&input_left!=0;
 always @(posedge clk)begin
   if(rst)input_left<=0;
   else if(c_valid &&c_ready)input_left<=c_bins;
   else if(s_valid &&s_ready)input_left<=input_left-1'b1;
 end
 mag_squared magnitude(.clk(clk),.rst_n(!rst),.s_tdata(s_iq),.s_tvalid(iq_valid),.s_tready(iq_ready),
   .m_tdata(power),.m_tuser(unused_clip),.m_tvalid(power_valid),.m_tready(power_ready),
   .cfg_valid(1'b0),.cfg_ready(cfg_ready),.cfg_shift(5'd0),.cfg_done(cfg_done),.cfg_error(cfg_error));
 spectral_band_monitor monitor(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_bins(c_bins),
   .c_threshold(c_threshold),.c_low(c_low),.c_high(c_high),.c_tag(c_tag),
   .s_valid(power_valid),.s_ready(core_ready),.s_power(power),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_band(m_band),.m_low(m_low),.m_high(m_high),
   .m_energy(m_energy),.m_moment(m_moment),.m_peak_power(m_peak_power),.m_peak_bin(m_peak_bin),.m_above(m_above),
   .m_last(m_last),.m_tag(m_tag));
 assign power_ready=core_ready;
endmodule
