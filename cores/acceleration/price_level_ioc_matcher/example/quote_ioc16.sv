// SPDX-License-Identifier: Apache-2.0
// Absolute L2 quote quantities -> shared book -> isolated IOC sweeps.
`default_nettype none
module quote_ioc16 (
    input wire clk,rst_n,
    input wire q_valid,output wire q_ready,input wire q_ask,
    input wire [31:0] q_price,q_quantity,input wire [7:0] q_tag,
    output wire qr_valid,input wire qr_ready,output wire [2:0] qr_status,output wire [7:0] qr_tag,
    input wire i_valid,output wire i_ready,input wire i_buy,i_market,
    input wire [31:0] i_limit,i_quantity,input wire [7:0] i_tag,
    output wire f_valid,input wire f_ready,output wire f_buy,
    output wire [31:0] f_price,f_quantity,f_remaining,f_index,output wire [7:0] f_tag,
    output wire d_valid,input wire d_ready,output wire [2:0] d_reason,
    output wire [31:0] d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels,output wire [7:0] d_tag
);
    // Quantity zero deletes the price level; nonzero SET replaces its quantity.
    price_level_ioc_matcher matcher (
        .clk(clk),.rst_n(rst_n),.c_valid(q_valid),.c_ready(q_ready),
        .c_op(q_quantity==0?4'd3:4'd0),.c_side(q_ask),.c_price(q_price),
        .c_quantity(q_quantity),.c_rank(32'd0),.c_tag(q_tag),
        .r_valid(qr_valid),.r_ready(qr_ready),.r_status(qr_status),.r_tag(qr_tag),
        .r_op(),.r_side(),.r_found(),.r_price(),.r_quantity(),.r_previous(),.r_bid_levels(),.r_ask_levels(),
        .i_valid(i_valid),.i_ready(i_ready),.i_buy(i_buy),.i_market(i_market),
        .i_limit(i_limit),.i_quantity(i_quantity),.i_tag(i_tag),
        .f_valid(f_valid),.f_ready(f_ready),.f_buy(f_buy),.f_price(f_price),
        .f_quantity(f_quantity),.f_remaining(f_remaining),.f_index(f_index),.f_tag(f_tag),
        .d_valid(d_valid),.d_ready(d_ready),.d_reason(d_reason),.d_filled(d_filled),
        .d_remaining(d_remaining),.d_fills(d_fills),.d_bid_levels(d_bid_levels),.d_ask_levels(d_ask_levels),.d_tag(d_tag));
endmodule
`default_nettype wire
