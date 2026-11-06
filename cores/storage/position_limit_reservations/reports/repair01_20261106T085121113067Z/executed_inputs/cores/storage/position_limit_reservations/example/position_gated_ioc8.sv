// SPDX-License-Identifier: Apache-2.0
// Actual two-sided limit IOC composition, with persistent signed positions.
`default_nettype none
module position_gated_ioc8(
    input wire clk,rst_n,
    input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_context,input wire [63:0] c_ticket,input wire c_buy,
    input wire [31:0] c_quantity,input wire signed [63:0] c_position,c_min_position,c_max_position,
    input wire [7:0] c_tag,
    output wire r_valid,input wire r_ready,output wire [2:0] r_op,output wire [3:0] r_status,
    output wire [31:0] r_context,output wire [63:0] r_ticket,output wire r_buy,
    output wire [31:0] r_remaining,output wire signed [63:0] r_position,r_min_position,r_max_position,
    output wire [37:0] r_buy_open,r_sell_open,output wire [31:0] r_live,output wire [7:0] r_tag,
    input wire q_valid,output wire q_ready,input wire [3:0] q_op,input wire q_side,
    input wire [31:0] q_price,q_quantity,q_rank,input wire [7:0] q_tag,
    output wire qr_valid,input wire qr_ready,output wire [3:0] qr_op,output wire qr_side,
    output wire [2:0] qr_status,output wire qr_found,
    output wire [31:0] qr_price,qr_quantity,qr_previous,qr_bid_levels,qr_ask_levels,output wire [7:0] qr_tag,
    input wire i_valid,output wire i_ready,input wire [31:0] i_context,
    input wire [63:0] i_ticket,input wire i_buy,input wire [31:0] i_limit,i_quantity,input wire [7:0] i_tag,
    output wire f_valid,input wire f_ready,output wire f_buy,
    output wire [31:0] f_price,f_quantity,f_remaining,f_index,output wire [7:0] f_tag,
    output wire d_valid,input wire d_ready,output reg [1:0] d_stage,
    output reg [3:0] d_risk_status,output reg [2:0] d_reason,
    output reg [31:0] d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels,d_context,
    output reg [63:0] d_ticket,output reg signed [63:0] d_position,
    output reg [37:0] d_buy_open,d_sell_open,output reg [7:0] d_tag,output wire faulted
);
    localparam [3:0] IDLE=0,ADMIN=1,MAINT=2,RES_SEND=3,RES_WAIT=4,IOC_SEND=5,IOC_WAIT=6,
        FILL_SEND=7,FILL_WAIT=8,CANCEL_SEND=9,CANCEL_WAIT=10,INV_SEND=11,INV_WAIT=12,DONE=13;
    reg [3:0] state;
    reg [31:0] saved_context,saved_limit,saved_quantity;
    reg [63:0] saved_ticket;
    reg saved_buy,stream_bad;
    reg [7:0] saved_tag;
    reg [32:0] seen_filled;
    reg [31:0] seen_fills;
    wire lc_ready,lr_valid,ledger_busy;
    wire [3:0] lr_status;
    wire [2:0] lr_op;
    wire [31:0] lr_context,lr_remaining;
    wire [63:0] lr_ticket;
    wire lr_buy;
    wire signed [63:0] lr_position;
    wire [37:0] lr_buy_open,lr_sell_open;
    wire [7:0] lr_tag;
    wire internal_command=(state==RES_SEND||state==FILL_SEND||state==CANCEL_SEND||state==INV_SEND);
    wire internal_reply=(state==RES_WAIT||state==FILL_WAIT||state==CANCEL_WAIT||state==INV_WAIT);
    wire [2:0] ledger_op=(state==IDLE)?c_op:((state==RES_SEND)?3'd1:((state==FILL_SEND)?3'd2:((state==CANCEL_SEND)?3'd3:3'd7)));
    wire [31:0] ledger_quantity=(state==IDLE)?c_quantity:((state==FILL_SEND)?d_filled:saved_quantity);
    position_limit_reservations ledger(
        .clk(clk),.rst_n(rst_n),.c_valid(rst_n&&((state==IDLE&&c_valid)||internal_command)),.c_ready(lc_ready),
        .c_op(ledger_op),.c_context(state==IDLE?c_context:saved_context),.c_ticket(state==IDLE?c_ticket:saved_ticket),
        .c_buy(state==IDLE?c_buy:saved_buy),.c_quantity(ledger_quantity),
        .c_position(c_position),.c_min_position(c_min_position),.c_max_position(c_max_position),.c_tag(state==IDLE?c_tag:saved_tag),
        .r_valid(lr_valid),.r_ready((state==ADMIN&&r_ready)||internal_reply),.r_op(lr_op),.r_status(lr_status),
        .r_context(lr_context),.r_ticket(lr_ticket),.r_buy(lr_buy),.r_remaining(lr_remaining),
        .r_position(lr_position),.r_min_position(r_min_position),.r_max_position(r_max_position),
        .r_buy_open(lr_buy_open),.r_sell_open(lr_sell_open),.r_live(r_live),.r_tag(lr_tag),.busy(ledger_busy),.faulted(faulted));
    assign c_ready=rst_n&&state==IDLE&&lc_ready;
    assign r_valid=rst_n&&state==ADMIN&&lr_valid;
    assign r_op=lr_op;assign r_status=lr_status;assign r_context=lr_context;assign r_ticket=lr_ticket;
    assign r_buy=lr_buy;assign r_remaining=lr_remaining;assign r_position=lr_position;
    assign r_buy_open=lr_buy_open;assign r_sell_open=lr_sell_open;assign r_tag=lr_tag;
    wire mi_ready,mf_valid,md_valid,mq_ready,mqr_valid;
    wire [2:0] md_reason;
    wire [31:0] md_filled,md_remaining,md_fills,md_bids,md_asks;
    wire [7:0] md_tag;
    price_level_ioc_matcher #(.LEVELS(8)) matcher(
        .clk(clk),.rst_n(rst_n),.c_valid(rst_n&&state==IDLE&&!c_valid&&q_valid),.c_ready(mq_ready),
        .c_op(q_op),.c_side(q_side),.c_price(q_price),.c_quantity(q_quantity),.c_rank(q_rank),.c_tag(q_tag),
        .r_valid(mqr_valid),.r_ready(state==MAINT&&qr_ready),.r_op(qr_op),.r_side(qr_side),
        .r_status(qr_status),.r_found(qr_found),.r_price(qr_price),.r_quantity(qr_quantity),.r_previous(qr_previous),
        .r_bid_levels(qr_bid_levels),.r_ask_levels(qr_ask_levels),.r_tag(qr_tag),
        .i_valid(rst_n&&state==IOC_SEND),.i_ready(mi_ready),.i_buy(saved_buy),.i_market(1'b0),
        .i_limit(saved_limit),.i_quantity(saved_quantity),.i_tag(saved_tag),
        .f_valid(mf_valid),.f_ready(state==IOC_WAIT&&f_ready),.f_buy(f_buy),.f_price(f_price),
        .f_quantity(f_quantity),.f_remaining(f_remaining),.f_index(f_index),.f_tag(f_tag),
        .d_valid(md_valid),.d_ready(state==IOC_WAIT),.d_reason(md_reason),.d_filled(md_filled),
        .d_remaining(md_remaining),.d_fills(md_fills),.d_bid_levels(md_bids),.d_ask_levels(md_asks),.d_tag(md_tag));
    assign q_ready=rst_n&&state==IDLE&&!c_valid&&mq_ready;
    assign qr_valid=rst_n&&state==MAINT&&mqr_valid;
    assign i_ready=rst_n&&state==IDLE&&!c_valid&&!q_valid&&lc_ready&&mi_ready;
    assign f_valid=rst_n&&state==IOC_WAIT&&mf_valid;
    assign d_valid=rst_n&&state==DONE;
    wire [32:0] next_seen=seen_filled+{1'b0,f_quantity};
    wire risk_identity=(lr_context==saved_context&&lr_ticket==saved_ticket&&lr_buy==saved_buy&&lr_tag==saved_tag);
    task isolate;
        begin d_stage<=2;d_position<=0;d_buy_open<=0;d_sell_open<=0;state<=INV_SEND;end
    endtask
    task capture_position;
        begin d_position<=lr_position;d_buy_open<=lr_buy_open;d_sell_open<=lr_sell_open;end
    endtask
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;saved_context<=0;saved_limit<=0;saved_quantity<=0;saved_ticket<=0;saved_buy<=0;saved_tag<=0;
            stream_bad<=0;seen_filled<=0;seen_fills<=0;
            d_stage<=0;d_risk_status<=0;d_reason<=0;d_filled<=0;d_remaining<=0;d_fills<=0;
            d_bid_levels<=0;d_ask_levels<=0;d_context<=0;d_ticket<=0;d_position<=0;d_buy_open<=0;d_sell_open<=0;d_tag<=0;
        end else case(state)
            IDLE:if(c_valid&&c_ready)state<=ADMIN;
            else if(q_valid&&q_ready)state<=MAINT;
            else if(i_valid&&i_ready)begin
                saved_context<=i_context;saved_ticket<=i_ticket;saved_buy<=i_buy;saved_limit<=i_limit;saved_quantity<=i_quantity;saved_tag<=i_tag;
                seen_filled<=0;seen_fills<=0;stream_bad<=0;
                d_stage<=0;d_risk_status<=0;d_reason<=0;d_filled<=0;d_remaining<=i_quantity;d_fills<=0;
                d_bid_levels<=0;d_ask_levels<=0;d_context<=i_context;d_ticket<=i_ticket;d_position<=0;d_buy_open<=0;d_sell_open<=0;d_tag<=i_tag;
                state<=RES_SEND;
            end
            ADMIN:if(lr_valid&&r_ready)state<=IDLE;
            MAINT:if(mqr_valid&&qr_ready)state<=IDLE;
            RES_SEND:if(lc_ready)state<=RES_WAIT;
            RES_WAIT:if(lr_valid)begin
                d_risk_status<=lr_status;
                if(lr_status!=0)begin d_stage<=(lr_status==11)?2'd2:2'd1;state<=DONE;end
                else if(lr_op!=1||!risk_identity||lr_remaining!=saved_quantity)isolate();
                else state<=IOC_SEND;
            end
            IOC_SEND:if(mi_ready)state<=IOC_WAIT;
            IOC_WAIT:begin
                if(mf_valid&&f_ready)begin
                    seen_filled<=next_seen;seen_fills<=seen_fills+1'b1;
                    if(f_buy!=saved_buy||f_tag!=saved_tag||f_quantity==0||f_index!=seen_fills||
                       next_seen>{1'b0,saved_quantity}||{1'b0,f_remaining}+next_seen!={1'b0,saved_quantity})stream_bad<=1;
                end
                if(md_valid)begin
                    d_reason<=md_reason;d_filled<=md_filled;d_remaining<=md_remaining;d_fills<=md_fills;d_bid_levels<=md_bids;d_ask_levels<=md_asks;
                    if(md_reason>3||stream_bad||md_tag!=saved_tag||seen_filled!={1'b0,md_filled}||seen_fills!=md_fills||
                       {1'b0,md_filled}+{1'b0,md_remaining}!={1'b0,saved_quantity})isolate();
                    else if(md_filled==0)state<=CANCEL_SEND;
                    else state<=FILL_SEND;
                end
            end
            FILL_SEND:if(lc_ready)state<=FILL_WAIT;
            FILL_WAIT:if(lr_valid)begin
                d_risk_status<=lr_status;
                if(lr_status!=0||lr_op!=2||!risk_identity||lr_remaining!=d_remaining)isolate();
                else begin capture_position();state<=(d_remaining==0)?DONE:CANCEL_SEND;end
            end
            CANCEL_SEND:if(lc_ready)state<=CANCEL_WAIT;
            CANCEL_WAIT:if(lr_valid)begin
                d_risk_status<=lr_status;
                if(lr_status!=0||lr_op!=3||!risk_identity||lr_remaining!=0)isolate();
                else begin capture_position();state<=DONE;end
            end
            INV_SEND:if(lc_ready)state<=INV_WAIT;
            INV_WAIT:if(lr_valid)state<=DONE;
            DONE:if(d_ready)state<=IDLE;
            default:isolate();
        endcase
    end
endmodule
`default_nettype wire
