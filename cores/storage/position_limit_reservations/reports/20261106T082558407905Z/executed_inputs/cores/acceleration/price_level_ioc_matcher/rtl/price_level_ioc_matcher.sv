// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE aggregated-price-level IOC composition. No individual orders.
`default_nettype none
module price_level_ioc_matcher #(
    parameter integer LEVELS=16, PRICE_W=32, QTY_W=32, TAG_W=8
) (
    input wire clk, input wire rst_n,
    // Maintenance command/response; identical operation semantics to the book.
    input wire c_valid, output wire c_ready,
    input wire [3:0] c_op, input wire c_side,
    input wire [PRICE_W-1:0] c_price,
    input wire [QTY_W-1:0] c_quantity,
    input wire [31:0] c_rank, input wire [TAG_W-1:0] c_tag,
    output wire r_valid, input wire r_ready,
    output reg [3:0] r_op, output reg r_side,
    output reg [2:0] r_status, output reg r_found,
    output reg [PRICE_W-1:0] r_price,
    output reg [QTY_W-1:0] r_quantity, r_previous,
    output wire [31:0] r_bid_levels, r_ask_levels,
    output reg [TAG_W-1:0] r_tag,
    // Immediate-or-cancel taker. Buy consumes asks; sell consumes bids.
    input wire i_valid, output wire i_ready,
    input wire i_buy, input wire i_market,
    input wire [PRICE_W-1:0] i_limit,
    input wire [QTY_W-1:0] i_quantity,
    input wire [TAG_W-1:0] i_tag,
    output wire f_valid, input wire f_ready,
    output reg f_buy, output reg [PRICE_W-1:0] f_price,
    output reg [QTY_W-1:0] f_quantity, f_remaining,
    output reg [31:0] f_index, output reg [TAG_W-1:0] f_tag,
    output wire d_valid, input wire d_ready,
    output reg [2:0] d_reason,
    output reg [QTY_W-1:0] d_filled, d_remaining,
    output reg [31:0] d_fills,
    output wire [31:0] d_bid_levels, d_ask_levels,
    output reg [TAG_W-1:0] d_tag
);
    localparam [3:0] IDLE=0,M_SEND=1,M_WAIT=2,M_REPLY=3,
        BEST_SEND=4,BEST_WAIT=5,SUB_SEND=6,SUB_WAIT=7,FILL=8,DONE=9;
    reg [3:0] state;
    reg [3:0] maint_op;
    reg maint_side;
    reg [PRICE_W-1:0] maint_price;
    reg [QTY_W-1:0] maint_quantity;
    reg [31:0] maint_rank;
    reg [TAG_W-1:0] maint_tag;
    reg buy,market;
    reg [PRICE_W-1:0] limit_price,best_price;
    reg [QTY_W-1:0] best_quantity,take_quantity;
    reg [31:0] bid_count,ask_count;
    wire b_ready,b_valid;
    wire [3:0] b_op;
    wire b_side,b_found;
    wire [2:0] b_status;
    wire [PRICE_W-1:0] b_price;
    wire [QTY_W-1:0] b_quantity,b_previous;
    wire [31:0] b_bids,b_asks;
    wire [TAG_W-1:0] b_tag;
    wire maintenance=(state==M_SEND);
    wire request=(state==M_SEND||state==BEST_SEND||state==SUB_SEND);
    wire reply=(state==M_WAIT||state==BEST_WAIT||state==SUB_WAIT);
    generate if(LEVELS<1||LEVELS>32||PRICE_W<1||PRICE_W>32||QTY_W<1||QTY_W>32||TAG_W<1||TAG_W>32) begin: invalid
        price_level_ioc_matcher_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    price_level_order_book #(.LEVELS(LEVELS),.PRICE_W(PRICE_W),.QTY_W(QTY_W),.TAG_W(TAG_W)) book (
        .clk(clk),.rst_n(rst_n),.c_valid(rst_n&&request),.c_ready(b_ready),
        .c_op(maintenance?maint_op:((state==SUB_SEND)?4'd2:4'd4)),
        .c_side(maintenance?maint_side:buy),
        .c_price(maintenance?maint_price:best_price),
        .c_quantity(maintenance?maint_quantity:take_quantity),
        .c_rank(maintenance?maint_rank:32'd0),.c_tag(maintenance?maint_tag:{TAG_W{1'b0}}),
        .r_valid(b_valid),.r_ready(rst_n&&reply),.r_op(b_op),.r_side(b_side),
        .r_status(b_status),.r_found(b_found),.r_price(b_price),
        .r_quantity(b_quantity),.r_previous(b_previous),
        .r_bid_levels(b_bids),.r_ask_levels(b_asks),.r_tag(b_tag));
    assign c_ready=rst_n&&state==IDLE&&b_ready;
    assign i_ready=c_ready&&!c_valid;
    assign r_valid=rst_n&&state==M_REPLY;
    assign f_valid=rst_n&&state==FILL;
    assign d_valid=rst_n&&state==DONE;
    assign r_bid_levels=bid_count;
    assign r_ask_levels=ask_count;
    assign d_bid_levels=bid_count;
    assign d_ask_levels=ask_count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;maint_op<=0;maint_side<=0;maint_price<=0;maint_quantity<=0;maint_rank<=0;maint_tag<=0;
            buy<=0;market<=0;limit_price<=0;best_price<=0;best_quantity<=0;take_quantity<=0;
            bid_count<=0;ask_count<=0;
            r_op<=0;r_side<=0;r_status<=0;r_found<=0;r_price<=0;r_quantity<=0;r_previous<=0;r_tag<=0;
            f_buy<=0;f_price<=0;f_quantity<=0;f_remaining<=0;f_index<=0;f_tag<=0;
            d_reason<=0;d_filled<=0;d_remaining<=0;d_fills<=0;d_tag<=0;
        end else begin
            if(reply&&b_valid) begin bid_count<=b_bids;ask_count<=b_asks;end
            case(state)
                IDLE: if(c_valid&&c_ready) begin
                    maint_op<=c_op;maint_side<=c_side;maint_price<=c_price;
                    maint_quantity<=c_quantity;maint_rank<=c_rank;maint_tag<=c_tag;state<=M_SEND;
                end else if(i_valid&&i_ready) begin
                    buy<=i_buy;market<=i_market;limit_price<=i_limit;
                    d_filled<=0;d_remaining<=i_quantity;d_fills<=0;d_tag<=i_tag;
                    if(i_quantity==0) begin d_reason<=3;state<=DONE;end
                    else state<=BEST_SEND;
                end
                M_SEND: if(b_ready) state<=M_WAIT;
                M_WAIT: if(b_valid) begin
                    r_op<=b_op;r_side<=b_side;r_status<=b_status;r_found<=b_found;
                    r_price<=b_price;r_quantity<=b_quantity;r_previous<=b_previous;r_tag<=b_tag;state<=M_REPLY;
                end
                M_REPLY: if(r_ready) state<=IDLE;
                BEST_SEND: if(b_ready) state<=BEST_WAIT;
                BEST_WAIT: if(b_valid) begin
                    if(b_status==1&&!b_found) begin d_reason<=1;state<=DONE;end
                    else if(b_status!=0||!b_found||b_quantity==0) begin d_reason<=4;state<=DONE;end
                    else if(!market&&((buy&&b_price>limit_price)||(!buy&&b_price<limit_price))) begin
                        d_reason<=2;state<=DONE;
                    end else begin
                        best_price<=b_price;best_quantity<=b_quantity;
                        take_quantity<=(b_quantity<d_remaining)?b_quantity:d_remaining;state<=SUB_SEND;
                    end
                end
                SUB_SEND: if(b_ready) state<=SUB_WAIT;
                SUB_WAIT: if(b_valid) begin
                    // Publish only a confirmed mutation; no maintenance can interleave.
                    if(b_status!=0||!b_found||b_price!=best_price||b_previous!=best_quantity||
                       b_quantity!=best_quantity-take_quantity) begin d_reason<=4;state<=DONE;end
                    else begin
                        f_buy<=buy;f_price<=best_price;f_quantity<=take_quantity;
                        f_remaining<=d_remaining-take_quantity;f_index<=d_fills;f_tag<=d_tag;
                        d_remaining<=d_remaining-take_quantity;d_filled<=d_filled+take_quantity;
                        d_fills<=d_fills+1'b1;state<=FILL;
                    end
                end
                FILL: if(f_ready) begin
                    if(d_remaining==0) begin d_reason<=0;state<=DONE;end
                    else state<=BEST_SEND;
                end
                DONE: if(d_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
