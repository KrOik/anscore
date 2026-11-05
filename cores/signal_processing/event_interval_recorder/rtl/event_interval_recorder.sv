// SPDX-License-Identifier: Apache-2.0
// Synchronous reference/observation pulse instrument. Physical clocks never stall.
module event_interval_recorder #(
 parameter integer TIME_W=32, EPOCH_W=16, FIFO_DEPTH=4, DROP_W=32, TAG_W=8
)(
 input wire clk,rst,
 input wire arm_valid, output wire arm_ready,
 input wire [31:0] arm_window, input wire [TAG_W-1:0] arm_tag,
 input wire reference_event,observation_event,stop,
 output wire busy,running,
 output wire m_valid, input wire m_ready,
 output wire [TIME_W-1:0] m_interval,
 output wire [EPOCH_W-1:0] m_epoch,
 output wire [1:0] m_status, output wire [TAG_W-1:0] m_tag,
 output wire done_valid,input wire done_ready,
 output wire done_error,
 output wire [DROP_W-1:0] done_dropped,
 output wire done_drop_saturated,output wire [TAG_W-1:0] done_tag
);
 localparam integer PW=(FIFO_DEPTH<=1)?1:$clog2(FIFO_DEPTH);
 localparam integer CW=(FIFO_DEPTH<=1)?1:$clog2(FIFO_DEPTH+1);
 localparam integer RW=TIME_W+EPOCH_W+2;
 localparam [1:0] IDLE=0,RUN=1,DRAIN=2,DONE=3;
 reg [1:0] state;
 reg [TIME_W-1:0] window,age;
 reg have_reference,expired,error,drop_saturated;
 reg [EPOCH_W-1:0] epoch;
 reg [TAG_W-1:0] tag;
 reg [DROP_W-1:0] dropped;
 reg [PW-1:0] write_ptr,read_ptr;
 reg [CW-1:0] count;
 reg [RW-1:0] fifo[0:FIFO_DEPTH-1];
 wire [TIME_W:0] next_age={1'b0,age}+{{TIME_W{1'b0}},1'b1};
 wire candidate_no_reference=!reference_event && !have_reference;
 wire candidate_expired=!reference_event && have_reference &&
                        (expired || next_age>{1'b0,window});
 wire [1:0] candidate_status=candidate_no_reference?2'd1:(candidate_expired?2'd2:2'd0);
 wire [TIME_W-1:0] candidate_interval=(reference_event || candidate_status!=0)?{TIME_W{1'b0}}:next_age[TIME_W-1:0];
 wire [EPOCH_W-1:0] candidate_epoch=reference_event?epoch+1'b1:epoch;
 wire pop=m_valid && m_ready;
 wire observed=(state==RUN) && !stop && observation_event;
 wire push=observed && (count<FIFO_DEPTH || pop);
 wire lost=observed && !push;
 wire [32:0] maximum_window=(33'd1<<TIME_W)-1'b1;
 function automatic [PW-1:0] advance(input [PW-1:0] ptr);
   advance=(ptr==FIFO_DEPTH-1)?{PW{1'b0}}:ptr+1'b1;
 endfunction
 generate if(TIME_W<1 || TIME_W>32 || EPOCH_W<1 || EPOCH_W>32 ||
             FIFO_DEPTH<1 || FIFO_DEPTH>16 || DROP_W<1 || DROP_W>32 ||
             TAG_W<1 || TAG_W>32)begin:invalid
   event_interval_recorder_invalid_parameters__see_README bad_parameters();
 end endgenerate
 assign arm_ready=!rst && state==IDLE;
 assign busy=(state!=IDLE);
 assign running=(state==RUN);
 assign m_valid=!rst && count!=0;
 assign {m_status,m_epoch,m_interval}=fifo[read_ptr];
 assign m_tag=tag;
 assign done_valid=!rst && state==DONE;
 assign done_error=error;
 assign done_dropped=dropped;
 assign done_drop_saturated=drop_saturated;
 assign done_tag=tag;

 always @(posedge clk) begin
   if(push && !rst) fifo[write_ptr]<={candidate_status,candidate_epoch,candidate_interval};
 end
 always @(posedge clk) begin
   if(rst)begin
     state<=IDLE;window<=0;age<=0;have_reference<=0;expired<=0;epoch<=0;
     error<=0;tag<=0;dropped<=0;drop_saturated<=0;write_ptr<=0;read_ptr<=0;count<=0;
   end else if(arm_valid && arm_ready)begin
     tag<=arm_tag;window<=arm_window[TIME_W-1:0];age<=0;have_reference<=0;expired<=0;
     epoch<=0;dropped<=0;drop_saturated<=0;write_ptr<=0;read_ptr<=0;count<=0;
     error<=({1'b0,arm_window}>maximum_window);
     state<=({1'b0,arm_window}>maximum_window)?DONE:RUN;
   end else begin
     if(pop)read_ptr<=advance(read_ptr);
     if(push)write_ptr<=advance(write_ptr);
     case({push,pop})
       2'b10:count<=count+1'b1;
       2'b01:count<=count-1'b1;
       default:count<=count;
     endcase
     if(lost)begin
       if(&dropped)drop_saturated<=1;
       else dropped<=dropped+1'b1;
     end
     case(state)
       RUN: if(stop)state<=DRAIN;
            else if(reference_event)begin
              age<=0;have_reference<=1;expired<=0;epoch<=epoch+1'b1;
            end else if(have_reference && !expired)begin
              if(next_age>{1'b0,window})expired<=1;
              else age<=next_age[TIME_W-1:0];
            end
       DRAIN:if(count==0)state<=DONE;
       DONE:if(done_ready)state<=IDLE;
       default:state<=state;
     endcase
   end
 end
endmodule
