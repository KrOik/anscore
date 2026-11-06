// SPDX-License-Identifier: Apache-2.0
`default_nettype none
// Actual unchanged mag_squared composition for already transformed FFT bins.
// One outstanding complex beat carries LAST through the power pipeline.
module iq_spectral_kurtosis64 #(
 parameter integer BINS=64,FRAMES=16,FRAC_W=12,TAG_W=8,
 localparam integer BIN_W=(BINS<2)?1:$clog2(BINS),GROW=$clog2(FRAMES),
 localparam integer COEF_W=$clog2(FRAMES+2),SUM_W=32+GROW,SUM2_W=64+GROW,
 localparam integer STAT_W=2*SUM_W+COEF_W,Q_W=FRAC_W+COEF_W
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [Q_W-1:0] c_lower,c_upper,input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [31:0] s_complex,input wire s_last,
 output wire m_valid,input wire m_ready,output wire [2:0] m_status,
 output wire [BIN_W-1:0] m_bin,output wire [SUM_W-1:0] m_sum,
 output wire [SUM2_W-1:0] m_sum2,output wire [STAT_W-1:0] m_numerator,m_denominator,
 output wire [Q_W-1:0] m_sk_q,output wire m_inexact,m_outside,m_last,
 output wire [TAG_W-1:0] m_tag,output wire busy
);
 localparam integer TOTAL=BINS*FRAMES,LEFT_W=$clog2(TOTAL+1);
 reg owned,pending,held_last,input_closed;
 reg [LEFT_W-1:0] left;
 reg [BIN_W-1:0] input_bin;
 wire core_ready,power_ready,power_valid,mag_ready;
 wire [31:0] power_data;
 wire mag_user,cfg_ready,cfg_done,cfg_error,core_busy;
 wire offer=owned && !pending && !input_closed;
 assign c_ready=!rst && !owned && core_ready;
 assign s_ready=!rst && offer && mag_ready;
 assign busy=!rst && (owned || core_busy);
 mag_squared power(
  .clk(clk),.rst_n(!rst && owned),.s_tdata(s_complex),
  .s_tvalid(!rst && offer && s_valid),.s_tready(mag_ready),
  .m_tdata(power_data),.m_tuser(mag_user),.m_tvalid(power_valid),
  .m_tready(power_ready && pending && owned),
  .cfg_valid(1'b0),.cfg_ready(cfg_ready),.cfg_shift(5'd0),.cfg_done(cfg_done),.cfg_error(cfg_error));
 spectral_kurtosis #(.BINS(BINS),.FRAMES(FRAMES),.POWER_W(32),.FRAC_W(FRAC_W),.TAG_W(TAG_W)) measure(
  .clk(clk),.rst(rst),.c_valid(c_valid && !owned),.c_ready(core_ready),
  .c_lower(c_lower),.c_upper(c_upper),.c_tag(c_tag),
  .s_valid(power_valid && pending && owned),.s_ready(power_ready),.s_power(power_data),.s_last(held_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_bin(m_bin),.m_sum(m_sum),.m_sum2(m_sum2),
  .m_numerator(m_numerator),.m_denominator(m_denominator),.m_sk_q(m_sk_q),
  .m_inexact(m_inexact),.m_outside(m_outside),.m_last(m_last),.m_tag(m_tag),.busy(core_busy));
 always @(posedge clk)begin
  if(rst)begin owned<=0;pending<=0;held_last<=0;input_closed<=1;left<=0;input_bin<=0;end
  else begin
   if(c_valid && c_ready)begin
    owned<=1;pending<=0;input_closed<=(c_lower>c_upper);left<=TOTAL;input_bin<=0;
   end
   if(s_valid && s_ready)begin
    pending<=1;held_last<=s_last;left<=left-1'b1;
    if(left==1 || s_last!==(input_bin==BINS-1))input_closed<=1;
    if(input_bin==BINS-1)input_bin<=0;else input_bin<=input_bin+1'b1;
   end
   if(power_valid && power_ready && pending && owned)pending<=0;
   if(m_valid && m_ready && m_last)begin owned<=0;pending<=0;input_closed<=1;end
  end
 end
endmodule
`default_nettype wire
