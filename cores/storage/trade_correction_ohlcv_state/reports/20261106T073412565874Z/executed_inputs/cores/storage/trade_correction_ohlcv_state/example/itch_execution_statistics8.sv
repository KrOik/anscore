// SPDX-License-Identifier: Apache-2.0
// Normalized ITCH E/C executions -> actual order mutation -> retained statistics.
`default_nettype none
module itch_execution_statistics8 #(
 parameter integer TAG_W=8
)(
 input wire clk,rst,input wire c_valid,output wire c_ready,input wire [3:0] c_op,
 input wire [15:0] c_locate,input wire [63:0] c_stock,c_order,c_match,
 input wire [31:0] c_price,c_quantity,input wire [TAG_W-1:0] c_tag,
 input wire e_valid,output wire e_ready,input wire [7:0] e_type,input wire [15:0] e_locate,
 input wire [63:0] e_order,e_new_order,e_stock,e_sequence,e_match,
 input wire e_sell,e_printable,input wire [31:0] e_price,e_quantity,input wire [TAG_W-1:0] e_tag,
 output wire r_valid,input wire r_ready,output reg r_admin,output reg [7:0] r_op,
 output reg [1:0] r_wrapper_status,output reg [3:0] r_order_status,r_trade_status,
 output reg r_isolated,output reg [3:0] r_isolation_trade_status,r_isolation_order_status,
 output reg [63:0] r_request_order,r_event_sequence,
 output reg [31:0] r_order_count,r_removed,output reg r_old_valid,r_new_valid,
 output reg [31:0] r_old_price,r_old_quantity,r_new_price,r_new_quantity,
 output reg [31:0] r_entries,r_symbol,output reg r_trade_valid,r_active,
 output reg [63:0] r_match,r_sequence,output reg [31:0] r_price,r_quantity,
 output reg r_stats_valid,output reg [31:0] r_count,output reg [37:0] r_volume,
 output reg [69:0] r_notional,output reg [31:0] r_open,r_high,r_low,r_close,
 output reg [TAG_W-1:0] r_tag,output wire configured,faulted,busy
);
 localparam [2:0] IDLE=0,CORE_SEND=1,CORE_WAIT=2,BOOK_SEND=3,BOOK_WAIT=4,OUTPUT=5;
 localparam [3:0] CONFIG_CORE=0,CONFIG_BOOK=1,CLEAR_CORE=2,CLEAR_BOOK=3,
  ADMIN_CORE=4,QUERY_BOOK=5,EVENT_BOOK=6,EVENT_TRADE=7,ISO_CORE=8,ISO_BOOK=9,INVALID_CORE=10,INVALID_BOOK=11;
 reg [2:0] state;
 reg [3:0] phase,admin_op;
 reg [15:0] locate,selected_locate;
 reg [63:0] stock,order_id,new_order_id,event_sequence,match_id;
 reg [7:0] kind;
 reg sell,printable;
 reg [31:0] price,quantity,execution_price;
 wire br,bv,ba,b_old,b_new,b_remove,b_config,b_fault;
 wire [3:0] bs;wire [7:0] bo;wire [63:0] b_request,b_seq,b_old_id,b_new_id;
 wire [31:0] b_old_price,b_old_quantity,b_new_price,b_new_quantity,b_removed,b_count,b_bids,b_asks;
 wire b_old_sell,b_new_sell;wire [TAG_W-1:0] b_tag;
 wire kr,kv,k_trade,k_active,k_stats,k_fault;
 wire [3:0] ko,ks;wire [31:0] k_entries,k_symbol,k_price,k_quantity,k_count,k_open,k_high,k_low,k_close;
 wire [63:0] k_match,k_sequence;wire [37:0] k_volume;wire [69:0] k_notional;wire [TAG_W-1:0] k_tag;
 wire [3:0] core_op=(phase==CONFIG_CORE||phase==CLEAR_CORE)?4'd5:
  (phase==ISO_CORE||phase==INVALID_CORE)?4'd6:phase==EVENT_TRADE?4'd0:
  admin_op==2?4'd3:admin_op==3?4'd4:admin_op==4?4'd1:4'd2;
 wire [1:0] book_op=phase==CONFIG_BOOK?2'd0:phase==CLEAR_BOOK?2'd1:
  (phase==ISO_BOOK||phase==INVALID_BOOK)?2'd3:2'd2;
 assign c_ready=!rst&&state==IDLE&&br&&kr;
 assign e_ready=c_ready&&!c_valid;
 assign r_valid=!rst&&state==OUTPUT;
 assign configured=b_config;
 assign faulted=k_fault||b_fault;
 assign busy=!rst&&(state!=IDLE||!br||!kr);
 itch_order_state #(.ORDERS(8),.TAG_W(TAG_W)) orders(
  .clk(clk),.rst(rst),.c_valid(!rst&&state==BOOK_SEND&&phase!=EVENT_BOOK),.c_ready(br),.c_op(book_op),
  .c_locate(locate),.c_stock(stock),.c_order(order_id),.c_tag({TAG_W{1'b0}}),
  .e_valid(!rst&&state==BOOK_SEND&&phase==EVENT_BOOK),.e_ready(),.e_type(kind),.e_locate(locate),
  .e_order(order_id),.e_new_order(new_order_id),.e_sell(sell),.e_quantity(quantity),.e_price(price),
  .e_stock(stock),.e_sequence(event_sequence),.e_tag({TAG_W{1'b0}}),
  .r_valid(bv),.r_ready(state==BOOK_WAIT),.r_admin(ba),.r_op(bo),.r_status(bs),.r_request_order(b_request),
  .r_sequence(b_seq),.r_tag(b_tag),.r_old_valid(b_old),.r_old_sell(b_old_sell),.r_old_order(b_old_id),
  .r_old_price(b_old_price),.r_old_quantity(b_old_quantity),.r_new_valid(b_new),.r_new_sell(b_new_sell),
  .r_new_order(b_new_id),.r_new_price(b_new_price),.r_new_quantity(b_new_quantity),
  .r_remove_valid(b_remove),.r_remove_quantity(b_removed),.r_add_valid(),
  .r_count(b_count),.r_bid_orders(b_bids),.r_ask_orders(b_asks),.configured(b_config),.faulted(b_fault),.busy());
 trade_correction_ohlcv_state #(.ENTRIES(8),.TAG_W(TAG_W)) trades(
  .clk(clk),.rst(rst),.c_valid(!rst&&state==CORE_SEND),.c_ready(kr),.c_op(core_op),
  .c_symbol({16'd0,selected_locate}),.c_match(match_id),.c_sequence(event_sequence),
  .c_price(phase==EVENT_TRADE?execution_price:price),.c_quantity(quantity),.c_tag({TAG_W{1'b0}}),
  .r_valid(kv),.r_ready(state==CORE_WAIT),.r_op(ko),.r_status(ks),.r_entries(k_entries),.r_symbol(k_symbol),
  .r_trade_valid(k_trade),.r_active(k_active),.r_match(k_match),.r_sequence(k_sequence),.r_price(k_price),.r_quantity(k_quantity),
  .r_stats_valid(k_stats),.r_count(k_count),.r_volume(k_volume),.r_notional(k_notional),
  .r_open(k_open),.r_high(k_high),.r_low(k_low),.r_close(k_close),.r_tag(k_tag),.faulted(k_fault),.busy());
 task capture_trade;
  begin r_entries<=k_entries;r_symbol<=k_symbol;r_trade_valid<=k_trade;r_active<=k_active;r_match<=k_match;
   r_sequence<=k_sequence;r_price<=k_price;r_quantity<=k_quantity;r_stats_valid<=k_stats;r_count<=k_count;
   r_volume<=k_volume;r_notional<=k_notional;r_open<=k_open;r_high<=k_high;r_low<=k_low;r_close<=k_close;end
 endtask
 task isolate;
  begin phase<=ISO_CORE;state<=CORE_SEND;end
 endtask
 task clear_result;
  begin r_wrapper_status<=0;r_order_status<=0;r_trade_status<=0;r_isolated<=0;
   r_isolation_trade_status<=0;r_isolation_order_status<=0;r_order_count<=0;r_removed<=0;
   r_old_valid<=0;r_new_valid<=0;r_old_price<=0;r_old_quantity<=0;r_new_price<=0;r_new_quantity<=0;
   r_entries<=0;r_symbol<=0;r_trade_valid<=0;r_active<=0;r_match<=0;r_sequence<=0;r_price<=0;r_quantity<=0;
   r_stats_valid<=0;r_count<=0;r_volume<=0;r_notional<=0;r_open<=0;r_high<=0;r_low<=0;r_close<=0;end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;phase<=0;admin_op<=0;locate<=0;selected_locate<=0;stock<=0;order_id<=0;new_order_id<=0;
   event_sequence<=0;match_id<=0;kind<=0;sell<=0;printable<=0;price<=0;quantity<=0;execution_price<=0;
   r_admin<=0;r_op<=0;r_request_order<=0;r_event_sequence<=0;r_tag<=0;clear_result();
  end else case(state)
   IDLE:begin
    if(c_valid&&c_ready)begin
     clear_result();r_admin<=1;r_op<={4'd0,c_op};r_request_order<=c_order;r_event_sequence<=0;r_tag<=c_tag;
     admin_op<=c_op;locate<=c_locate;stock<=c_stock;order_id<=c_order;match_id<=c_match;
     price<=c_price;quantity<=c_quantity;event_sequence<=0;
     if(c_op>7)begin r_wrapper_status<=2;state<=OUTPUT;end
     else if(c_op==0)begin phase<=CONFIG_CORE;state<=CORE_SEND;end
     else if(c_op==1)begin phase<=CLEAR_CORE;state<=CORE_SEND;end
     else if(c_op==7)begin phase<=INVALID_CORE;state<=CORE_SEND;end
     else if(!b_config)begin r_wrapper_status<=1;state<=OUTPUT;end
     else if(c_op==6)begin phase<=QUERY_BOOK;state<=BOOK_SEND;end
     else begin phase<=ADMIN_CORE;state<=CORE_SEND;end
    end else if(e_valid&&e_ready)begin
     clear_result();r_admin<=0;r_op<=e_type;r_request_order<=e_order;r_event_sequence<=e_sequence;r_tag<=e_tag;
     locate<=e_locate;stock<=e_stock;order_id<=e_order;new_order_id<=e_new_order;
     event_sequence<=e_sequence;match_id<=e_match;kind<=e_type;sell<=e_sell;printable<=e_printable;
     price<=e_price;quantity<=e_quantity;phase<=EVENT_BOOK;state<=BOOK_SEND;
    end
   end
   CORE_SEND:if(kr)state<=CORE_WAIT;
   CORE_WAIT:if(kv)begin
    if(phase==ISO_CORE)begin r_isolation_trade_status<=ks;phase<=ISO_BOOK;state<=BOOK_SEND;end
    else if(phase==INVALID_CORE)begin r_trade_status<=ks;phase<=INVALID_BOOK;state<=BOOK_SEND;end
    else begin
     r_trade_status<=ks;
     if(phase==CONFIG_CORE||phase==CLEAR_CORE)begin
      if(ks!=0)state<=OUTPUT;
      else begin phase<=phase==CONFIG_CORE?CONFIG_BOOK:CLEAR_BOOK;state<=BOOK_SEND;end
     end else if(phase==EVENT_TRADE&&ks!=0)isolate();
     else begin capture_trade();state<=OUTPUT;end
    end
   end
   BOOK_SEND:if(br)state<=BOOK_WAIT;
   BOOK_WAIT:if(bv)begin
    if(phase==ISO_BOOK)begin
     r_isolation_order_status<=bs;r_isolated<=r_isolation_trade_status==0&&bs==0;
     if(r_isolation_trade_status!=0||bs!=0)r_wrapper_status<=3;
     state<=OUTPUT;
    end else if(phase==INVALID_BOOK)begin
     r_order_status<=bs;r_isolated<=r_trade_status==0&&bs==0;
     if(r_trade_status!=0||bs!=0)r_wrapper_status<=3;state<=OUTPUT;
    end else begin
     r_order_status<=bs;r_order_count<=b_count;r_removed<=b_remove?b_removed:0;
     r_old_valid<=b_old;r_new_valid<=b_new;r_old_price<=b_old_price;r_old_quantity<=b_old_quantity;
     r_new_price<=b_new_price;r_new_quantity<=b_new_quantity;
     if(phase==CONFIG_BOOK)begin
      if(bs==0)begin selected_locate<=locate;state<=OUTPUT;end else isolate();
     end else if(phase==CLEAR_BOOK)begin if(bs==0)state<=OUTPUT;else isolate();end
     else if(phase==EVENT_BOOK)begin
      if(bs>=3)isolate();
      else if(bs==0&&(kind=="E"||(kind=="C"&&printable)))begin
       execution_price<=kind=="C"?price:b_old_price;quantity<=b_removed;phase<=EVENT_TRADE;state<=CORE_SEND;
      end else state<=OUTPUT;
     end else state<=OUTPUT;
    end
   end
   OUTPUT:if(r_ready)state<=IDLE;
   default:begin r_wrapper_status<=3;state<=OUTPUT;end
  endcase
 end
endmodule
`default_nettype wire
