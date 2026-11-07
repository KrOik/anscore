// SPDX-License-Identifier: Apache-2.0
// Timestamp-paced finite stream. See README for exact edge/flush ownership.
module timestamp_event_replay #(
 parameter integer TIME_W=64,
 parameter integer DATA_W=64,
 parameter integer TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_count,input wire [47:0] c_step_q16,
 input wire [TAG_W-1:0] c_tag,
 input wire run_enable,abort_run,
 input wire s_valid,output wire s_ready,
 input wire [TIME_W-1:0] s_time,input wire [DATA_W-1:0] s_data,
 output wire m_valid,input wire m_ready,
 output wire [TIME_W-1:0] m_time,output wire [DATA_W-1:0] m_data,
 output wire [TAG_W-1:0] m_tag,
 output wire d_valid,input wire d_ready,output wire [2:0] d_status,
 output wire [31:0] d_received,d_emitted,
 output wire [TIME_W-1:0] d_anchor,
 output wire [TIME_W+15:0] d_elapsed_q16,
 output wire [TAG_W-1:0] d_tag,
 output wire active,epoch_flush
);
 localparam integer VT_W=TIME_W+16;
 localparam integer SUM_W=(VT_W>48?VT_W:48)+1;
 localparam [1:0] IDLE=0,RUN=1,FAULT_HOLD=2,DONE=3;
 localparam [2:0] OK=0,BAD_CONFIG=1,TIME_BACKWARDS=2,TIME_OVERFLOW=3,ABORTED=4;
 reg [1:0] state;
 reg anchored,head_present,offered;
 reg [31:0] expected,received,emitted;
 reg [47:0] step_q16;
 reg [VT_W-1:0] elapsed_q16,deadline_q16;
 reg [TIME_W-1:0] anchor,head_time;
 reg [DATA_W-1:0] head_data;
 reg [TAG_W-1:0] tag;
 reg [2:0] status;
 wire [SUM_W-1:0] time_sum={{(SUM_W-VT_W){1'b0}},elapsed_q16}
                               +{{(SUM_W-48){1'b0}},step_q16};
 wire tick_overflow=state==RUN && anchored && run_enable && (|time_sum[SUM_W-1:VT_W]);
 assign active=state==RUN || state==FAULT_HOLD;
 // Explicit epoch flush is the sole non-reset exception to a held output.
 assign epoch_flush=rst || (active && abort_run);
 assign c_ready=!rst && !abort_run && state==IDLE;
 assign s_ready=!epoch_flush && state==RUN && !head_present && received<expected && !tick_overflow;
 assign m_valid=!epoch_flush && active && offered;
 assign m_time=head_time;assign m_data=head_data;assign m_tag=tag;
 assign d_valid=!rst && state==DONE;
 assign d_status=status;assign d_received=received;assign d_emitted=emitted;
 assign d_anchor=anchor;assign d_elapsed_q16=elapsed_q16;assign d_tag=tag;
 wire input_take=s_valid && s_ready;
 wire output_take=m_valid && m_ready;
 wire final_take=output_take && emitted==expected-32'd1;
 generate if(TIME_W<1 || TIME_W>64 || DATA_W<1 || DATA_W>1024 || TAG_W<1 || TAG_W>32)begin:bad_parameters
  timestamp_event_replay_invalid_parameters__see_README invalid_configuration();
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;anchored<=0;head_present<=0;offered<=0;
   expected<=0;received<=0;emitted<=0;step_q16<=0;elapsed_q16<=0;deadline_q16<=0;
   anchor<=0;head_time<=0;tag<=0;status<=OK;
   // head_data is unreset: no valid consumer can observe it before capture.
  end else if(active && abort_run)begin
   state<=DONE;head_present<=0;offered<=0;status<=ABORTED;
   // Flush wins over every apparent transfer and freezes the old phase/counts.
  end else begin
   case(state)
    IDLE:if(c_valid && c_ready)begin
     expected<=c_count;step_q16<=c_step_q16;tag<=c_tag;
     received<=0;emitted<=0;anchored<=0;head_present<=0;offered<=0;
     elapsed_q16<=0;deadline_q16<=0;anchor<=0;head_time<=0;
     if(c_count==0 || c_step_q16==0)begin status<=BAD_CONFIG;state<=DONE;end
     else begin status<=OK;state<=RUN;end
    end
    RUN:begin
     if(final_take)begin
      emitted<=emitted+32'd1;head_present<=0;offered<=0;status<=OK;state<=DONE;
      // Final retirement ends time ownership; no terminal-edge tick is attempted.
     end else if(tick_overflow)begin
      // Never store the wrapped sum. A visible output retains its ownership.
      status<=TIME_OVERFLOW;
      if(output_take)begin
       emitted<=emitted+32'd1;head_present<=0;offered<=0;state<=DONE;
      end else if(offered)state<=FAULT_HOLD;
      else begin head_present<=0;offered<=0;state<=DONE;end
     end else if(input_take && anchored && s_time<head_time)begin
      received<=received+32'd1;head_present<=0;offered<=0;
      status<=TIME_BACKWARDS;state<=DONE;
     end else begin
      // Pre-edge phase makes a pending head eligible; this edge's tick follows.
      if(anchored && run_enable)elapsed_q16<=time_sum[VT_W-1:0];
      if(head_present && !offered && run_enable && elapsed_q16>=deadline_q16)offered<=1;
      if(output_take)begin emitted<=emitted+32'd1;head_present<=0;offered<=0;end
      if(input_take)begin
       received<=received+32'd1;head_present<=1;offered<=0;
       head_time<=s_time;head_data<=s_data;
       if(!anchored)begin
        anchor<=s_time;anchored<=1;elapsed_q16<=0;deadline_q16<=0;
       end else deadline_q16<={(s_time-anchor),16'd0};
      end
     end
    end
    FAULT_HOLD:if(output_take)begin
     emitted<=emitted+32'd1;head_present<=0;offered<=0;state<=DONE;
    end
    DONE:if(d_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
