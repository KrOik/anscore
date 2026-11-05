// SPDX-License-Identifier: Apache-2.0
// Direct default-size endpoint for a previously validated UDP payload stream.
module itch_order_events(
 input wire clk,rst,cfg_valid,output wire cfg_ready,
 input wire [79:0] cfg_session,input wire [63:0] cfg_next,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_keep,s_last,input wire [7:0] s_tag,
 output wire m_valid,input wire m_ready,output wire [7:0] m_type,
 output wire [63:0] m_sequence,output wire [15:0] m_locate,m_tracking,
 output wire [47:0] m_timestamp,output wire [63:0] m_order,m_new_order,
 output wire [31:0] m_quantity,m_price,output wire [63:0] m_stock,
 output wire [31:0] m_attribution,output wire [63:0] m_match,
 output wire m_sell,m_printable,m_price_valid,m_stock_valid,m_attribution_valid,m_match_valid,
 output wire m_last,output wire [7:0] m_tag,
 output wire rsp_valid,input wire rsp_ready,output wire [3:0] rsp_status,
 output wire [79:0] rsp_session,output wire [63:0] rsp_sequence,
 output wire [15:0] rsp_messages,rsp_events,output wire [63:0] rsp_next,
 output wire rsp_end,output wire [7:0] rsp_tag,output wire busy
);
 moldudp64_itch_rx #(.MAX_PACKET_BYTES(2048),.TAG_W(8)) rx(
  .clk(clk),.rst(rst),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_session(cfg_session),.cfg_next(cfg_next),
  .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
  .m_valid(m_valid),.m_ready(m_ready),.m_type(m_type),.m_sequence(m_sequence),.m_locate(m_locate),
  .m_tracking(m_tracking),.m_timestamp(m_timestamp),.m_order(m_order),.m_new_order(m_new_order),
  .m_quantity(m_quantity),.m_price(m_price),.m_stock(m_stock),.m_attribution(m_attribution),.m_match(m_match),
  .m_sell(m_sell),.m_printable(m_printable),.m_price_valid(m_price_valid),.m_stock_valid(m_stock_valid),
  .m_attribution_valid(m_attribution_valid),.m_match_valid(m_match_valid),.m_last(m_last),.m_tag(m_tag),
  .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_status(rsp_status),.rsp_session(rsp_session),
  .rsp_sequence(rsp_sequence),.rsp_messages(rsp_messages),.rsp_events(rsp_events),.rsp_next(rsp_next),
  .rsp_end(rsp_end),.rsp_tag(rsp_tag),.busy(busy));
endmodule
