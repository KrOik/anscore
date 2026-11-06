// SPDX-License-Identifier: Apache-2.0
// Original compound ITCH-delta aggregation and post-transaction BBO service.
`default_nettype none
module itch_l2_delta_book #(
 parameter integer LEVELS=32,TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [2:0] c_op,
 input wire c_remove_valid,c_remove_sell,input wire [31:0] c_remove_price,c_remove_quantity,
 input wire c_add_valid,c_add_sell,input wire [31:0] c_add_price,c_add_quantity,
 input wire [63:0] c_sequence,input wire [TAG_W-1:0] c_tag,
 output wire r_valid,input wire r_ready,output reg [2:0] r_op,output reg [3:0] r_status,
 output reg [63:0] r_sequence,output reg [TAG_W-1:0] r_tag,
 output reg r_found,output reg [37:0] r_quantity,
 output reg [37:0] r_remove_before,r_remove_after,r_add_before,r_add_after,
 output reg r_bid_valid,output reg [31:0] r_bid_price,output reg [37:0] r_bid_quantity,
 output reg r_ask_valid,output reg [31:0] r_ask_price,output reg [37:0] r_ask_quantity,
 output reg r_bid_changed,r_ask_changed,
 output reg [31:0] r_bid_levels,r_ask_levels,
 output wire r_crossed,output reg faulted,output wire busy
);
 localparam integer IW=(LEVELS<2)?1:$clog2(LEVELS);
 localparam integer CW=(LEVELS<2)?1:$clog2(LEVELS+1);
 localparam [3:0] IDLE=0,SCAN_SEND=1,SCAN_WAIT=2,CHECK_REMOVE=3,CHECK_ADD=4,
  BUILD=5,BBO_REMOVE=6,BBO_ADD=7,WRITE1_SEND=8,WRITE1_WAIT=9,
  WRITE2_SEND=10,WRITE2_WAIT=11,COMMIT=12,RESPONSE=13;
 localparam [3:0] OK=0,NOT_FOUND=1,BAD_DELTA=2,UNDERFLOW=3,FULL=4,
  OVERFLOW=5,FAULTED=6,BAD_OP=7,INTERNAL=8;
 reg [3:0] state;
 reg [LEVELS-1:0] live,commit_live;
 reg remove_valid,remove_sell,add_valid,add_sell;
 reg [31:0] remove_price,remove_quantity,add_price,add_quantity;
 reg [IW-1:0] scan_index,remove_index,add_index,free_index,add_target;
 reg remove_found,add_found,free_found;
 reg [37:0] remove_before,add_before,remove_after,add_after;
 reg best_bid_valid,best_ask_valid;
 reg [31:0] best_bid_price,best_ask_price;
 reg [CW-1:0] bid_levels,ask_levels;
 reg [37:0] best_bid_quantity,best_ask_quantity;
 reg write1,write2;
 reg [IW-1:0] write1_index,write2_index;
 reg [71:0] write1_data,write2_data;
 wire same_key=remove_valid && add_valid && remove_sell==add_sell && remove_price==add_price;
 wire [37:0] add_base=same_key?remove_after:(add_found?add_before:38'd0);
 wire [38:0] added={1'b0,add_base}+{7'd0,add_quantity};
 wire ram_ready,ram_valid,ram_error;
 wire [71:0] ram_data;
 wire row_sell=ram_data[70];wire [31:0] row_price=ram_data[69:38];wire [37:0] row_quantity=ram_data[37:0];
 wire hit_remove=row_sell==remove_sell && row_price==remove_price;
 wire hit_add=row_sell==add_sell && row_price==add_price;
 wire request_write=state==WRITE1_SEND || state==WRITE2_SEND;
 wire request_valid=state==SCAN_SEND || request_write;
 wire [IW-1:0] request_index=state==SCAN_SEND?scan_index:(state==WRITE1_SEND?write1_index:write2_index);
 wire [71:0] request_data=state==WRITE1_SEND?write1_data:write2_data;
 wire response_ready=state==SCAN_WAIT || state==WRITE1_WAIT || state==WRITE2_WAIT;
 assign c_ready=!rst && state==IDLE;
 assign r_valid=!rst && state==RESPONSE;
 assign r_crossed=r_bid_valid && r_ask_valid && r_bid_price>=r_ask_price;
 assign busy=state!=IDLE;
 generate if(LEVELS<1 || LEVELS>64 || TAG_W<1 || TAG_W>32)begin:invalid
  itch_l2_delta_book_invalid_parameters__see_README bad_parameters();
 end endgenerate
 // Canonical CE-qualified memory is private and permanently enabled.
 // Write responses are read-first and their payload is deliberately ignored.
 cip_sync_sp_ram #(.DATA_WIDTH(72),.ADDR_WIDTH(IW),.DEPTH(LEVELS)) storage(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(!rst && request_valid),.req_ready(ram_ready),
  .req_write(request_write),.req_addr(request_index),.req_wdata(request_data),.req_wstrb(9'h1ff),
  .rsp_valid(ram_valid),.rsp_ready(!rst && response_ready),.rsp_rdata(ram_data),.rsp_error(ram_error));
 task fail(input [3:0] status,input poison);
  begin r_status<=status;if(poison)faulted<=1;state<=RESPONSE;end
 endtask
 task include_level(input sell,input [31:0] price,input [37:0] quantity);
  begin
   if(sell)begin
    ask_levels<=ask_levels+1'b1;
    if(!best_ask_valid || price<best_ask_price)begin
     best_ask_valid<=1;best_ask_price<=price;best_ask_quantity<=quantity;
    end
   end else begin
    bid_levels<=bid_levels+1'b1;
    if(!best_bid_valid || price>best_bid_price)begin
     best_bid_valid<=1;best_bid_price<=price;best_bid_quantity<=quantity;
    end
   end
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;live<=0;commit_live<=0;faulted<=0;
   remove_valid<=0;remove_sell<=0;remove_price<=0;remove_quantity<=0;
   add_valid<=0;add_sell<=0;add_price<=0;add_quantity<=0;
   scan_index<=0;remove_index<=0;add_index<=0;free_index<=0;add_target<=0;
   remove_found<=0;add_found<=0;free_found<=0;remove_before<=0;add_before<=0;remove_after<=0;add_after<=0;
   best_bid_valid<=0;best_bid_price<=0;best_bid_quantity<=0;best_ask_valid<=0;best_ask_price<=0;best_ask_quantity<=0;
   bid_levels<=0;ask_levels<=0;write1<=0;write2<=0;write1_index<=0;write2_index<=0;write1_data<=0;write2_data<=0;
   r_op<=0;r_status<=0;r_sequence<=0;r_tag<=0;r_found<=0;r_quantity<=0;
   r_remove_before<=0;r_remove_after<=0;r_add_before<=0;r_add_after<=0;
   r_bid_valid<=0;r_bid_price<=0;r_bid_quantity<=0;r_ask_valid<=0;r_ask_price<=0;r_ask_quantity<=0;
   r_bid_changed<=0;r_ask_changed<=0;r_bid_levels<=0;r_ask_levels<=0;
  end else case(state)
   IDLE:if(c_valid && c_ready)begin
    r_op<=c_op;r_status<=OK;r_sequence<=c_sequence;r_tag<=c_tag;r_found<=0;r_quantity<=0;
    r_remove_before<=0;r_remove_after<=0;r_add_before<=0;r_add_after<=0;r_bid_changed<=0;r_ask_changed<=0;
    remove_valid<=c_remove_valid;remove_sell<=c_remove_sell;remove_price<=c_remove_price;remove_quantity<=c_remove_quantity;
    add_valid<=c_add_valid;add_sell<=c_add_sell;add_price<=c_add_price;add_quantity<=c_add_quantity;
    if(c_op==3)begin
     live<=0;faulted<=0;r_bid_levels<=0;r_ask_levels<=0;
     r_bid_changed<=r_bid_valid;r_ask_changed<=r_ask_valid;
     r_bid_valid<=0;r_bid_price<=0;r_bid_quantity<=0;r_ask_valid<=0;r_ask_price<=0;r_ask_quantity<=0;state<=RESPONSE;
    end else if(c_op==4)begin faulted<=1;state<=RESPONSE;end
    else if(c_op>4)fail(BAD_OP,0);
    else if(faulted)fail(FAULTED,0);
    else if(c_op==2)state<=RESPONSE;
    else if(c_op==0 && ((!c_remove_valid && !c_add_valid) ||
             (c_remove_valid && c_remove_quantity==0) || (c_add_valid && c_add_quantity==0)))fail(BAD_DELTA,1);
    else begin
     scan_index<=0;remove_found<=0;add_found<=0;free_found<=0;
     remove_before<=0;add_before<=0;remove_after<=0;add_after<=0;
     best_bid_valid<=0;best_bid_price<=0;best_bid_quantity<=0;
     best_ask_valid<=0;best_ask_price<=0;best_ask_quantity<=0;bid_levels<=0;ask_levels<=0;
     state<=SCAN_SEND;
    end
   end
   SCAN_SEND:if(ram_ready)state<=SCAN_WAIT;
   SCAN_WAIT:if(ram_valid)begin
    if(ram_error)fail(INTERNAL,1);
    else begin
     if(live[scan_index])begin
      if((r_op==1 || remove_valid) && hit_remove)begin remove_found<=1;remove_before<=row_quantity;remove_index<=scan_index;end
      if(r_op==0 && add_valid && hit_add)begin add_found<=1;add_before<=row_quantity;add_index<=scan_index;end
      if(r_op==0 && !(remove_valid && hit_remove) && !(add_valid && hit_add))include_level(row_sell,row_price,row_quantity);
     end else if(!free_found)begin free_found<=1;free_index<=scan_index;end
     if(scan_index==LEVELS-1)state<=CHECK_REMOVE;
     else begin scan_index<=scan_index+1'b1;state<=SCAN_SEND;end
    end
   end
   CHECK_REMOVE:begin
    if(r_op==1)begin
     if(remove_found)begin r_found<=1;r_quantity<=remove_before;state<=RESPONSE;end
     else fail(NOT_FOUND,0);
    end else if(remove_valid && !remove_found)fail(NOT_FOUND,1);
    else if(remove_valid && remove_before<{6'd0,remove_quantity})fail(UNDERFLOW,1);
    else begin remove_after<=remove_valid?remove_before-{6'd0,remove_quantity}:38'd0;state<=CHECK_ADD;end
   end
   CHECK_ADD:begin
    if(add_valid && added[38])fail(OVERFLOW,1);
    else if(add_valid && !add_found && !free_found && !(remove_valid && remove_after==0))fail(FULL,1);
    else begin
     add_after<=add_valid?added[37:0]:38'd0;
     add_target<=add_found?add_index:(free_found?free_index:remove_index);state<=BUILD;
    end
   end
   BUILD:begin
    // Both legs are fully checked. Zero levels disappear only at COMMIT.
    commit_live<=live;
    if(remove_valid)commit_live[remove_index]<=same_key?1'b1:(remove_after!=0);
    if(add_valid)commit_live[add_target]<=1;
    write1<=0;write2<=0;
    if(remove_valid && !same_key && remove_after!=0)begin
     write1<=1;write1_index<=remove_index;write1_data<={1'b0,remove_sell,remove_price,remove_after};
     if(add_valid)begin write2<=1;write2_index<=add_target;write2_data<={1'b0,add_sell,add_price,add_after};end
    end else if(add_valid)begin
     write1<=1;write1_index<=add_target;write1_data<={1'b0,add_sell,add_price,add_after};
    end
    state<=BBO_REMOVE;
   end
   BBO_REMOVE:begin
    if(remove_valid && !same_key && remove_after!=0)include_level(remove_sell,remove_price,remove_after);
    state<=BBO_ADD;
   end
   BBO_ADD:begin
    if(add_valid)include_level(add_sell,add_price,add_after);
    state<=write1?WRITE1_SEND:COMMIT;
   end
   WRITE1_SEND:if(ram_ready)state<=WRITE1_WAIT;
   WRITE1_WAIT:if(ram_valid)begin
    if(ram_error)fail(INTERNAL,1);else state<=write2?WRITE2_SEND:COMMIT;
   end
   WRITE2_SEND:if(ram_ready)state<=WRITE2_WAIT;
   WRITE2_WAIT:if(ram_valid)begin if(ram_error)fail(INTERNAL,1);else state<=COMMIT;end
   COMMIT:begin
    live<=commit_live;r_bid_levels<=bid_levels;r_ask_levels<=ask_levels;
    r_bid_changed<=({r_bid_valid,r_bid_price,r_bid_quantity}!={best_bid_valid,best_bid_price,best_bid_quantity});
    r_ask_changed<=({r_ask_valid,r_ask_price,r_ask_quantity}!={best_ask_valid,best_ask_price,best_ask_quantity});
    r_bid_valid<=best_bid_valid;r_bid_price<=best_bid_price;r_bid_quantity<=best_bid_quantity;
    r_ask_valid<=best_ask_valid;r_ask_price<=best_ask_price;r_ask_quantity<=best_ask_quantity;
    if(remove_valid)begin r_remove_before<=remove_before;r_remove_after<=same_key?add_after:remove_after;end
    if(add_valid)begin r_add_before<=add_before;r_add_after<=add_after;end
    state<=RESPONSE;
   end
   RESPONSE:if(r_ready)state<=IDLE;
   default:fail(INTERNAL,1);
  endcase
 end
endmodule
`default_nettype wire
