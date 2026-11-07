// SPDX-License-Identifier: Apache-2.0
// Actual unchanged strict dual decoder/merger -> timestamp pacer composition.
module paced_dual_itch_replay #(
 parameter integer TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [31:0] c_count,
 input wire [47:0] c_step_q16,input wire [TAG_W-1:0] c_tag,
 input wire run_enable,abort_run,
 input wire [1:0] cfg_valid,output wire [1:0] cfg_ready,
 input wire [159:0] cfg_session,input wire [127:0] cfg_next,
 input wire [1:0] s_valid,output wire [1:0] s_ready,input wire [15:0] s_data,
 input wire [1:0] s_keep,s_last,input wire [2*TAG_W-1:0] s_tag,
 output wire [1:0] packet_valid,input wire [1:0] packet_ready,
 output wire [7:0] packet_status,output wire [159:0] packet_session,
 output wire [127:0] packet_sequence,packet_next,output wire [31:0] packet_messages,packet_events,
 output wire [1:0] packet_end,output wire [2*TAG_W-1:0] packet_tag,
 input wire a_valid,output wire a_ready,input wire [2:0] a_op,input wire [31:0] a_feed,
 input wire [63:0] a_time,input wire [TAG_W-1:0] a_tag,
 output wire z_valid,input wire z_ready,output wire [2:0] z_op,output wire [3:0] z_status,
 output wire [31:0] z_feed,z_heads,output wire z_end,z_head,z_closed,z_has_previous,z_has_watermark,
 output wire [63:0] z_previous_time,z_previous_sequence,z_watermark,output wire [TAG_W-1:0] z_tag,
 output wire m_valid,input wire m_ready,output wire m_feed,output wire [63:0] m_time,m_sequence,
 output wire [511:0] m_data,output wire [TAG_W-1:0] m_tag,
 output wire error_valid,input wire error_ready,output wire error_feed,output wire [3:0] error_status,
 output wire [TAG_W-1:0] error_tag,output wire merge_faulted,source_fault,
 output wire d_valid,input wire d_ready,output wire [2:0] d_status,
 output wire [31:0] d_received,d_emitted,output wire [63:0] d_anchor,
 output wire [79:0] d_elapsed_q16,output wire [TAG_W-1:0] d_tag,
 output wire active,epoch_flush
);
 wire [1:0] merge_cfg_ready,merge_s_ready;
 wire event_valid,event_ready,event_feed;
 wire [63:0] event_time,event_sequence;
 wire [511:0] event_data;
 wire pacer_c_ready;
 wire [576:0] paced_data;
 reg poisoned;
 wire packet_fault=(packet_valid[0] && packet_status[3:0]!=0)
                  || (packet_valid[1] && packet_status[7:4]!=0);
 assign source_fault=poisoned || merge_faulted || error_valid || packet_fault;
 assign c_ready=pacer_c_ready && !source_fault;
 wire source_allow=!source_fault && !abort_run;
 assign cfg_ready=merge_cfg_ready & {2{source_allow}};
 assign s_ready=merge_s_ready & {2{source_allow}};
 assign {m_feed,m_sequence,m_data}=paced_data;
 always @(posedge clk)begin
  if(rst)poisoned<=0;
  else if(source_fault || (active && abort_run))poisoned<=1;
 end
 dual_itch_time_merge #(.TAG_W(TAG_W)) source(
  .clk(clk),.rst(rst),
  .cfg_valid(cfg_valid & {2{source_allow}}),.cfg_ready(merge_cfg_ready),
  .cfg_session(cfg_session),.cfg_next(cfg_next),
  .s_valid(s_valid & {2{source_allow}}),.s_ready(merge_s_ready),.s_data(s_data),
  .s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
  .packet_valid(packet_valid),.packet_ready(packet_ready),.packet_status(packet_status),
  .packet_session(packet_session),.packet_sequence(packet_sequence),.packet_next(packet_next),
  .packet_messages(packet_messages),.packet_events(packet_events),.packet_end(packet_end),.packet_tag(packet_tag),
  .a_valid(a_valid),.a_ready(a_ready),.a_op(a_op),.a_feed(a_feed),.a_time(a_time),.a_tag(a_tag),
  .z_valid(z_valid),.z_ready(z_ready),.z_op(z_op),.z_status(z_status),.z_feed(z_feed),.z_heads(z_heads),
  .z_end(z_end),.z_head(z_head),.z_closed(z_closed),.z_has_previous(z_has_previous),.z_has_watermark(z_has_watermark),
  .z_previous_time(z_previous_time),.z_previous_sequence(z_previous_sequence),.z_watermark(z_watermark),.z_tag(z_tag),
  .m_valid(event_valid),.m_ready(event_ready),.m_feed(event_feed),.m_time(event_time),
  .m_sequence(event_sequence),.m_data(event_data),
  .error_valid(error_valid),.error_ready(error_ready),.error_feed(error_feed),.error_status(error_status),
  .error_tag(error_tag),.faulted(merge_faulted));
 timestamp_event_replay #(.TIME_W(64),.DATA_W(577),.TAG_W(TAG_W)) pacer(
  .clk(clk),.rst(rst),.c_valid(c_valid && !source_fault),.c_ready(pacer_c_ready),
  .c_count(c_count),.c_step_q16(c_step_q16),.c_tag(c_tag),
  .run_enable(run_enable),.abort_run(abort_run || source_fault),
  .s_valid(event_valid),.s_ready(event_ready),.s_time(event_time),.s_data({event_feed,event_sequence,event_data}),
  .m_valid(m_valid),.m_ready(m_ready),.m_time(m_time),.m_data(paced_data),.m_tag(m_tag),
  .d_valid(d_valid),.d_ready(d_ready),.d_status(d_status),.d_received(d_received),.d_emitted(d_emitted),
  .d_anchor(d_anchor),.d_elapsed_q16(d_elapsed_q16),.d_tag(d_tag),.active(active),.epoch_flush(epoch_flush));
endmodule
