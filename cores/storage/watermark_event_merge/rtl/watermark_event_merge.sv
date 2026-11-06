// SPDX-License-Identifier: Apache-2.0
// Original bounded online event-time merge. No external source is incorporated.
module watermark_event_merge #(
 parameter integer FEEDS=4, DATA_W=128, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [3:0] c_op,
 input wire [31:0] c_feed,input wire [63:0] c_time,c_sequence,
 input wire [DATA_W-1:0] c_data,input wire [TAG_W-1:0] c_tag,
 output wire r_valid,input wire r_ready,output reg [3:0] r_op,r_status,
 output reg [31:0] r_feed,r_blocked_feed,output reg [63:0] r_time,r_sequence,
 output reg [DATA_W-1:0] r_data,output reg [TAG_W-1:0] r_tag,
 output reg r_head,r_closed,r_has_previous,r_has_watermark,
 output reg [63:0] r_previous_time,r_previous_sequence,r_watermark,
 output wire [31:0] r_heads,output wire r_end,output reg faulted,output wire busy
);
 localparam integer F=(FEEDS>=1 && FEEDS<=8)?FEEDS:1;
 localparam integer AW=(F>1)?$clog2(F):1,CW=$clog2(F+1);
 localparam [3:0] OK=0,BAD_OP=1,BAD_FEED=2,CLOSED=3,HEAD_FULL=4,
  STALE_SEQUENCE=5,TIME_BACKWARDS=6,BELOW_WATERMARK=7,
  WATERMARK_BACKWARDS=8,EMPTY=9,WAIT_FEED=10,INVALID_STATE=11,BACKEND_FAULT=12;
 localparam [4:0] IDLE=0,MREAD=1,MRESULT=2,EVALUATE=3,MWRITE=4,MWRESULT=5,
  PWRITE=6,PWRESULT=7,BSEND=8,BRESULT=9,SCAN=10,SWREAD=11,SWRESULT=12,
  PREAD=13,PRRESULT=14,RESPONSE=15;
 reg [4:0] state;
 reg [F-1:0] heads,closed,previous_valid,watermark_valid;
 reg [CW-1:0] head_count;
 reg [31:0] feed,candidate_feed;
 reg [63:0] event_time,event_sequence,candidate_time,candidate_sequence;
 reg [DATA_W-1:0] event_data,popped_data;
 reg [191:0] metadata,metadata_write;
 reg [AW-1:0] scan;
 reg [2:0] backend_op;
 reg [63:0] backend_cutoff;
 wire bs_ready,bm_valid,bm_found,bm_replaced,bm_due;
 wire [2:0] bm_op,bm_status;
 wire [31:0] bm_id;
 wire [63:0] bm_time,bm_data;
 wire [0:0] bm_tag;
 wire [CW-1:0] bm_live,bm_free;
 wire mr_ready,mr_valid,mr_error,pr_ready,pr_valid,pr_error;
 wire [191:0] mr_data;
 wire [DATA_W-1:0] pr_data;
 wire meta_request=state==MREAD || state==MWRITE || state==SWREAD;
 wire payload_request=state==PWRITE || state==PREAD;
 wire [AW-1:0] meta_address=(state==SWREAD)?scan:feed[AW-1:0];
 wire [AW-1:0] payload_address=(state==PREAD)?candidate_feed[AW-1:0]:feed[AW-1:0];
 generate if(FEEDS<1 || FEEDS>8 || DATA_W<8 || DATA_W>512 || DATA_W%8!=0 || TAG_W<1 || TAG_W>32)begin:invalid
  watermark_event_merge_invalid_parameters__see_README rejected();
 end endgenerate
 assign c_ready=!rst && state==IDLE && bs_ready;
 assign r_valid=!rst && state==RESPONSE;
 assign r_heads={{(32-CW){1'b0}},head_count};
 assign r_end=(&closed) && head_count==0;
 assign busy=!rst && (state!=IDLE || !bs_ready);
 ram_deadline_scheduler #(.SLOTS(F),.ID_W(32),.TIME_W(64),.DATA_W(64),.TAG_W(1)) calendar(
  .clk(clk),.rst(rst),.s_valid(state==BSEND),.s_ready(bs_ready),.s_op(backend_op),
  .s_id(feed),.s_deadline(event_time),.s_cutoff(backend_cutoff),.s_data(event_sequence),.s_tag(1'b0),
  .m_valid(bm_valid),.m_ready(state==BRESULT),.m_op(bm_op),.m_status(bm_status),
  .m_found(bm_found),.m_replaced(bm_replaced),.m_due(bm_due),.m_id(bm_id),
  .m_deadline(bm_time),.m_data(bm_data),.m_tag(bm_tag),.m_live(bm_live),.m_free(bm_free));
 cip_sync_sp_ram #(.DATA_WIDTH(192),.ADDR_WIDTH(AW),.DEPTH(F)) feed_metadata(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(meta_request),.req_ready(mr_ready),
  .req_write(state==MWRITE),.req_addr(meta_address),.req_wdata(metadata_write),.req_wstrb(24'hffffff),
  .rsp_valid(mr_valid),.rsp_ready(state==MRESULT || state==MWRESULT || state==SWRESULT),
  .rsp_rdata(mr_data),.rsp_error(mr_error));
 cip_sync_sp_ram #(.DATA_WIDTH(DATA_W),.ADDR_WIDTH(AW),.DEPTH(F)) head_payload(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(payload_request),.req_ready(pr_ready),
  .req_write(state==PWRITE),.req_addr(payload_address),.req_wdata(event_data),.req_wstrb({(DATA_W/8){1'b1}}),
  .rsp_valid(pr_valid),.rsp_ready(state==PWRESULT || state==PRRESULT),.rsp_rdata(pr_data),.rsp_error(pr_error));
 task automatic backend_failure;
  begin faulted<=1;r_status<=BACKEND_FAULT;r_data<=0;r_time<=0;r_sequence<=0;state<=RESPONSE;end
 endtask
 task automatic advance_scan;
  begin if(scan==F-1)state<=PREAD;else begin scan<=scan+1'b1;state<=SCAN;end end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;heads<=0;closed<=0;previous_valid<=0;watermark_valid<=0;head_count<=0;faulted<=0;
   feed<=0;candidate_feed<=0;event_time<=0;event_sequence<=0;candidate_time<=0;candidate_sequence<=0;
   scan<=0;backend_op<=0;backend_cutoff<=0;
   r_op<=0;r_status<=0;r_feed<=0;r_blocked_feed<=0;r_tag<=0;r_time<=0;r_sequence<=0;
   r_head<=0;r_closed<=0;r_has_previous<=0;r_has_watermark<=0;
   r_previous_time<=0;r_previous_sequence<=0;r_watermark<=0;
  end else case(state)
   IDLE:if(c_valid && c_ready)begin
    r_op<=c_op;r_tag<=c_tag;r_status<=OK;r_feed<=0;r_blocked_feed<=0;r_time<=0;r_sequence<=0;r_data<=0;
    r_head<=0;r_closed<=0;r_has_previous<=0;r_has_watermark<=0;r_previous_time<=0;r_previous_sequence<=0;r_watermark<=0;
    feed<=c_feed;event_time<=c_time;event_sequence<=c_sequence;event_data<=c_data;
    if(c_op>6)begin r_status<=BAD_OP;state<=RESPONSE;end
    else if(c_op==5)begin backend_op<=4;backend_cutoff<=0;state<=BSEND;end
    else if(c_op==6)begin faulted<=1;state<=RESPONSE;end
    else if(faulted)begin r_status<=INVALID_STATE;state<=RESPONSE;end
    else if(c_op==3)begin backend_op<=2;backend_cutoff<=64'hffffffffffffffff;state<=BSEND;end
    else if(c_feed>=F)begin r_status<=BAD_FEED;state<=RESPONSE;end
    else begin
     r_feed<=c_feed;r_head<=heads[c_feed];r_closed<=closed[c_feed];
     if(c_op==2)begin closed[c_feed]<=1;r_closed<=1;state<=RESPONSE;end
     else if(c_op!=4 && closed[c_feed])begin r_status<=CLOSED;state<=RESPONSE;end
     else if(c_op==0 && heads[c_feed])begin r_status<=HEAD_FULL;state<=RESPONSE;end
     else state<=MREAD;
    end
   end
   MREAD:if(mr_ready)state<=MRESULT;
   MRESULT:if(mr_valid)begin
    if(mr_error)backend_failure();else begin metadata<=mr_data;state<=EVALUATE;end
   end
   EVALUATE:begin
    if(r_op==4)begin
     r_has_previous<=previous_valid[feed];r_has_watermark<=watermark_valid[feed];
     r_previous_time<=previous_valid[feed]?metadata[191:128]:64'd0;
     r_previous_sequence<=previous_valid[feed]?metadata[127:64]:64'd0;
     r_watermark<=watermark_valid[feed]?metadata[63:0]:64'd0;state<=RESPONSE;
    end else if(r_op==0)begin
     if(previous_valid[feed] && event_sequence<=metadata[127:64])begin r_status<=STALE_SEQUENCE;state<=RESPONSE;end
     else if(previous_valid[feed] && event_time<metadata[191:128])begin r_status<=TIME_BACKWARDS;state<=RESPONSE;end
     else if(watermark_valid[feed] && event_time<metadata[63:0])begin r_status<=BELOW_WATERMARK;state<=RESPONSE;end
     else begin metadata_write<={event_time,event_sequence,watermark_valid[feed]?metadata[63:0]:64'd0};state<=MWRITE;end
    end else if(watermark_valid[feed] && event_time<metadata[63:0])begin r_status<=WATERMARK_BACKWARDS;state<=RESPONSE;end
    else begin
     metadata_write<={previous_valid[feed]?metadata[191:64]:128'd0,event_time};state<=MWRITE;
    end
   end
   MWRITE:if(mr_ready)state<=MWRESULT;
   MWRESULT:if(mr_valid)begin
    if(mr_error)backend_failure();
    else if(r_op==0)begin previous_valid[feed]<=1;state<=PWRITE;end
    else begin watermark_valid[feed]<=1;state<=RESPONSE;end
   end
   PWRITE:if(pr_ready)state<=PWRESULT;
   PWRESULT:if(pr_valid)begin
    if(pr_error)backend_failure();else begin backend_op<=0;backend_cutoff<=0;state<=BSEND;end
   end
   BSEND:if(bs_ready)state<=BRESULT;
   BRESULT:if(bm_valid)begin
    if(bm_op!=backend_op || bm_tag!=0 || bm_free+bm_live!=F)backend_failure();
    else if(backend_op==4)begin
     if(bm_status!=0 || bm_found || bm_live!=0)backend_failure();
     else begin heads<=0;closed<=0;previous_valid<=0;watermark_valid<=0;head_count<=0;faulted<=0;state<=RESPONSE;end
    end else if(backend_op==0)begin
     if(bm_status!=0 || !bm_found || bm_replaced || bm_id!=feed || bm_time!=event_time || bm_data!=event_sequence || bm_live!=head_count+1'b1)backend_failure();
     else begin heads[feed]<=1;head_count<=head_count+1'b1;r_head<=1;state<=RESPONSE;end
    end else if(backend_op==2)begin
     if(bm_status==1 && !bm_found && bm_live==0 && head_count==0)begin r_status<=EMPTY;state<=RESPONSE;end
     else if(bm_status!=0 || !bm_found || bm_id>=F || bm_live!=head_count)backend_failure();
     else if(!heads[bm_id])backend_failure();
     else begin candidate_feed<=bm_id;candidate_time<=bm_time;candidate_sequence<=bm_data;scan<=0;state<=SCAN;end
    end else if(bm_status!=0 || !bm_found || !bm_due || bm_id!=candidate_feed || bm_time!=candidate_time || bm_data!=candidate_sequence || bm_live!=head_count-1'b1)backend_failure();
    else begin
     heads[candidate_feed]<=0;head_count<=head_count-1'b1;r_feed<=candidate_feed;r_time<=candidate_time;
     r_sequence<=candidate_sequence;r_data<=popped_data;r_closed<=closed[candidate_feed];state<=RESPONSE;
    end
   end
   SCAN:begin
    if(heads[scan] || closed[scan])advance_scan();
    else if(!watermark_valid[scan])begin r_status<=WAIT_FEED;r_blocked_feed<=scan;r_time<=candidate_time;state<=RESPONSE;end
    else state<=SWREAD;
   end
   SWREAD:if(mr_ready)state<=SWRESULT;
   SWRESULT:if(mr_valid)begin
    if(mr_error)backend_failure();
    else if(mr_data[63:0]<=candidate_time)begin r_status<=WAIT_FEED;r_blocked_feed<=scan;r_time<=candidate_time;state<=RESPONSE;end
    else advance_scan();
   end
   PREAD:if(pr_ready)state<=PRRESULT;
   PRRESULT:if(pr_valid)begin
    if(pr_error)backend_failure();else begin popped_data<=pr_data;backend_op<=3;backend_cutoff<=candidate_time;state<=BSEND;end
   end
   RESPONSE:if(r_ready)state<=IDLE;
   default:backend_failure();
  endcase
 end
endmodule
