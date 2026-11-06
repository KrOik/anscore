// SPDX-License-Identifier: Apache-2.0
// Natural-order complex FFT bins -> unchanged magnitude pipeline -> instrument.
module iq_spectral_harmonic_quality #(
 parameter integer MAX_LOG2N=8,MAX_HARMONICS=8,TAG_W=8,
 localparam integer SUM_W=32+MAX_LOG2N-1,RATIO_W=SUM_W+17
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire[31:0]c_log2n,c_harmonics,c_radius,c_search_low,c_search_high,
 input wire[TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[31:0]s_iq,
 input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,output wire[2:0]m_status,
 output wire[TAG_W-1:0]m_tag,
 output wire[31:0]m_log2n,m_harmonics,m_radius,m_search_low,m_search_high,
 output wire[12:0]m_received,output wire[31:0]m_fund_bin,m_peak_power,
 output wire[SUM_W-1:0]m_total,m_fund,m_harm,m_residual,
 output wire[MAX_HARMONICS*SUM_W-1:0]m_components,
 output wire[RATIO_W-1:0]m_thd2_q16,m_snr_q16,m_sinad_q16,
 output wire[2:0]m_ratio_valid
);
 reg support_reset_n;
 reg[12:0]input_left;
 reg[3:0]last_pipe,invalid_pipe;
 wire power_valid,power_ready,iq_ready,power_clip,cfg_ready,cfg_done,cfg_error;
 wire[31:0]power;
 wire advance=!power_valid ||power_ready;
 wire iq_valid=!rst &&s_valid &&input_left!=0 &&power_ready;
 wire input_fire=s_valid &&s_ready;
 assign s_ready=!rst &&support_reset_n &&input_left!=0 &&power_ready &&iq_ready;
 always @(posedge clk)begin
   if(rst)begin
     support_reset_n<=0;input_left<=0;last_pipe<=0;invalid_pipe<=0;
   end else begin
     support_reset_n<=1;
     if(c_valid &&c_ready)
       input_left<=(c_log2n>=4 &&c_log2n<=MAX_LOG2N)?(13'd1<<c_log2n):13'd0;
     else if(input_fire)input_left<=s_last?13'd0:input_left-1'b1;
     if(advance)begin
       last_pipe<={last_pipe[2:0],input_fire &&s_last};
       invalid_pipe<={invalid_pipe[2:0],input_fire &&s_invalid};
     end
   end
 end
 mag_squared magnitude(
   .clk(clk),.rst_n(support_reset_n),.s_tdata(s_iq),.s_tvalid(iq_valid),.s_tready(iq_ready),
   .m_tdata(power),.m_tuser(power_clip),.m_tvalid(power_valid),.m_tready(power_ready),
   .cfg_valid(1'b0),.cfg_ready(cfg_ready),.cfg_shift(5'd0),.cfg_done(cfg_done),.cfg_error(cfg_error));
 spectral_harmonic_quality #(.MAX_LOG2N(MAX_LOG2N),.MAX_HARMONICS(MAX_HARMONICS),.TAG_W(TAG_W)) instrument(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
   .c_log2n(c_log2n),.c_harmonics(c_harmonics),.c_radius(c_radius),
   .c_search_low(c_search_low),.c_search_high(c_search_high),.c_tag(c_tag),
   .s_valid(power_valid),.s_ready(power_ready),.s_power(power),
   .s_last(last_pipe[3]),.s_invalid(invalid_pipe[3] ||power_clip),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),
   .m_log2n(m_log2n),.m_harmonics(m_harmonics),.m_radius(m_radius),
   .m_search_low(m_search_low),.m_search_high(m_search_high),.m_received(m_received),
   .m_fund_bin(m_fund_bin),.m_peak_power(m_peak_power),.m_total(m_total),.m_fund(m_fund),
   .m_harm(m_harm),.m_residual(m_residual),.m_components(m_components),
   .m_thd2_q16(m_thd2_q16),.m_snr_q16(m_snr_q16),.m_sinad_q16(m_sinad_q16),.m_ratio_valid(m_ratio_valid));
endmodule
