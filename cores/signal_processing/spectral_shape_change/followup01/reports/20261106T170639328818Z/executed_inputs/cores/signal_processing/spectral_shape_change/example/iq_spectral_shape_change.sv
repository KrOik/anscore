// SPDX-License-Identifier: Apache-2.0
// Already-transformed signed16 complex bins. Fixed unshifted power units.
`default_nettype none
module iq_spectral_shape_change #(
 parameter integer MAX_BINS=64,TAG_W=8,
 localparam integer COUNT_W=$clog2(MAX_BINS+1),
 localparam integer SUM_W=32+((MAX_BINS>1)?$clog2(MAX_BINS):0),
 localparam integer STAT_W=2*SUM_W
)(
 input wire clk,rst,input wire c_valid,output wire c_ready,input wire [31:0] c_bins,
 input wire c_restart,input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [31:0] s_iq,input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,output wire [3:0] m_status,
 output wire [TAG_W-1:0] m_tag,output wire [31:0] m_bins,
 output wire [COUNT_W-1:0] m_received,
 output wire [SUM_W-1:0] m_total,m_reference_total,
 output wire [STAT_W-1:0] m_numerator,m_denominator,
 output wire [16:0] m_change_q16,output wire m_metric_valid,m_inexact,output wire busy
);
 reg magnitude_n;
 reg [COUNT_W-1:0] input_left;
 reg [2:0] in_flight;
 reg [3:0] last_pipe,invalid_pipe;
 wire core_ready,power_ready,iq_ready,power_valid,power_clip,cfg_ready,cfg_done,cfg_error;
 wire [31:0] power;
 wire command_allowed=magnitude_n && input_left==0 && in_flight==0 && !power_valid;
 wire command_fire=c_valid && c_ready;
 wire iq_valid=!rst && magnitude_n && input_left!=0 && power_ready && s_valid;
 assign c_ready=!rst && command_allowed && core_ready;
 assign s_ready=!rst && magnitude_n && input_left!=0 && power_ready && iq_ready;
 wire input_fire=s_valid && s_ready;
 wire power_fire=power_valid && power_ready;
 wire advance=!power_valid || power_ready;
 always @(posedge clk)begin
  if(rst)begin magnitude_n<=0;input_left<=0;in_flight<=0;last_pipe<=0;invalid_pipe<=0;end
  else begin
   magnitude_n<=1;
   if(command_fire)input_left<=(c_bins>=1 && c_bins<=MAX_BINS)?c_bins[COUNT_W-1:0]:{COUNT_W{1'b0}};
   else if(input_fire)input_left<=(s_last || s_invalid)?{COUNT_W{1'b0}}:input_left-1'b1;
   case({input_fire,power_fire})
    2'b10:in_flight<=in_flight+1'b1;
    2'b01:in_flight<=in_flight-1'b1;
    default:in_flight<=in_flight;
   endcase
   if(advance)begin
    last_pipe<={last_pipe[2:0],input_fire && s_last};
    invalid_pipe<={invalid_pipe[2:0],input_fire && s_invalid};
   end
  end
 end
 mag_squared magnitude(.clk(clk),.rst_n(magnitude_n),.s_tdata(s_iq),.s_tvalid(iq_valid),.s_tready(iq_ready),
  .m_tdata(power),.m_tuser(power_clip),.m_tvalid(power_valid),.m_tready(power_ready),
  .cfg_valid(1'b0),.cfg_ready(cfg_ready),.cfg_shift(5'd0),.cfg_done(cfg_done),.cfg_error(cfg_error));
 spectral_shape_change #(.MAX_BINS(MAX_BINS),.TAG_W(TAG_W)) instrument(
  .clk(clk),.rst(rst),.c_valid(c_valid && command_allowed),.c_ready(core_ready),.c_bins(c_bins),
  .c_restart(c_restart),.c_tag(c_tag),.s_valid(power_valid),.s_ready(power_ready),.s_power(power),
  .s_last(last_pipe[3]),.s_invalid(invalid_pipe[3] || power_clip),
  .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_bins(m_bins),
  .m_received(m_received),.m_total(m_total),.m_reference_total(m_reference_total),
  .m_numerator(m_numerator),.m_denominator(m_denominator),.m_change_q16(m_change_q16),
  .m_metric_valid(m_metric_valid),.m_inexact(m_inexact),.busy(busy));
endmodule
`default_nettype wire
