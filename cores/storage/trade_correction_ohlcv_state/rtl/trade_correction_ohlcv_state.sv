// SPDX-License-Identifier: Apache-2.0
// Bounded retained-match history; broken IDs remain allocated until CLEAR.
`default_nettype none
module trade_correction_ohlcv_state #(
 parameter integer ENTRIES=32,TAG_W=8
)(
 input wire clk,rst,input wire c_valid,output wire c_ready,
 input wire [3:0] c_op,input wire [31:0] c_symbol,
 input wire [63:0] c_match,c_sequence,input wire [31:0] c_price,c_quantity,
 input wire [TAG_W-1:0] c_tag,
 output wire r_valid,input wire r_ready,output reg [3:0] r_op,r_status,
 output reg [31:0] r_entries,r_symbol,output reg r_trade_valid,r_active,
 output reg [63:0] r_match,r_sequence,output reg [31:0] r_price,r_quantity,
 output reg r_stats_valid,output reg [31:0] r_count,
 output reg [37:0] r_volume,output reg [69:0] r_notional,
 output reg [31:0] r_open,r_high,r_low,r_close,
 output reg [TAG_W-1:0] r_tag,output reg faulted,output wire busy
);
 localparam integer IW=ENTRIES<2?1:$clog2(ENTRIES);
 localparam [3:0] ADD=0,BUST=1,CORRECT=2,GET=3,QUERY=4,CLEAR=5,INVALIDATE=6;
 localparam [3:0] OK=0,BAD_QUANTITY=1,DUPLICATE=2,FULL=3,NOT_FOUND=4,
  BROKEN=5,INVALID_STATE=6,BAD_OP=7,BACKEND_FAULT=8;
 localparam [3:0] IDLE=0,FIND_SEND=1,FIND_WAIT=2,FIND_END=3,
  AGG_SEND=4,AGG_WAIT=5,ACCUM=6,AGG_END=7,WRITE_SEND=8,WRITE_WAIT=9,RESPONSE=10;
 generate if(ENTRIES<1||ENTRIES>64||TAG_W<1||TAG_W>32)begin: invalid
  trade_correction_ohlcv_state_invalid_parameters__see_README rejected();
 end endgenerate
 reg [3:0] state,op;
 reg [ENTRIES-1:0] allocated,active;
 reg [6:0] retained;
 reg [IW-1:0] cursor,target,free_slot;
 reg found,free_seen;
 reg [31:0] symbol,price,quantity,target_symbol;
 reg [63:0] match_id,seq_value;
 reg [223:0] found_row,candidate;
 reg work_include;
 reg [31:0] work_price,work_quantity;
 reg [127:0] work_key,first_key,last_key;
 reg [63:0] product;
 reg [6:0] count;
 reg [37:0] volume;
 reg [69:0] notional;
 reg [31:0] open_price,high_price,low_price,close_price;
 wire ram_ready,ram_valid,ram_error;
 wire [223:0] row;
 wire request=state==FIND_SEND||state==AGG_SEND||state==WRITE_SEND;
 wire [IW-1:0] address=state==WRITE_SEND?target:cursor;
 wire [223:0] selected=(op==ADD||op==CORRECT)&&cursor==target?candidate:row;
 wire include_row=selected[223:192]==target_symbol &&
  (((op==ADD||op==CORRECT)&&cursor==target)||(active[cursor]&&!(op==BUST&&cursor==target)));
 wire [31:0] selected_price=selected[63:32],selected_quantity=selected[31:0];
 cip_sync_sp_ram #(.DATA_WIDTH(224),.ADDR_WIDTH(IW),.DEPTH(ENTRIES)) records(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(!rst&&request),.req_ready(ram_ready),
  .req_write(state==WRITE_SEND),.req_addr(address),.req_wdata(candidate),.req_wstrb(28'hfffffff),
  .rsp_valid(ram_valid),.rsp_ready(state==FIND_WAIT||state==AGG_WAIT||state==WRITE_WAIT),
  .rsp_rdata(row),.rsp_error(ram_error));
 assign c_ready=!rst&&state==IDLE;
 assign r_valid=!rst&&state==RESPONSE;
 assign busy=!rst&&state!=IDLE;
 task fail(input [3:0] status,input poison);
  begin r_status<=status;if(poison)faulted<=1;state<=RESPONSE;end
 endtask
 task clear_summary;
  begin count<=0;volume<=0;notional<=0;open_price<=0;high_price<=0;low_price<=0;close_price<=0;first_key<=0;last_key<=0;end
 endtask
 task publish_trade(input [223:0] data,input enabled);
  begin r_trade_valid<=1;r_active<=enabled;r_symbol<=data[223:192];r_match<=data[191:128];
   r_sequence<=data[127:64];r_price<=data[63:32];r_quantity<=data[31:0];end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;op<=0;allocated<=0;active<=0;retained<=0;faulted<=0;
   cursor<=0;target<=0;free_slot<=0;found<=0;free_seen<=0;symbol<=0;price<=0;quantity<=0;
   target_symbol<=0;match_id<=0;seq_value<=0;found_row<=0;candidate<=0;
   work_include<=0;work_price<=0;work_quantity<=0;work_key<=0;product<=0;clear_summary();
   r_op<=0;r_status<=0;r_entries<=0;r_symbol<=0;r_trade_valid<=0;r_active<=0;r_match<=0;r_sequence<=0;
   r_price<=0;r_quantity<=0;r_stats_valid<=0;r_count<=0;r_volume<=0;r_notional<=0;
   r_open<=0;r_high<=0;r_low<=0;r_close<=0;r_tag<=0;
  end else case(state)
   IDLE:if(c_valid)begin
    op<=c_op;symbol<=c_symbol;match_id<=c_match;seq_value<=c_sequence;price<=c_price;quantity<=c_quantity;
    r_op<=c_op;r_tag<=c_tag;r_status<=OK;r_entries<={25'd0,retained};
    r_symbol<=0;r_trade_valid<=0;r_active<=0;r_match<=0;r_sequence<=0;r_price<=0;r_quantity<=0;
    r_stats_valid<=0;r_count<=0;r_volume<=0;r_notional<=0;r_open<=0;r_high<=0;r_low<=0;r_close<=0;
    cursor<=0;found<=0;free_seen<=0;free_slot<=0;target<=0;found_row<=0;clear_summary();
    if(c_op>INVALIDATE)fail(BAD_OP,0);
    else if(c_op==CLEAR)begin allocated<=0;active<=0;retained<=0;faulted<=0;r_entries<=0;state<=RESPONSE;end
    else if(c_op==INVALIDATE)begin faulted<=1;state<=RESPONSE;end
    else if(faulted)fail(INVALID_STATE,0);
    else if((c_op==ADD||c_op==CORRECT)&&c_quantity==0)fail(BAD_QUANTITY,0);
    else if(c_op==QUERY)begin target_symbol<=c_symbol;state<=AGG_SEND;end
    else state<=FIND_SEND;
   end
   FIND_SEND:if(ram_ready)state<=FIND_WAIT;
   FIND_WAIT:if(ram_valid)begin
    if(ram_error||(allocated[cursor]&&row[31:0]==0))fail(BACKEND_FAULT,1);
    else begin
     if(!allocated[cursor]&&!free_seen)begin free_seen<=1;free_slot<=cursor;end
     if(allocated[cursor]&&row[191:128]==match_id)begin
      if(found)fail(BACKEND_FAULT,1);
      else begin found<=1;found_row<=row;target<=cursor;end
     end
     if(!(allocated[cursor]&&row[191:128]==match_id&&found))begin
      if(cursor==ENTRIES-1)state<=FIND_END;else begin cursor<=cursor+1'b1;state<=FIND_SEND;end
     end
    end
   end
   FIND_END:begin
    if(op==ADD&&found)fail(DUPLICATE,0);
    else if(op==ADD&&!free_seen)fail(FULL,0);
    else if(op!=ADD&&!found)fail(NOT_FOUND,0);
    else if(op==GET)begin publish_trade(found_row,active[target]);state<=RESPONSE;end
    else if(op!=ADD&&!active[target])fail(BROKEN,0);
    else begin
     if(op==ADD)begin target<=free_slot;target_symbol<=symbol;candidate<={symbol,match_id,seq_value,price,quantity};end
     else begin target_symbol<=found_row[223:192];candidate<=op==CORRECT?{found_row[223:64],price,quantity}:found_row;end
     cursor<=0;clear_summary();state<=AGG_SEND;
    end
   end
   AGG_SEND:if(ram_ready)state<=AGG_WAIT;
   AGG_WAIT:if(ram_valid)begin
    if(ram_error||(allocated[cursor]&&row[31:0]==0))fail(BACKEND_FAULT,1);
    else begin
     work_include<=include_row;work_price<=selected_price;work_quantity<=selected_quantity;
     work_key<={selected[127:64],selected[191:128]};
     product<=selected_price*selected_quantity;state<=ACCUM;
    end
   end
   ACCUM:begin
    if(work_include)begin
     count<=count+1'b1;volume<=volume+{6'd0,work_quantity};notional<=notional+{6'd0,product};
     if(count==0||work_price>high_price)high_price<=work_price;
     if(count==0||work_price<low_price)low_price<=work_price;
     if(count==0||work_key<first_key)begin first_key<=work_key;open_price<=work_price;end
     if(count==0||work_key>last_key)begin last_key<=work_key;close_price<=work_price;end
    end
    if(cursor==ENTRIES-1)state<=AGG_END;else begin cursor<=cursor+1'b1;state<=AGG_SEND;end
   end
   AGG_END:begin
    if(op==ADD||op==CORRECT)state<=WRITE_SEND;
    else begin
     r_stats_valid<=1;r_symbol<=target_symbol;r_count<={25'd0,count};r_volume<=volume;r_notional<=notional;
     r_open<=open_price;r_high<=high_price;r_low<=low_price;r_close<=close_price;
     if(op==BUST)begin active[target]<=0;publish_trade(candidate,0);end
     state<=RESPONSE;
    end
   end
   WRITE_SEND:if(ram_ready)state<=WRITE_WAIT;
   WRITE_WAIT:if(ram_valid)begin
    if(ram_error)fail(BACKEND_FAULT,1);
    else begin
     if(op==ADD)begin allocated[target]<=1;active[target]<=1;retained<=retained+1'b1;r_entries<={25'd0,retained}+1'b1;end
     publish_trade(candidate,1);r_stats_valid<=1;r_count<={25'd0,count};r_volume<=volume;r_notional<=notional;
     r_open<=open_price;r_high<=high_price;r_low<=low_price;r_close<=close_price;state<=RESPONSE;
    end
   end
   RESPONSE:if(r_ready)state<=IDLE;
   default:fail(BACKEND_FAULT,1);
  endcase
 end
endmodule
`default_nettype wire
