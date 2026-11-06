// SPDX-License-Identifier: Apache-2.0
// Actual two unchanged L2 books -> epoch/sequence guarded consolidated quotes.
`default_nettype none
module dual_venue_l2_quote #(
    parameter integer TAG_W=8
)(
    input wire clk,rst,input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_venue,input wire [63:0] c_epoch,c_sequence,
    input wire c_remove_valid,c_remove_sell,input wire [31:0] c_remove_price,c_remove_quantity,
    input wire c_add_valid,c_add_sell,input wire [31:0] c_add_price,c_add_quantity,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output reg [2:0] r_op,
    output reg [31:0] r_venue,output reg [63:0] r_epoch,r_sequence,output reg [TAG_W-1:0] r_tag,
    output reg [3:0] r_quote_status,r_l2_status,r_isolation_status,
    output reg r_l2_touched,r_disabled,r_quote_valid,r_bid_valid,r_ask_valid,
    output reg [31:0] r_bid_price,r_ask_price,output reg [40:0] r_bid_quantity,r_ask_quantity,
    output reg [7:0] r_bid_sources,r_ask_sources,output wire r_locked,r_crossed,output wire busy
);
    localparam [2:0] IDLE=0,CORE_SEND=1,CORE_WAIT=2,L2_SEND=3,L2_WAIT=4,OUTPUT=5;
    localparam [2:0] CONFIG=0,DISABLE=1,PROBE=2,UPDATE=3,ISOLATE=4,QUERY=5;
    reg [2:0] state,phase;
    reg selected,remove_valid,remove_sell,add_valid,add_sell;
    reg [31:0] remove_price,remove_quantity,add_price,add_quantity;
    reg quote_bid,quote_ask;reg [31:0] quote_bp,quote_ap;reg [37:0] quote_bq,quote_aq;
    wire qr,qv,q_has,q_quote,q_bid,q_ask;
    wire [3:0] qs;
    wire [31:0] qbp,qap;
    wire [40:0] qbq,qaq;
    wire [7:0] qbs,qas;
    wire [3:0] core_op=phase==CONFIG?0:phase==DISABLE||phase==ISOLATE?1:phase==PROBE?2:phase==UPDATE?3:4;
    wire [1:0] lr,lv;
    wire [3:0] ls[0:1];
    wire lb[0:1],la[0:1];
    wire [31:0] lbp[0:1],lap[0:1];
    wire [37:0] lbq[0:1],laq[0:1];
    assign c_ready=!rst&&state==IDLE;
    assign r_valid=!rst&&state==OUTPUT;
    assign busy=!rst&&state!=IDLE;
    assign r_locked=r_quote_valid&&r_bid_valid&&r_ask_valid&&r_bid_price==r_ask_price;
    assign r_crossed=r_quote_valid&&r_bid_valid&&r_ask_valid&&r_bid_price>r_ask_price;
    multi_venue_quote_state #(.SYMBOLS(1),.VENUES(2),.TAG_W(TAG_W)) quotes(
        .clk(clk),.rst(rst),.c_valid(state==CORE_SEND),.c_ready(qr),.c_op(core_op),.c_symbol(32'd0),
        .c_venue(r_venue),.c_epoch(r_epoch),.c_sequence(r_sequence),.c_bid_valid(quote_bid),.c_ask_valid(quote_ask),
        .c_bid_price(quote_bp),.c_ask_price(quote_ap),.c_bid_quantity(quote_bq),.c_ask_quantity(quote_aq),.c_tag(r_tag),
        .r_valid(qv),.r_ready(state==CORE_WAIT),.r_op(),.r_status(qs),.r_symbol(),.r_venue(),.r_epoch(),.r_sequence(),
        .r_has_previous(q_has),.r_previous_sequence(),.r_quote_valid(q_quote),.r_bid_valid(q_bid),.r_ask_valid(q_ask),
        .r_bid_price(qbp),.r_ask_price(qap),.r_bid_quantity(qbq),.r_ask_quantity(qaq),.r_bid_sources(qbs),.r_ask_sources(qas),
        .r_locked(),.r_crossed(),.r_tag(),.busy());
    genvar g;
    generate for(g=0;g<2;g=g+1)begin:venue
        itch_l2_delta_book #(.LEVELS(8),.TAG_W(TAG_W)) book(
            .clk(clk),.rst(rst),.c_valid(state==L2_SEND&&selected==g),.c_ready(lr[g]),.c_op(phase==CONFIG?3'd3:3'd0),
            .c_remove_valid(remove_valid),.c_remove_sell(remove_sell),.c_remove_price(remove_price),.c_remove_quantity(remove_quantity),
            .c_add_valid(add_valid),.c_add_sell(add_sell),.c_add_price(add_price),.c_add_quantity(add_quantity),.c_sequence(r_sequence),.c_tag(r_tag),
            .r_valid(lv[g]),.r_ready(state==L2_WAIT&&selected==g),.r_op(),.r_status(ls[g]),.r_sequence(),.r_tag(),.r_found(),.r_quantity(),
            .r_remove_before(),.r_remove_after(),.r_add_before(),.r_add_after(),
            .r_bid_valid(lb[g]),.r_bid_price(lbp[g]),.r_bid_quantity(lbq[g]),.r_ask_valid(la[g]),.r_ask_price(lap[g]),.r_ask_quantity(laq[g]),
            .r_bid_changed(),.r_ask_changed(),.r_bid_levels(),.r_ask_levels(),.r_crossed(),.faulted(),.busy());
    end endgenerate
    task clear_result;
        begin r_quote_status<=0;r_l2_status<=0;r_isolation_status<=0;r_l2_touched<=0;r_disabled<=0;
            r_quote_valid<=0;r_bid_valid<=0;r_ask_valid<=0;r_bid_price<=0;r_ask_price<=0;
            r_bid_quantity<=0;r_ask_quantity<=0;r_bid_sources<=0;r_ask_sources<=0;end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;phase<=0;selected<=0;remove_valid<=0;remove_sell<=0;add_valid<=0;add_sell<=0;
            remove_price<=0;remove_quantity<=0;add_price<=0;add_quantity<=0;
            quote_bid<=0;quote_ask<=0;quote_bp<=0;quote_ap<=0;quote_bq<=0;quote_aq<=0;
            r_op<=0;r_venue<=0;r_epoch<=0;r_sequence<=0;r_tag<=0;clear_result();
        end else case(state)
            IDLE:if(c_valid)begin
                r_op<=c_op;r_venue<=c_venue;r_epoch<=c_epoch;r_sequence<=c_sequence;r_tag<=c_tag;clear_result();
                selected<=c_venue[0];remove_valid<=c_remove_valid;remove_sell<=c_remove_sell;
                remove_price<=c_remove_price;remove_quantity<=c_remove_quantity;
                add_valid<=c_add_valid;add_sell<=c_add_sell;add_price<=c_add_price;add_quantity<=c_add_quantity;
                if(c_op>3)begin r_quote_status<=9;state<=OUTPUT;end
                else begin phase<=c_op==0?CONFIG:c_op==1?DISABLE:c_op==2?PROBE:QUERY;state<=CORE_SEND;end
            end
            CORE_SEND:if(qr)state<=CORE_WAIT;
            CORE_WAIT:if(qv)begin
                if(phase==ISOLATE)begin r_isolation_status<=qs;r_disabled<=qs==0;state<=OUTPUT;end
                else begin
                    r_quote_status<=qs;
                    if(phase==CONFIG&&qs==0)state<=L2_SEND;
                    else if(phase==PROBE&&qs==0)state<=L2_SEND;
                    else if(phase==UPDATE&&qs!=0)begin phase<=ISOLATE;state<=CORE_SEND;end
                    else begin
                        r_quote_valid<=q_quote;r_bid_valid<=q_bid;r_ask_valid<=q_ask;r_bid_price<=qbp;r_ask_price<=qap;
                        r_bid_quantity<=qbq;r_ask_quantity<=qaq;r_bid_sources<=qbs;r_ask_sources<=qas;
                        if(phase==DISABLE&&qs==0)r_disabled<=1;
                        state<=OUTPUT;
                    end
                end
            end
            L2_SEND:if(lr[selected])begin r_l2_touched<=1;state<=L2_WAIT;end
            L2_WAIT:if(lv[selected])begin
                r_l2_status<=ls[selected];
                if(ls[selected]!=0)begin phase<=ISOLATE;state<=CORE_SEND;end
                else if(phase==CONFIG)state<=OUTPUT;
                else begin
                    quote_bid<=lb[selected];quote_ask<=la[selected];quote_bp<=lbp[selected];quote_ap<=lap[selected];
                    quote_bq<=lbq[selected];quote_aq<=laq[selected];phase<=UPDATE;state<=CORE_SEND;
                end
            end
            OUTPUT:if(r_ready)state<=IDLE;
            default:begin r_quote_status<=8;state<=OUTPUT;end
        endcase
    end
endmodule
`default_nettype wire
