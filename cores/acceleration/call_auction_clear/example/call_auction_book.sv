// SPDX-License-Identifier: Apache-2.0
// Auction indication over the unchanged persistent two-sided L2 book.
`default_nettype none
module call_auction_book #(
    parameter integer LEVELS=8, PRICE_W=32, QTY_W=32, TAG_W=8,
    parameter integer SUM_W=QTY_W+$clog2(2*LEVELS+1)
) (
    input wire clk,input wire rst_n,
    input wire c_valid,output wire c_ready,
    input wire [3:0] c_op,input wire c_side,
    input wire [PRICE_W-1:0] c_price,input wire [QTY_W-1:0] c_quantity,
    input wire [31:0] c_rank,input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,
    output wire [3:0] r_op,output wire r_side,
    output wire [2:0] r_status,output wire r_found,
    output wire [PRICE_W-1:0] r_price,
    output wire [QTY_W-1:0] r_quantity,r_previous,
    output wire [31:0] r_bid_levels,r_ask_levels,
    output wire [TAG_W-1:0] r_tag,
    input wire a_valid,output wire a_ready,
    input wire [PRICE_W-1:0] a_reference,input wire [TAG_W-1:0] a_tag,
    output wire m_valid,input wire m_ready,
    output wire [1:0] m_status,output wire [31:0] m_rows,
    output wire [PRICE_W-1:0] m_price,
    output wire [SUM_W-1:0] m_matched,m_buy,m_sell,
    output wire signed [SUM_W:0] m_imbalance,
    output wire [31:0] m_bid_levels,m_ask_levels,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer CW=(LEVELS<2)?1:$clog2(LEVELS+1);
    localparam [3:0] IDLE=0,MAINTENANCE=1,COUNT_SEND=2,COUNT_WAIT=3,
        START_CORE=4,ROW_SEND=5,ROW_WAIT=6,RESULT=7;
    reg [3:0] state;
    reg [PRICE_W-1:0] reference_price;
    reg [TAG_W-1:0] tag;
    reg [CW-1:0] bids,asks,rank;
    reg side;
    wire book_c_ready,book_r_valid,book_r_ready;
    wire core_a_ready,core_s_ready,core_m_valid;
    wire [31:0] total_rows={{(32-CW){1'b0}},bids}+{{(32-CW){1'b0}},asks};
    wire maintenance_admit=(state==IDLE)&&!a_valid;
    wire book_c_valid=(maintenance_admit&&c_valid)||(state==COUNT_SEND)||(state==ROW_SEND);
    wire [3:0] book_c_op=maintenance_admit?c_op:((state==COUNT_SEND)?4'd4:4'd5);
    wire book_c_side=maintenance_admit?c_side:((state==COUNT_SEND)?1'b0:side);
    wire [31:0] book_c_rank=maintenance_admit?c_rank:{{(32-CW){1'b0}},rank};
    assign c_ready=rst_n&&maintenance_admit&&book_c_ready;
    assign a_ready=rst_n&&(state==IDLE)&&book_c_ready&&core_a_ready;
    assign r_valid=rst_n&&(state==MAINTENANCE)&&book_r_valid;
    assign book_r_ready=((state==MAINTENANCE)&&r_ready)||(state==COUNT_WAIT)||((state==ROW_WAIT)&&core_s_ready);
    assign m_valid=rst_n&&(state==RESULT)&&core_m_valid;
    assign m_bid_levels={{(32-CW){1'b0}},bids};
    assign m_ask_levels={{(32-CW){1'b0}},asks};
    generate if(LEVELS<1||LEVELS>32||PRICE_W<1||PRICE_W>32||QTY_W<1||QTY_W>32||
        TAG_W<1||TAG_W>32||SUM_W!=QTY_W+$clog2(2*LEVELS+1)) begin: invalid
        call_auction_book_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    price_level_order_book #(.LEVELS(LEVELS),.PRICE_W(PRICE_W),.QTY_W(QTY_W),.TAG_W(TAG_W)) book (
        .clk(clk),.rst_n(rst_n),.c_valid(book_c_valid),.c_ready(book_c_ready),
        .c_op(book_c_op),.c_side(book_c_side),.c_price(c_price),.c_quantity(c_quantity),
        .c_rank(book_c_rank),.c_tag(c_tag),.r_valid(book_r_valid),.r_ready(book_r_ready),
        .r_op(r_op),.r_side(r_side),.r_status(r_status),.r_found(r_found),.r_price(r_price),
        .r_quantity(r_quantity),.r_previous(r_previous),.r_bid_levels(r_bid_levels),.r_ask_levels(r_ask_levels),.r_tag(r_tag));
    call_auction_clear #(.MAX_ROWS(2*LEVELS),.PRICE_W(PRICE_W),.QTY_W(QTY_W),.TAG_W(TAG_W)) engine (
        .clk(clk),.rst_n(rst_n),.a_valid(state==START_CORE),.a_ready(core_a_ready),
        .a_rows(total_rows),.a_reference(reference_price),.a_tag(tag),
        .s_valid((state==ROW_WAIT)&&book_r_valid),.s_ready(core_s_ready),
        .s_side(side),.s_price(r_price),.s_quantity(r_quantity),
        .m_valid(core_m_valid),.m_ready((state==RESULT)&&m_ready),
        .m_status(m_status),.m_rows(m_rows),.m_price(m_price),.m_matched(m_matched),
        .m_buy(m_buy),.m_sell(m_sell),.m_imbalance(m_imbalance),.m_tag(m_tag));
    // Every private DEPTH rank is below its frozen count. The exclusive owner
    // prevents mutation until the auction response retires, so each is an OK row.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=IDLE;reference_price<=0;tag<=0;bids<=0;asks<=0;rank<=0;side<=0;end
        else case(state)
            IDLE: begin
                if(a_valid&&a_ready) begin reference_price<=a_reference;tag<=a_tag;state<=COUNT_SEND;end
                else if(c_valid&&c_ready) state<=MAINTENANCE;
            end
            MAINTENANCE: if(book_r_valid&&r_ready) state<=IDLE;
            COUNT_SEND: if(book_c_ready) state<=COUNT_WAIT;
            COUNT_WAIT: if(book_r_valid) begin
                bids<=r_bid_levels[CW-1:0];asks<=r_ask_levels[CW-1:0];rank<=0;
                side<=(r_bid_levels==0);state<=START_CORE;
            end
            START_CORE: if(core_a_ready) state<=(total_rows==0)?RESULT:ROW_SEND;
            ROW_SEND: if(book_c_ready) state<=ROW_WAIT;
            ROW_WAIT: if(book_r_valid&&core_s_ready) begin
                if({1'b0,rank}+1'b1==(side?asks:bids)) begin
                    if(!side&&(asks!=0)) begin side<=1;rank<=0;state<=ROW_SEND;end
                    else state<=RESULT;
                end else begin rank<=rank+1'b1;state<=ROW_SEND;end
            end
            RESULT: if(core_m_valid&&m_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
