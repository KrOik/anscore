// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module range_lock_manager #(
 parameter integer ADDR_W=32,SLOTS=8,GEN_W=8,OWNER_W=8,TAG_W=8
)(
 input wire clk,rst,
 input wire s_valid,output wire s_ready,
 input wire [1:0] s_op,
 input wire [ADDR_W-1:0] s_base,input wire [ADDR_W:0] s_length,
 input wire s_exclusive,input wire [OWNER_W-1:0] s_owner,
 input wire [31:0] s_slot,input wire [GEN_W-1:0] s_generation,
 input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg [1:0] m_op,output reg [2:0] m_status,
 output reg [TAG_W-1:0] m_tag,
 output reg [31:0] m_slot,output reg [GEN_W-1:0] m_generation,
 output reg [OWNER_W-1:0] m_owner,
 output reg [ADDR_W-1:0] m_base,output reg [ADDR_W:0] m_length,
 output reg m_exclusive,output reg [SLOTS-1:0] m_conflicts,
 output reg [$clog2(SLOTS+1)-1:0] m_live,m_free,m_retired
);
 localparam integer IW=(SLOTS>1)?$clog2(SLOTS):1,CW=$clog2(SLOTS+1);
 localparam integer EW=2*ADDR_W+GEN_W+OWNER_W+2;
 localparam [2:0] INIT=0,IDLE=1,TARGET_READ=2,TARGET_CHECK=3,
  SCAN_READ=4,SCAN_CHECK=5,DECIDE=6,HOLD=7;
 localparam [2:0] OK=0,BAD_RANGE=1,CONFLICT=2,FULL=3,BAD_HANDLE=4;
 generate if(ADDR_W<8 || ADDR_W>64 || SLOTS<1 || SLOTS>32 ||
  GEN_W<1 || GEN_W>32 || OWNER_W<1 || OWNER_W>32 || TAG_W<1 || TAG_W>32)
  begin: invalid_parameter
   range_lock_manager_invalid_parameter__see_README rejected();
  end
 endgenerate
 reg [2:0] state;
 // {live,exclusive,owner,generation,base,inclusive_last}; never read before INIT.
 reg [EW-1:0] entries[0:SLOTS-1];
 reg [EW-1:0] read_entry,write_entry;
 reg [IW-1:0] cursor,target,free_slot,write_slot;
 reg [CW-1:0] live_count,free_count,retired_count;
 reg [1:0] op;
 reg [ADDR_W-1:0] base,last_byte;
 reg [ADDR_W:0] length;
 reg exclusive,bad_range,free_found,write_pending;
 reg [OWNER_W-1:0] owner;
 reg [GEN_W-1:0] generation,free_generation;
 reg [SLOTS-1:0] conflicts;
 wire q_live=read_entry[EW-1],q_exclusive=read_entry[EW-2];
 wire [OWNER_W-1:0] q_owner=read_entry[2*ADDR_W+GEN_W+:OWNER_W];
 wire [GEN_W-1:0] q_generation=read_entry[2*ADDR_W+:GEN_W];
 wire [ADDR_W-1:0] q_base=read_entry[2*ADDR_W-1:ADDR_W];
 wire [ADDR_W-1:0] q_last=read_entry[ADDR_W-1:0];
 wire [ADDR_W+1:0] input_last={2'b0,s_base}+{1'b0,s_length}-1'b1;
 wire input_bad_range=(s_length==0) || (input_last[ADDR_W+1:ADDR_W]!=0);
 wire [GEN_W-1:0] next_generation=free_generation+1'b1;
 wire self=(op==2 && cursor==target);
 wire hit=q_live && !self && (exclusive || q_exclusive) && base<=q_last && q_base<=last_byte;
 wire read_enable=!rst && (state==TARGET_READ || state==SCAN_READ);
 wire [IW-1:0] read_address=(state==TARGET_READ)?target:cursor;
 wire commit=!rst && state==HOLD && m_ready && write_pending;
 // Serial initialization, disjoint scan reads and response-handshake writes.
 always @(posedge clk)begin
  if(!rst && state==INIT)entries[cursor]<=0;
  else if(commit)entries[write_slot]<=write_entry;
  if(read_enable)read_entry<=entries[read_address];
 end
 assign s_ready=!rst && state==IDLE;
 assign m_valid=!rst && state==HOLD;
 always @(posedge clk)begin
  if(rst)begin
   state<=INIT;cursor<=0;live_count<=0;free_count<=SLOTS;retired_count<=0;
   op<=0;base<=0;last_byte<=0;length<=0;exclusive<=0;bad_range<=0;
   owner<=0;generation<=0;free_found<=0;free_generation<=0;conflicts<=0;
   target<=0;free_slot<=0;write_slot<=0;write_entry<=0;write_pending<=0;
   m_op<=0;m_status<=0;m_tag<=0;m_slot<=0;m_generation<=0;m_owner<=0;
   m_base<=0;m_length<=0;m_exclusive<=0;m_conflicts<=0;m_live<=0;m_free<=0;m_retired<=0;
  end else case(state)
   INIT:if(cursor==SLOTS-1)state<=IDLE;else cursor<=cursor+1'b1;
   IDLE:if(s_valid)begin
    op<=s_op;base<=s_base;last_byte<=input_last[ADDR_W-1:0];length<=s_length;
    exclusive<=s_exclusive;owner<=s_owner;generation<=s_generation;bad_range<=input_bad_range;
    target<=s_slot;cursor<=0;free_found<=0;free_generation<=0;conflicts<=0;write_pending<=0;
    m_op<=s_op;m_status<=OK;m_tag<=s_tag;m_slot<=0;m_generation<=0;m_owner<=0;
    m_base<=0;m_length<=0;m_exclusive<=0;m_conflicts<=0;
    m_live<=live_count;m_free<=free_count;m_retired<=retired_count;
    if(s_op==3)state<=HOLD;
    else if(s_op==0)begin
     if(input_bad_range)begin m_status<=BAD_RANGE;state<=HOLD;end
     else state<=SCAN_READ;
    end else if(s_slot>=SLOTS || s_generation==0)begin m_status<=BAD_HANDLE;state<=HOLD;end
    else state<=TARGET_READ;
   end
   TARGET_READ:state<=TARGET_CHECK;
   TARGET_CHECK:begin
    if(!q_live || q_owner!=owner || q_generation!=generation)begin m_status<=BAD_HANDLE;state<=HOLD;end
    else if(op==1)begin
     write_slot<=target;write_entry<={1'b0,read_entry[EW-2:0]};write_pending<=1;
     m_slot<=target;m_generation<=generation;m_owner<=q_owner;m_base<=q_base;
     m_length<={1'b0,q_last}-{1'b0,q_base}+1'b1;m_exclusive<=q_exclusive;
     m_live<=live_count-1'b1;
     if(&q_generation)m_retired<=retired_count+1'b1;else m_free<=free_count+1'b1;
     state<=HOLD;
    end else if(bad_range)begin m_status<=BAD_RANGE;state<=HOLD;end
    else begin cursor<=0;state<=SCAN_READ;end
   end
   SCAN_READ:state<=SCAN_CHECK;
   SCAN_CHECK:begin
    if(hit)conflicts[cursor]<=1;
    if(!q_live && !(&q_generation) && !free_found)begin
     free_found<=1;free_slot<=cursor;free_generation<=q_generation;
    end
    if(cursor==SLOTS-1)state<=DECIDE;
    else begin cursor<=cursor+1'b1;state<=SCAN_READ;end
   end
   DECIDE:begin
    if(conflicts!=0)begin m_status<=CONFLICT;m_conflicts<=conflicts;end
    else if(op==0 && !free_found)m_status<=FULL;
    else begin
     write_pending<=1;write_slot<=(op==0)?free_slot:target;
     write_entry<={1'b1,exclusive,owner,(op==0)?next_generation:generation,base,last_byte};
     m_slot<=(op==0)?free_slot:target;m_generation<=(op==0)?next_generation:generation;
     m_owner<=owner;m_base<=base;m_length<=length;m_exclusive<=exclusive;
     if(op==0)begin m_live<=live_count+1'b1;m_free<=free_count-1'b1;end
    end
    state<=HOLD;
   end
   HOLD:if(m_ready)begin
    if(write_pending)begin live_count<=m_live;free_count<=m_free;retired_count<=m_retired;end
    state<=IDLE;
   end
   default:begin state<=INIT;cursor<=0;live_count<=0;free_count<=SLOTS;retired_count<=0;end
  endcase
 end
endmodule
`default_nettype wire
