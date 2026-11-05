// SPDX-License-Identifier: Apache-2.0
// Existing signed16 I/Q magnitude pipeline feeding the 1024-bin instrument.
module iq_occupied_bandwidth(
 input wire clk,rst,c_valid,output wire c_ready,input wire[31:0]c_bins,
 input wire[15:0]c_occupied_num,c_occupied_den,input wire[7:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[31:0]s_iq,
 output wire m_valid,input wire m_ready,output wire[1:0]m_status,
 output wire[31:0]m_low,m_high,m_span,
 output wire[41:0]m_total,m_retained,m_below,m_above,output wire[7:0]m_tag
);
 reg[31:0]input_left;
 wire collect_ready,iq_ready,power_valid,unused_clip,cfg_ready,cfg_done,cfg_error;
 wire[31:0]power;
 wire iq_valid=s_valid &&collect_ready &&input_left!=0;
 assign s_ready=!rst &&collect_ready &&input_left!=0 &&iq_ready;
 always @(posedge clk)begin
   if(rst)input_left<=0;
   else if(c_valid &&c_ready)input_left<=c_bins;
   else if(s_valid &&s_ready)input_left<=input_left-1'b1;
 end
 mag_squared magnitude(.clk(clk),.rst_n(!rst),.s_tdata(s_iq),.s_tvalid(iq_valid),.s_tready(iq_ready),
   .m_tdata(power),.m_tuser(unused_clip),.m_tvalid(power_valid),.m_tready(collect_ready),
   .cfg_valid(1'b0),.cfg_ready(cfg_ready),.cfg_shift(5'd0),.cfg_done(cfg_done),.cfg_error(cfg_error));
 occupied_spectral_bandwidth instrument(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
   .c_bins(c_bins),.c_occupied_num(c_occupied_num),.c_occupied_den(c_occupied_den),.c_tag(c_tag),
   .s_valid(power_valid),.s_ready(collect_ready),.s_power(power),.m_valid(m_valid),.m_ready(m_ready),
   .m_status(m_status),.m_low(m_low),.m_high(m_high),.m_span(m_span),.m_total(m_total),
   .m_retained(m_retained),.m_below(m_below),.m_above(m_above),.m_tag(m_tag));
endmodule
