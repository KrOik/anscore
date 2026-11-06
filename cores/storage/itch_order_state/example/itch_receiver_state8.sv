// SPDX-License-Identifier: Apache-2.0
// Actual byte receiver -> order state composition. External controller owns recovery.
module itch_receiver_state8(
 input wire clk,rst,
 input wire rx_cfg_valid,output wire rx_cfg_ready,input wire [79:0] rx_cfg_session,input wire [63:0] rx_cfg_next,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_keep,s_last,input wire [7:0] s_tag,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,input wire [15:0] c_locate,
 input wire [63:0] c_stock,c_order,input wire [7:0] c_tag,
 output wire r_valid,input wire r_ready,output wire r_admin,output wire [7:0] r_op,output wire [3:0] r_status,
 output wire [63:0] r_request_order,r_sequence,output wire [7:0] r_tag,
 output wire r_old_valid,r_old_sell,output wire [63:0] r_old_order,output wire [31:0] r_old_price,r_old_quantity,
 output wire r_new_valid,r_new_sell,output wire [63:0] r_new_order,output wire [31:0] r_new_price,r_new_quantity,
 output wire r_remove_valid,output wire [31:0] r_remove_quantity,output wire r_add_valid,
 output wire [31:0] r_count,r_bid_orders,r_ask_orders,output wire configured,faulted,state_busy,rx_busy,
 output wire p_valid,input wire p_ready,output wire [3:0] p_status,output wire [79:0] p_session,
 output wire [63:0] p_sequence,p_next,output wire [15:0] p_messages,p_events,output wire p_end,output wire [7:0] p_tag
);
 wire ev,er,esell;wire [7:0] etype,etag;wire [15:0] elocate;
 wire [63:0] esequence,eorder,enew,estock;wire [31:0] equantity,eprice;
 moldudp64_itch_rx #(.MAX_PACKET_BYTES(256),.TAG_W(8)) receiver(
  .clk(clk),.rst(rst),.cfg_valid(rx_cfg_valid),.cfg_ready(rx_cfg_ready),.cfg_session(rx_cfg_session),.cfg_next(rx_cfg_next),
  .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
  .m_valid(ev),.m_ready(er),.m_type(etype),.m_sequence(esequence),.m_locate(elocate),.m_tracking(),.m_timestamp(),
  .m_order(eorder),.m_new_order(enew),.m_quantity(equantity),.m_price(eprice),.m_stock(estock),.m_attribution(),.m_match(),
  .m_sell(esell),.m_printable(),.m_price_valid(),.m_stock_valid(),.m_attribution_valid(),.m_match_valid(),.m_last(),.m_tag(etag),
  .rsp_valid(p_valid),.rsp_ready(p_ready),.rsp_status(p_status),.rsp_session(p_session),.rsp_sequence(p_sequence),
  .rsp_messages(p_messages),.rsp_events(p_events),.rsp_next(p_next),.rsp_end(p_end),.rsp_tag(p_tag),.busy(rx_busy));
 itch_order_state #(.ORDERS(8),.TAG_W(8)) state_core(
  .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_locate(c_locate),.c_stock(c_stock),.c_order(c_order),.c_tag(c_tag),
  .e_valid(ev),.e_ready(er),.e_type(etype),.e_locate(elocate),.e_order(eorder),.e_new_order(enew),.e_sell(esell),
  .e_quantity(equantity),.e_price(eprice),.e_stock(estock),.e_sequence(esequence),.e_tag(etag),
  .r_valid(r_valid),.r_ready(r_ready),.r_admin(r_admin),.r_op(r_op),.r_status(r_status),.r_request_order(r_request_order),.r_sequence(r_sequence),.r_tag(r_tag),
  .r_old_valid(r_old_valid),.r_old_sell(r_old_sell),.r_old_order(r_old_order),.r_old_price(r_old_price),.r_old_quantity(r_old_quantity),
  .r_new_valid(r_new_valid),.r_new_sell(r_new_sell),.r_new_order(r_new_order),.r_new_price(r_new_price),.r_new_quantity(r_new_quantity),
  .r_remove_valid(r_remove_valid),.r_remove_quantity(r_remove_quantity),.r_add_valid(r_add_valid),
  .r_count(r_count),.r_bid_orders(r_bid_orders),.r_ask_orders(r_ask_orders),.configured(configured),.faulted(faulted),.busy(state_busy));
endmodule
