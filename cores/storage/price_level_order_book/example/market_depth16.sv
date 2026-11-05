// SPDX-License-Identifier: Apache-2.0
// All-port default 16-level-per-side market-data service.
`default_nettype none
module market_depth16(
    input wire clk, input wire rst_n,
    input wire c_valid, output wire c_ready,
    input wire [3:0] c_op, input wire c_side,
    input wire [32-1:0] c_price,
    input wire [32-1:0] c_quantity,
    input wire [31:0] c_rank, input wire [8-1:0] c_tag,
    output wire r_valid, input wire r_ready,
    output wire [3:0] r_op, output wire r_side,
    output wire [2:0] r_status, output wire r_found,
    output wire [32-1:0] r_price,
    output wire [32-1:0] r_quantity, r_previous,
    output wire [31:0] r_bid_levels, r_ask_levels,
    output wire [8-1:0] r_tag
);
    price_level_order_book book (.*);
endmodule
`default_nettype wire
