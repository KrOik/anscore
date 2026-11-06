// SPDX-License-Identifier: Apache-2.0
// Actual order-ID state -> compound aggregation; one owner spans both services.
`default_nettype none
module itch_order_bbo8 #(
 parameter integer L2_LEVELS=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,input wire [15:0] c_locate,
 input wire [63:0] c_stock,c_order,input wire [7:0] c_tag,
 input wire e_valid,output wire e_ready,input wire [7:0] e_type,input wire [15:0] e_locate,
 input wire [63:0] e_order,e_new_order,input wire e_sell,input wire [31:0] e_quantity,e_price,
 input wire [63:0] e_stock,e_sequence,input wire [7:0] e_tag,
 output wire r_valid,input wire r_ready,output reg r_admin,output reg [7:0] r_op,
 output reg [3:0] r_state_status,output wire [3:0] r_l2_status,
 output reg [63:0] r_order,r_sequence,output reg [7:0] r_tag,output reg [31:0] r_orders,
 output wire r_bid_valid,output wire [31:0] r_bid_price,output wire [37:0] r_bid_quantity,
 output wire r_ask_valid,output wire [31:0] r_ask_price,output wire [37:0] r_ask_quantity,
 output wire r_bid_changed,r_ask_changed,output wire [31:0] r_bid_levels,r_ask_levels,
 output wire r_crossed,output wire configured,faulted,busy
);
 localparam [2:0] IDLE=0,STATE_WAIT=1,L2_SEND=2,L2_WAIT=3,POISON_SEND=4,POISON_WAIT=5,OUTPUT=6;
 reg [2:0] state,l2_op;
 reg remove_valid,remove_sell,add_valid,add_sell;
 reg [31:0] remove_price,remove_quantity,add_price,add_quantity;
 wire sc_ready,se_ready,sr_valid,sr_admin,sr_remove,sr_add,sr_old_sell,sr_new_sell,state_faulted;
 wire [7:0] sr_op,sr_tag;wire [3:0] sr_status;
 wire [63:0] sr_order,sr_sequence;wire [31:0] sr_old_price,sr_remove_quantity,sr_new_price,sr_new_quantity,sr_count;
 wire lc_ready,lr_valid,l2_faulted;
 assign c_ready=!rst && state==IDLE && sc_ready;
 assign e_ready=!rst && state==IDLE && se_ready;
 assign r_valid=!rst && state==OUTPUT && lr_valid;
 assign faulted=state_faulted || l2_faulted;
 assign busy=state!=IDLE;
 generate if(L2_LEVELS<1 || L2_LEVELS>8)begin:invalid
  itch_order_bbo8_invalid_parameters__see_README bad_parameters();
 end endgenerate
 itch_order_state #(.ORDERS(8),.TAG_W(8)) orders(
  .clk(clk),.rst(rst),.c_valid(!rst && ((state==IDLE && c_valid) || state==POISON_SEND)),.c_ready(sc_ready),
  .c_op(state==POISON_SEND?2'd3:c_op),.c_locate(c_locate),.c_stock(c_stock),.c_order(c_order),.c_tag(c_tag),
  .e_valid(!rst && state==IDLE && e_valid),.e_ready(se_ready),.e_type(e_type),.e_locate(e_locate),
  .e_order(e_order),.e_new_order(e_new_order),.e_sell(e_sell),.e_quantity(e_quantity),.e_price(e_price),
  .e_stock(e_stock),.e_sequence(e_sequence),.e_tag(e_tag),
  .r_valid(sr_valid),.r_ready(state==STATE_WAIT || state==POISON_WAIT),.r_admin(sr_admin),.r_op(sr_op),.r_status(sr_status),
  .r_request_order(sr_order),.r_sequence(sr_sequence),.r_tag(sr_tag),
  .r_old_valid(),.r_old_sell(sr_old_sell),.r_old_order(),.r_old_price(sr_old_price),.r_old_quantity(),
  .r_new_valid(),.r_new_sell(sr_new_sell),.r_new_order(),.r_new_price(sr_new_price),.r_new_quantity(sr_new_quantity),
  .r_remove_valid(sr_remove),.r_remove_quantity(sr_remove_quantity),.r_add_valid(sr_add),
  .r_count(sr_count),.r_bid_orders(),.r_ask_orders(),.configured(configured),.faulted(state_faulted),.busy());
 itch_l2_delta_book #(.LEVELS(L2_LEVELS),.TAG_W(8)) levels(
  .clk(clk),.rst(rst),.c_valid(state==L2_SEND),.c_ready(lc_ready),.c_op(l2_op),
  .c_remove_valid(remove_valid),.c_remove_sell(remove_sell),.c_remove_price(remove_price),.c_remove_quantity(remove_quantity),
  .c_add_valid(add_valid),.c_add_sell(add_sell),.c_add_price(add_price),.c_add_quantity(add_quantity),.c_sequence(r_sequence),.c_tag(r_tag),
  .r_valid(lr_valid),.r_ready(state==OUTPUT && r_ready),.r_op(),.r_status(r_l2_status),.r_sequence(),.r_tag(),.r_found(),.r_quantity(),
  .r_remove_before(),.r_remove_after(),.r_add_before(),.r_add_after(),
  .r_bid_valid(r_bid_valid),.r_bid_price(r_bid_price),.r_bid_quantity(r_bid_quantity),
  .r_ask_valid(r_ask_valid),.r_ask_price(r_ask_price),.r_ask_quantity(r_ask_quantity),
  .r_bid_changed(r_bid_changed),.r_ask_changed(r_ask_changed),.r_bid_levels(r_bid_levels),.r_ask_levels(r_ask_levels),
  .r_crossed(r_crossed),.faulted(l2_faulted),.busy());
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;l2_op<=0;remove_valid<=0;remove_sell<=0;remove_price<=0;remove_quantity<=0;
   add_valid<=0;add_sell<=0;add_price<=0;add_quantity<=0;
   r_admin<=0;r_op<=0;r_state_status<=0;r_order<=0;r_sequence<=0;r_tag<=0;r_orders<=0;
  end else case(state)
   IDLE:if((c_valid && c_ready) || (e_valid && e_ready))state<=STATE_WAIT;
   STATE_WAIT:if(sr_valid)begin
    r_admin<=sr_admin;r_op<=sr_op;r_state_status<=sr_status;r_order<=sr_order;r_sequence<=sr_sequence;r_tag<=sr_tag;r_orders<=sr_count;
    remove_valid<=sr_remove;remove_sell<=sr_old_sell;remove_price<=sr_old_price;remove_quantity<=sr_remove_quantity;
    add_valid<=sr_add;add_sell<=sr_new_sell;add_price<=sr_new_price;add_quantity<=sr_new_quantity;
    if(sr_admin && (sr_op==0 || sr_op==1) && sr_status==0)l2_op<=3;
    else if((sr_admin && sr_op==3) || state_faulted)l2_op<=4;
    else if(sr_status==0 && (sr_remove || sr_add))l2_op<=0;
    else l2_op<=2;
    state<=L2_SEND;
   end
   L2_SEND:if(lc_ready)state<=L2_WAIT;
   L2_WAIT:if(lr_valid)begin
    // The upstream order mutation is already committed. Invalidate its epoch
    // before exposing the failed aggregate result; never claim a rollback.
    if(l2_op==0 && r_l2_status!=0)state<=POISON_SEND;else state<=OUTPUT;
   end
   POISON_SEND:if(sc_ready)state<=POISON_WAIT;
   POISON_WAIT:if(sr_valid)state<=OUTPUT;
   OUTPUT:if(lr_valid && r_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
`default_nettype wire
