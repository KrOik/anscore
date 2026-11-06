// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Store-forward payload ownership around the unchanged descriptor shaper.
module payload_multiflow_token_shaper #(
 parameter integer FLOWS=4,DATA_W=32,MAX_BEATS=512,TOKEN_W=16,TAG_W=8,QUANTUM=16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_flow,input wire c_enable,
 input wire [TOKEN_W-1:0] c_capacity,c_rate,c_initial,
 input wire [TAG_W-1:0] c_tag,
 output wire r_valid,input wire r_ready,
 output wire [1:0] r_status,output wire [31:0] r_flow,
 output wire [TAG_W-1:0] r_tag,
 input wire s_valid,output reg s_ready,input wire [31:0] s_flow,
 input wire [DATA_W-1:0] s_data,input wire [DATA_W/8-1:0] s_keep,
 input wire s_last,input wire [TAG_W-1:0] s_tag,
 output wire a_valid,input wire a_ready,output reg [2:0] a_status,
 output reg [31:0] a_flow,a_bytes,a_beats,output reg [TAG_W-1:0] a_tag,
 output wire m_valid,input wire m_ready,output wire [31:0] m_flow,
 output wire [DATA_W-1:0] m_data,output wire [DATA_W/8-1:0] m_keep,
 output wire m_sop,m_last,output wire [TOKEN_W-1:0] m_length,
 output wire [TAG_W-1:0] m_tag,output reg faulted
);
 localparam integer KEEP_W=DATA_W/8;
 localparam integer MAX_BYTES=MAX_BEATS*KEEP_W;
 localparam integer AW=MAX_BEATS>1?$clog2(MAX_BEATS):1;
 localparam integer CW=$clog2(MAX_BEATS+2);
 localparam integer BW=$clog2(MAX_BYTES+2);
 localparam integer RW=8*((DATA_W+KEEP_W+7)/8);
 localparam integer FW=DATA_W+KEEP_W+1;
 localparam [2:0] FREE=0,COLLECT=1,COMPLETE=2,QUEUED=3,ACTIVE=4;
 localparam [1:0] I_IDLE=0,I_BODY=1,I_REPLY=2;
 localparam [2:0] STORED=0,BAD_FLOW=1,EMPTY=2,OVERSIZE=3,BAD_COST=4,DISABLED=5;
 generate if(FLOWS<1 || FLOWS>8 ||
  !(DATA_W==8 || DATA_W==16 || DATA_W==32 || DATA_W==64) ||
  MAX_BEATS<1 || MAX_BEATS>512 || TOKEN_W<1 || TOKEN_W>24 ||
  TAG_W<1 || TAG_W>16 || QUANTUM<1 || QUANTUM>1024 ||
  MAX_BYTES>((64'd1<<TOKEN_W)-1)) begin: bad_parameters
  payload_multiflow_token_shaper_invalid_parameters__see_README rejected();
 end endgenerate

 reg [2:0] state[0:FLOWS-1];
 reg [FLOWS-1:0] enabled;
 reg [TOKEN_W-1:0] capacity[0:FLOWS-1],packet_bytes[0:FLOWS-1];
 reg [CW-1:0] packet_beats[0:FLOWS-1];
 reg [TAG_W-1:0] packet_tag[0:FLOWS-1];
 reg saved_enable;
 reg [TOKEN_W-1:0] saved_capacity;
 reg [1:0] ingress_state;
 reg [31:0] ingress_flow;
 reg [TAG_W-1:0] ingress_tag;
 reg [2:0] ingress_drop;
 reg [CW-1:0] ingress_beats;
 reg [BW-1:0] ingress_bytes;

 wire sh_c_ready,sh_r_valid;
 wire [1:0] sh_r_status;
 wire [31:0] sh_r_flow;
 wire [TAG_W-1:0] sh_r_tag;
 reg config_allowed;
 always @* begin
  config_allowed=1'b1;
  if(c_flow<FLOWS)config_allowed=state[c_flow]==FREE;
 end
 wire sh_c_valid=c_valid && config_allowed && !faulted;
 assign c_ready=!rst && !faulted && config_allowed && sh_c_ready;
 wire c_fire=c_valid && c_ready;
 assign r_valid=sh_r_valid;
 assign r_status=sh_r_status;
 assign r_flow=sh_r_flow;
 assign r_tag=sh_r_tag;
 wire config_commit=sh_r_valid && r_ready && sh_r_status==0;

 wire [FLOWS-1:0] sh_s_valid,sh_s_ready;
 wire [FLOWS*TOKEN_W-1:0] sh_s_cost;
 wire [FLOWS*32-1:0] sh_s_data;
 wire [FLOWS*TAG_W-1:0] sh_s_tag;
 wire sh_m_valid,sh_m_ready,sh_m_status;
 wire [31:0] sh_m_flow,sh_m_data;
 wire [TOKEN_W-1:0] sh_m_cost;
 wire [TAG_W-1:0] sh_m_tag;
 multiflow_token_shaper #(.FLOWS(FLOWS),.TOKEN_W(TOKEN_W),.DATA_W(32),
  .TAG_W(TAG_W),.QUANTUM(QUANTUM)) u_shaper(
  .clk(clk),.rst(rst),.c_valid(sh_c_valid),.c_ready(sh_c_ready),
  .c_flow(c_flow),.c_enable(c_enable),.c_capacity(c_capacity),.c_rate(c_rate),
  .c_initial(c_initial),.c_tag(c_tag),.r_valid(sh_r_valid),.r_ready(r_ready),
  .r_status(sh_r_status),.r_flow(sh_r_flow),.r_tag(sh_r_tag),
  .s_valid(sh_s_valid),.s_ready(sh_s_ready),.s_cost(sh_s_cost),
  .s_data(sh_s_data),.s_tag(sh_s_tag),.m_valid(sh_m_valid),.m_ready(sh_m_ready),
  .m_flow(sh_m_flow),.m_status(sh_m_status),.m_cost(sh_m_cost),
  .m_data(sh_m_data),.m_tag(sh_m_tag));

 reg tx_busy,tx_started;
 reg [31:0] tx_flow;
 reg [CW-1:0] tx_beats,tx_issued;
 reg [TOKEN_W-1:0] tx_length;
 reg [TAG_W-1:0] tx_tag;
 reg read_last;
 wire [FLOWS-1:0] ram_req_ready,ram_rsp_valid,ram_rsp_error;
 wire [FLOWS*RW-1:0] ram_rsp_data;
 reg ingress_write;
 reg [31:0] write_flow;
 reg [AW-1:0] write_addr;
 reg [31:0] working_flow;
 reg [TAG_W-1:0] working_tag;
 reg [2:0] working_drop;
 reg [CW-1:0] working_beats,next_beats;
 reg [BW-1:0] working_bytes,next_bytes;
 reg [2:0] final_status;
 reg target_available;
 reg [31:0] byte_sum;
 integer lane;
 // Full IDs are checked before every selected array access. Subsequent beats
 // cannot redirect the first accepted beat's flow/tag ownership.
 always @* begin
  working_flow=ingress_state==I_IDLE?s_flow:ingress_flow;
  working_tag=ingress_state==I_IDLE?s_tag:ingress_tag;
  working_drop=ingress_state==I_IDLE?STORED:ingress_drop;
  working_beats=ingress_state==I_IDLE?0:ingress_beats;
  working_bytes=ingress_state==I_IDLE?0:ingress_bytes;
  if(ingress_state==I_IDLE)begin
   if(s_flow>=FLOWS)working_drop=BAD_FLOW;
   else if(!enabled[s_flow])working_drop=DISABLED;
  end
  next_beats=working_beats;
  if(working_beats<MAX_BEATS+1)next_beats=working_beats+1'b1;
  byte_sum={{(32-BW){1'b0}},working_bytes};
  for(lane=0;lane<KEEP_W;lane=lane+1)byte_sum=byte_sum+s_keep[lane];
  next_bytes=byte_sum>MAX_BYTES+1?MAX_BYTES+1:byte_sum[BW-1:0];
  final_status=working_drop;
  if(final_status==STORED)begin
   if(next_beats>MAX_BEATS)final_status=OVERSIZE;
   else if(next_bytes==0)final_status=EMPTY;
   else if(working_flow<FLOWS)begin
    if(next_bytes>capacity[working_flow])final_status=BAD_COST;
   end
  end
  target_available=ingress_state==I_BODY;
  if(ingress_state==I_IDLE)begin
   if(working_flow>=FLOWS)target_available=1;
   else target_available=state[working_flow]==FREE;
  end
  s_ready=0;ingress_write=0;write_flow=working_flow;write_addr=working_beats[AW-1:0];
  if(!rst && !faulted && ingress_state!=I_REPLY)begin
   if(target_available)begin
    s_ready=1;
    if(ingress_state==I_IDLE && working_flow<FLOWS &&
      ((c_fire && c_flow==working_flow) ||
       (sh_r_valid && sh_r_flow==working_flow)))s_ready=0;
    if(working_drop==STORED && working_beats<MAX_BEATS && working_flow<FLOWS)begin
     s_ready=s_ready && ram_req_ready[working_flow];
     ingress_write=s_valid && s_ready;
    end
   end
  end
 end
 wire s_fire=s_valid && s_ready;
 assign a_valid=!rst && ingress_state==I_REPLY;

 wire fifo_in_ready,fifo_out_valid,fifo_out_ready;
 wire [FW-1:0] fifo_out_data;
 wire fifo_in_valid=tx_busy && ram_rsp_valid[tx_flow];
 wire [RW-1:0] selected_read=ram_rsp_data[tx_flow*RW+:RW];
 wire [FW-1:0] fifo_in_data={read_last,selected_read[DATA_W+KEEP_W-1:0]};
 wire [1:0] unused_fifo_level;
 wire unused_fifo_full,unused_fifo_empty;
 cip_sync_fifo #(.DATA_WIDTH(FW),.DEPTH(2)) u_output_fifo(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.in_valid(fifo_in_valid),
  .in_ready(fifo_in_ready),.in_data(fifo_in_data),.out_valid(fifo_out_valid),
  .out_ready(fifo_out_ready),.out_data(fifo_out_data),.level(unused_fifo_level),
  .full(unused_fifo_full),.empty(unused_fifo_empty));
 assign m_valid=!rst && tx_busy && fifo_out_valid &&
  (tx_started || (sh_m_valid && !sh_m_status && sh_m_flow==tx_flow));
 assign m_data=fifo_out_data[DATA_W-1:0];
 assign m_keep=fifo_out_data[DATA_W+:KEEP_W];
 assign m_last=fifo_out_data[FW-1];
 assign m_sop=!tx_started;
 assign m_flow=tx_flow;
 assign m_length=tx_length;
 assign m_tag=tx_tag;
 wire m_fire=m_valid && m_ready;
 assign fifo_out_ready=m_fire;
 // The only descriptor retirement event is the actual public first-beat
 // handshake. Neither selection, RAM read, FIFO push, LAST nor admission ACK
 // can debit the unchanged token engine. No fault flag can separate these.
 assign sh_m_ready=m_fire && m_sop;
 wire issue_read=!rst && !faulted && tx_busy && tx_issued<tx_beats;
 wire read_fire=issue_read && ram_req_ready[tx_flow];

 genvar f;
 generate for(f=0;f<FLOWS;f=f+1)begin: banks
  assign sh_s_valid[f]=!faulted && state[f]==COMPLETE;
  assign sh_s_cost[f*TOKEN_W+:TOKEN_W]=packet_bytes[f];
  assign sh_s_data[f*32+:32]={{(32-CW){1'b0}},packet_beats[f]};
  assign sh_s_tag[f*TAG_W+:TAG_W]=packet_tag[f];
  wire writing=ingress_write && write_flow==f;
  wire reading=issue_read && tx_flow==f;
  // COLLECT and ACTIVE cannot own the same flow. Independent banks permit
  // one ingress write and one egress read for different flows on each edge.
  wire [AW-1:0] address=writing?write_addr:tx_issued[AW-1:0];
  wire [RW-1:0] payload={{(RW-DATA_W-KEEP_W){1'b0}},s_keep,s_data};
  wire rsp_ready=(tx_busy && tx_flow==f)?fifo_in_ready:1'b1;
  cip_sync_sp_ram #(.DATA_WIDTH(RW),.ADDR_WIDTH(AW),.DEPTH(MAX_BEATS)) u_ram(
   .clk(clk),.rst_n(!rst),.clk_en(1'b1),
   .req_valid(writing || reading),.req_ready(ram_req_ready[f]),
   .req_write(writing),.req_addr(address),.req_wdata(payload),
   .req_wstrb({(RW/8){1'b1}}),.rsp_valid(ram_rsp_valid[f]),.rsp_ready(rsp_ready),
   .rsp_rdata(ram_rsp_data[f*RW+:RW]),.rsp_error(ram_rsp_error[f]));
 end endgenerate

 integer k;
 always @(posedge clk)begin
  if(rst)begin
   enabled<=0;saved_enable<=0;saved_capacity<=0;
   ingress_state<=I_IDLE;ingress_flow<=0;ingress_tag<=0;ingress_drop<=0;
   ingress_beats<=0;ingress_bytes<=0;
   a_status<=0;a_flow<=0;a_bytes<=0;a_beats<=0;a_tag<=0;
   tx_busy<=0;tx_started<=0;tx_flow<=0;tx_beats<=0;tx_issued<=0;
   tx_length<=0;tx_tag<=0;read_last<=0;faulted<=0;
   for(k=0;k<FLOWS;k=k+1)begin
    state[k]<=FREE;capacity[k]<=0;packet_bytes[k]<=0;packet_beats[k]<=0;packet_tag[k]<=0;
   end
  end else begin
   if(c_fire)begin saved_enable<=c_enable;saved_capacity<=c_capacity;end
   if(config_commit)begin
    enabled[sh_r_flow]<=saved_enable;capacity[sh_r_flow]<=saved_capacity;
   end
   for(k=0;k<FLOWS;k=k+1)begin
    if(sh_s_valid[k] && sh_s_ready[k])state[k]<=QUEUED;
    if(ram_rsp_valid[k] && ram_rsp_error[k])faulted<=1;
   end
   if(ingress_state==I_REPLY && a_ready)ingress_state<=I_IDLE;
   if(s_fire)begin
    ingress_flow<=working_flow;ingress_tag<=working_tag;
    ingress_beats<=next_beats;ingress_bytes<=next_bytes;
    ingress_drop<=working_drop;
    if(working_drop==STORED && next_beats>MAX_BEATS)ingress_drop<=OVERSIZE;
    if(ingress_state==I_IDLE && working_flow<FLOWS)state[working_flow]<=COLLECT;
    if(s_last)begin
     ingress_state<=I_REPLY;
     a_status<=final_status;a_flow<=working_flow;a_tag<=working_tag;
     a_bytes<={{(32-BW){1'b0}},next_bytes};a_beats<={{(32-CW){1'b0}},next_beats};
     if(working_flow<FLOWS)begin
      if(final_status==STORED)begin
       state[working_flow]<=COMPLETE;
       packet_bytes[working_flow]<=next_bytes;
       packet_beats[working_flow]<=next_beats;
       packet_tag[working_flow]<=working_tag;
      end else state[working_flow]<=FREE;
     end
    end else ingress_state<=I_BODY;
   end
   if(!tx_busy && !faulted && sh_m_valid)begin
    if(sh_m_status || sh_m_flow>=FLOWS)faulted<=1;
    else if(state[sh_m_flow]!=QUEUED || sh_m_cost!=packet_bytes[sh_m_flow] ||
      sh_m_data!={{(32-CW){1'b0}},packet_beats[sh_m_flow]} ||
      sh_m_tag!=packet_tag[sh_m_flow])faulted<=1;
    else begin
     tx_busy<=1;tx_started<=0;tx_flow<=sh_m_flow;tx_beats<=packet_beats[sh_m_flow];
     tx_length<=sh_m_cost;tx_tag<=sh_m_tag;tx_issued<=0;state[sh_m_flow]<=ACTIVE;
    end
   end
   if(read_fire)begin
    read_last<=tx_issued==tx_beats-1'b1;
    tx_issued<=tx_issued+1'b1;
   end
   if(m_fire)begin
    tx_started<=1;
    if(m_last)begin
     state[tx_flow]<=FREE;tx_busy<=0;tx_started<=0;
    end
   end
  end
 end
endmodule
`default_nettype wire
