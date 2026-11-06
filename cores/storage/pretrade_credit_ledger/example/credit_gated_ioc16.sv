// SPDX-License-Identifier: Apache-2.0
// Transient in-flight buy-notional holds; no settlement accounting or rollback.
`default_nettype none
module credit_gated_ioc16 (
    input wire clk,rst_n,
    // Serialized ledger management port, with the complete core operation set.
    input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [15:0] c_account,input wire [63:0] c_ticket,c_amount,c_limit,
    input wire [7:0] c_tag,
    output wire r_valid,input wire r_ready,output wire [2:0] r_op,
    output wire [3:0] r_status,output wire [15:0] r_account,
    output wire [63:0] r_ticket,r_amount,r_limit,r_used,r_available,
    output wire [31:0] r_live,output wire [7:0] r_tag,
    // Existing matcher maintenance port: SET/ADD/SUB/DELETE/BEST/DEPTH/clears.
    input wire q_valid,output wire q_ready,input wire [3:0] q_op,input wire q_side,
    input wire [31:0] q_price,q_quantity,q_rank,input wire [7:0] q_tag,
    output wire qr_valid,input wire qr_ready,output wire [3:0] qr_op,
    output wire qr_side,output wire [2:0] qr_status,output wire qr_found,
    output wire [31:0] qr_price,qr_quantity,qr_previous,qr_bid_levels,qr_ask_levels,
    output wire [7:0] qr_tag,
    // Buy limit IOC only. Price32 * quantity32 is a full unsigned64 amount.
    input wire i_valid,output wire i_ready,input wire [15:0] i_account,
    input wire [63:0] i_ticket,input wire [31:0] i_limit,i_quantity,input wire [7:0] i_tag,
    output wire f_valid,input wire f_ready,output wire f_buy,
    output wire [31:0] f_price,f_quantity,f_remaining,f_index,output wire [7:0] f_tag,
    output wire d_valid,input wire d_ready,output reg [1:0] d_stage,
    output reg [3:0] d_credit_status,output reg [2:0] d_reason,
    output reg [31:0] d_filled,d_remaining,d_fills,d_bid_levels,d_ask_levels,
    output reg [15:0] d_account,output reg [63:0] d_ticket,d_used,
    output reg [7:0] d_tag,output wire faulted
);
    localparam [3:0] IDLE=0,ADMIN=1,MAINT=2,RES_SEND=3,RES_WAIT=4,
        IOC_SEND=5,IOC_WAIT=6,REL_SEND=7,REL_WAIT=8,INV_SEND=9,INV_WAIT=10,DONE=11;
    reg [3:0] state;
    reg [15:0] saved_account;
    reg [63:0] saved_ticket,saved_amount;
    reg [31:0] saved_limit,saved_quantity;
    reg [7:0] saved_tag;
    wire lc_ready,lr_valid;
    wire [3:0] lr_status;
    wire [63:0] lr_used;
    wire ledger_busy;
    wire internal_command=(state==RES_SEND || state==REL_SEND || state==INV_SEND);
    wire [2:0] ledger_op=(state==IDLE)?c_op:(state==RES_SEND?3'd1:(state==REL_SEND?3'd2:3'd6));
    wire ledger_reply=(state==RES_WAIT || state==REL_WAIT || state==INV_WAIT);
    pretrade_credit_ledger ledger(
        .clk(clk),.rst_n(rst_n),.c_valid(rst_n&&((state==IDLE&&c_valid)||internal_command)),.c_ready(lc_ready),
        .c_op(ledger_op),.c_account(state==IDLE?c_account:saved_account),
        .c_ticket(state==IDLE?c_ticket:saved_ticket),.c_amount(state==IDLE?c_amount:saved_amount),
        .c_limit(c_limit),.c_tag(state==IDLE?c_tag:saved_tag),
        .r_valid(lr_valid),.r_ready((state==ADMIN&&r_ready)||ledger_reply),
        .r_op(r_op),.r_status(lr_status),.r_account(r_account),.r_ticket(r_ticket),
        .r_amount(r_amount),.r_limit(r_limit),.r_used(lr_used),.r_available(r_available),
        .r_live(r_live),.r_tag(r_tag),.busy(ledger_busy),.faulted(faulted));
    assign c_ready=rst_n&&state==IDLE&&lc_ready;
    assign r_valid=rst_n&&state==ADMIN&&lr_valid;
    assign r_status=lr_status;
    assign r_used=lr_used;
    wire mi_ready,mf_valid,md_valid;
    wire [2:0] md_reason;
    wire [31:0] md_filled,md_remaining,md_fills,md_bids,md_asks;
    wire [7:0] md_tag;
    wire mq_ready,mqr_valid;
    price_level_ioc_matcher matcher(
        .clk(clk),.rst_n(rst_n),.c_valid(rst_n&&state==IDLE&&!c_valid&&q_valid),.c_ready(mq_ready),
        .c_op(q_op),.c_side(q_side),.c_price(q_price),.c_quantity(q_quantity),.c_rank(q_rank),.c_tag(q_tag),
        .r_valid(mqr_valid),.r_ready(state==MAINT&&qr_ready),.r_op(qr_op),.r_side(qr_side),
        .r_status(qr_status),.r_found(qr_found),.r_price(qr_price),.r_quantity(qr_quantity),
        .r_previous(qr_previous),.r_bid_levels(qr_bid_levels),.r_ask_levels(qr_ask_levels),.r_tag(qr_tag),
        .i_valid(rst_n&&state==IOC_SEND),.i_ready(mi_ready),.i_buy(1'b1),.i_market(1'b0),
        .i_limit(saved_limit),.i_quantity(saved_quantity),.i_tag(saved_tag),
        .f_valid(mf_valid),.f_ready(state==IOC_WAIT&&f_ready),.f_buy(f_buy),.f_price(f_price),
        .f_quantity(f_quantity),.f_remaining(f_remaining),.f_index(f_index),.f_tag(f_tag),
        .d_valid(md_valid),.d_ready(state==IOC_WAIT),.d_reason(md_reason),
        .d_filled(md_filled),.d_remaining(md_remaining),.d_fills(md_fills),
        .d_bid_levels(md_bids),.d_ask_levels(md_asks),.d_tag(md_tag));
    assign q_ready=rst_n&&state==IDLE&&!c_valid&&mq_ready;
    assign qr_valid=rst_n&&state==MAINT&&mqr_valid;
    assign i_ready=rst_n&&state==IDLE&&!c_valid&&!q_valid&&lc_ready;
    assign f_valid=rst_n&&state==IOC_WAIT&&mf_valid;
    assign d_valid=rst_n&&state==DONE;
    wire [63:0] requested_notional=i_limit*i_quantity;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;saved_account<=0;saved_ticket<=0;saved_amount<=0;
            saved_limit<=0;saved_quantity<=0;saved_tag<=0;
            d_stage<=0;d_credit_status<=0;d_reason<=0;d_filled<=0;d_remaining<=0;d_fills<=0;
            d_bid_levels<=0;d_ask_levels<=0;d_account<=0;d_ticket<=0;d_used<=0;d_tag<=0;
        end else case(state)
            IDLE:if(c_valid&&c_ready)state<=ADMIN;
            else if(q_valid&&q_ready)state<=MAINT;
            else if(i_valid&&i_ready)begin
                saved_account<=i_account;saved_ticket<=i_ticket;saved_amount<=requested_notional;
                saved_limit<=i_limit;saved_quantity<=i_quantity;saved_tag<=i_tag;
                d_stage<=0;d_credit_status<=0;d_reason<=0;d_filled<=0;d_remaining<=i_quantity;d_fills<=0;
                d_bid_levels<=0;d_ask_levels<=0;d_account<=i_account;d_ticket<=i_ticket;d_used<=0;d_tag<=i_tag;
                state<=RES_SEND;
            end
            ADMIN:if(lr_valid&&r_ready)state<=IDLE;
            MAINT:if(mqr_valid&&qr_ready)state<=IDLE;
            RES_SEND:if(lc_ready)state<=RES_WAIT;
            RES_WAIT:if(lr_valid)begin
                d_credit_status<=lr_status;
                if(lr_status==0)state<=IOC_SEND;
                else begin d_stage<=(lr_status==11)?2'd2:2'd1;state<=DONE;end
            end
            IOC_SEND:if(mi_ready)state<=IOC_WAIT;
            IOC_WAIT:if(md_valid)begin
                d_reason<=md_reason;d_filled<=md_filled;d_remaining<=md_remaining;d_fills<=md_fills;
                d_bid_levels<=md_bids;d_ask_levels<=md_asks;
                if(md_reason==4)begin d_stage<=2;state<=INV_SEND;end
                else state<=REL_SEND;
            end
            REL_SEND:if(lc_ready)state<=REL_WAIT;
            REL_WAIT:if(lr_valid)begin
                d_credit_status<=lr_status;d_used<=lr_used;
                if(lr_status==0)state<=DONE;
                else begin d_stage<=2;state<=INV_SEND;end
            end
            INV_SEND:if(lc_ready)state<=INV_WAIT;
            INV_WAIT:if(lr_valid)state<=DONE;
            DONE:if(d_ready)state<=IDLE;
            default:begin d_stage<=2;state<=INV_SEND;end
        endcase
    end
endmodule
`default_nettype wire
