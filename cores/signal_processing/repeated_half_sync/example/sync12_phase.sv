// SPDX-License-Identifier: Apache-2.0
// Exact 12-bit/L16 P -> existing full-circle atan2; metadata follows each angle.
module sync12_phase(
 input wire clk,rst,c_valid,output wire c_ready,
 input wire[31:0]c_samples,c_threshold_q16,c_hold,input wire[63:0]c_min_energy,input wire[7:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[23:0]s_iq,input wire s_last,
 output wire m_valid,input wire m_ready,output wire[2:0]m_status,
 output wire[31:0]m_end,m_start,m_event_start,output wire m_qual,m_event,m_last,
 output wire[7:0]m_tag,output wire[23:0]m_phase,output wire m_zero
);
 wire cv,sv,sr,last,qual,event_flag;
 wire[2:0]status;
 wire[31:0]end_index,start_index,event_start;
 wire[7:0]tag;
 wire[28:0]energy;
 wire signed[28:0]pre,pim;
 reg meta_full;
 reg[2:0]meta_status;
 reg[31:0]meta_end,meta_start,meta_event_start;
 reg meta_qual,meta_event;
 wire angle_ready,angle_valid;
 assign c_ready=cv &&!meta_full;
 repeated_half_sync #(.DATA_W(12),.L(16),.MAX_SAMPLES(1024),.TAG_W(8)) detector(
   .clk(clk),.rst(rst),.c_valid(c_valid &&!meta_full),.c_ready(cv),
   .c_samples(c_samples),.c_threshold_q16(c_threshold_q16),.c_hold(c_hold),.c_min_energy(c_min_energy),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_iq(s_iq),.s_last(s_last),
   .m_valid(sv),.m_ready(sr),.m_status(status),.m_end(end_index),.m_start(start_index),
   .m_event_start(event_start),.m_qual(qual),.m_event(event_flag),.m_last(last),.m_tag(tag),
   .m_energy(energy),.m_cross_re(pre),.m_cross_im(pim));
 assign sr=angle_ready &&!meta_full;
 stream_atan2 #(.IN_W(29),.PHASE_W(24),.ITER(24),.TAG_W(8)) phase_core(
   .clk(clk),.rst(rst),.s_valid(sv &&!meta_full),.s_ready(angle_ready),.s_x(pre),.s_y(pim),
   .s_last(last),.s_tag(tag),.m_valid(angle_valid),.m_ready(m_ready &&meta_full),
   .m_phase(m_phase),.m_zero(m_zero),.m_last(m_last),.m_tag(m_tag));
 assign m_valid=!rst &&angle_valid &&meta_full;
 assign m_status=meta_status;assign m_end=meta_end;assign m_start=meta_start;
 assign m_event_start=meta_event_start;assign m_qual=meta_qual;assign m_event=meta_event;
 always @(posedge clk)begin
   if(rst)begin
     meta_full<=0;meta_status<=0;meta_end<=0;meta_start<=0;meta_event_start<=0;meta_qual<=0;meta_event<=0;
   end else begin
     if(m_valid &&m_ready)meta_full<=0;
     if(sv &&sr)begin
       meta_full<=1;meta_status<=status;meta_end<=end_index;meta_start<=start_index;
       meta_event_start<=event_start;meta_qual<=qual;meta_event<=event_flag;
     end
   end
 end
endmodule
