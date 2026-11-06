// SPDX-License-Identifier: Apache-2.0
`default_nettype none
// Venue-confirmed lifecycle around the unchanged directional position ledger.
module order_risk_reservation #(
    parameter integer CONTEXTS=4, ORDERS=8, TAG_W=8
)(
    input wire clk,rst_n,
    input wire c_valid,output wire c_ready,input wire [3:0] c_op,
    input wire [31:0] c_context,input wire [111:0] c_token,
    input wire c_buy,input wire [31:0] c_quantity,
    input wire signed [63:0] c_position,c_min_position,c_max_position,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,
    output reg [3:0] r_op,output reg [4:0] r_status,
    output reg [111:0] r_token,output reg [31:0] r_context,
    output reg r_buy,output reg [31:0] r_remaining,output reg [1:0] r_phase,
    output reg signed [63:0] r_position,r_min_position,r_max_position,
    output reg [37:0] r_buy_open,r_sell_open,output reg [31:0] r_live,
    output reg [TAG_W-1:0] r_tag,output wire busy,faulted
);
    localparam integer K=(ORDERS>=1&&ORDERS<=32)?ORDERS:1;
    localparam integer W=(K>1)?$clog2(K):1,CW=$clog2(K+1);
    localparam [3:0] CONFIG=0,NEW_ORDER=1,ACK=2,REJECT=3,CANCEL_REQUEST=4,
        CANCEL_ACK=5,CANCEL_REJECT=6,FILL=7,GET_ORDER=8,GET_CONTEXT=9,CLEAR=10,INVALIDATE=11;
    localparam [4:0] OK=0,DUPLICATE=4,FULL=6,NOT_FOUND=7,INVALID_STATE=9,
        BAD_STATE=13,BAD_OP=14,INTERNAL=15,BAD_QUANTITY=3,EXCESS=12;
    localparam [2:0] IDLE=0,SCAN=1,DECIDE=2,SEND=3,WAIT_REPLY=4,RESPONSE=5;
    localparam [1:0] PENDING_NEW=1,LIVE=2,PENDING_CANCEL=3;
    generate if(CONTEXTS<1||CONTEXTS>16||ORDERS<1||ORDERS>32||TAG_W<1||TAG_W>32)begin:invalid
        order_risk_reservation_invalid_parameters__see_README rejected();
    end endgenerate
    reg [2:0] state;
    reg [K-1:0] occupied;
    reg [111:0] tokens[0:K-1];
    reg [31:0] quantities[0:K-1],contexts[0:K-1];
    reg directions[0:K-1];
    reg [1:0] phases[0:K-1];
    reg [CW-1:0] count;
    reg [W-1:0] cursor,slot,free_slot;
    reg free_seen,found,isolate,own_fault,second;
    reg [3:0] op;
    reg [111:0] token;
    reg [31:0] context_id,quantity,saved_quantity;
    reg buy,offered_buy;
    reg [1:0] saved_phase;
    reg signed [63:0] position_in,min_in,max_in;
    reg [2:0] private_op;
    wire pc_ready,pr_valid,ledger_fault;
    wire [2:0] pr_op;
    wire [3:0] pr_status;
    wire [31:0] pr_context,pr_remaining,pr_live;
    wire [63:0] pr_ticket;
    wire pr_buy;
    wire signed [63:0] pr_position,pr_min,pr_max;
    wire [37:0] pr_buy_open,pr_sell_open;
    wire [TAG_W-1:0] pr_tag;
    wire [63:0] private_ticket={{(64-W){1'b0}},slot};
    wire [31:0] private_quantity=(op==CANCEL_ACK&&second)?saved_quantity-quantity:quantity;
    position_limit_reservations #(.CONTEXTS(CONTEXTS),.TICKETS(K),.TAG_W(TAG_W)) ledger(
        .clk(clk),.rst_n(rst_n),.c_valid(rst_n&&state==SEND),.c_ready(pc_ready),.c_op(private_op),
        .c_context(context_id),.c_ticket(private_ticket),.c_buy(buy),.c_quantity(private_quantity),
        .c_position(position_in),.c_min_position(min_in),.c_max_position(max_in),.c_tag(r_tag),
        .r_valid(pr_valid),.r_ready(state==WAIT_REPLY),.r_op(pr_op),.r_status(pr_status),
        .r_context(pr_context),.r_ticket(pr_ticket),.r_buy(pr_buy),.r_remaining(pr_remaining),
        .r_position(pr_position),.r_min_position(pr_min),.r_max_position(pr_max),
        .r_buy_open(pr_buy_open),.r_sell_open(pr_sell_open),.r_live(pr_live),.r_tag(pr_tag),
        .busy(),.faulted(ledger_fault));
    assign c_ready=rst_n&&state==IDLE;
    assign r_valid=rst_n&&state==RESPONSE;
    assign busy=rst_n&&state!=IDLE;
    assign faulted=rst_n&&(own_fault||ledger_fault);
    task reject(input [4:0] status);
        begin r_status<=status;state<=RESPONSE;end
    endtask
    task isolation;
        begin own_fault<=1;isolate<=1;private_op<=7;state<=SEND;end
    endtask
    task snapshot;
        begin r_context<=pr_context;r_position<=pr_position;r_min_position<=pr_min;
            r_max_position<=pr_max;r_buy_open<=pr_buy_open;r_sell_open<=pr_sell_open;
        end
    endtask
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;occupied<=0;count<=0;own_fault<=0;
            cursor<=0;slot<=0;free_slot<=0;free_seen<=0;found<=0;isolate<=0;second<=0;
            op<=0;token<=0;context_id<=0;quantity<=0;saved_quantity<=0;buy<=0;offered_buy<=0;saved_phase<=0;
            position_in<=0;min_in<=0;max_in<=0;private_op<=0;
            r_op<=0;r_status<=0;r_token<=0;r_context<=0;r_buy<=0;r_remaining<=0;r_phase<=0;
            r_position<=0;r_min_position<=0;r_max_position<=0;r_buy_open<=0;r_sell_open<=0;r_live<=0;r_tag<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                op<=c_op;token<=c_token;context_id<=c_context;quantity<=c_quantity;buy<=c_buy;offered_buy<=c_buy;
                position_in<=c_position;min_in<=c_min_position;max_in<=c_max_position;
                cursor<=0;free_slot<=0;slot<=0;free_seen<=0;found<=0;isolate<=0;second<=0;
                saved_quantity<=0;saved_phase<=0;
                r_op<=c_op;r_tag<=c_tag;r_token<=c_token;r_status<=OK;r_live<=count;
                r_context<=0;r_buy<=0;r_remaining<=0;r_phase<=0;r_position<=0;
                r_min_position<=0;r_max_position<=0;r_buy_open<=0;r_sell_open<=0;
                if(c_op==CLEAR||c_op==INVALIDATE)begin private_op<=(c_op==CLEAR)?6:7;state<=SEND;end
                else if(faulted)reject(INVALID_STATE);
                else if(c_op>INVALIDATE)reject(BAD_OP);
                else if(c_op==CONFIG||c_op==GET_CONTEXT)begin private_op<=(c_op==CONFIG)?0:4;state<=SEND;end
                else state<=SCAN;
            end
            SCAN:begin
                if(occupied[cursor]&&tokens[cursor]==token)begin
                    found<=1;slot<=cursor;context_id<=contexts[cursor];buy<=directions[cursor];
                    saved_quantity<=quantities[cursor];saved_phase<=phases[cursor];state<=DECIDE;
                end else begin
                    if(!occupied[cursor]&&!free_seen)begin free_slot<=cursor;free_seen<=1;end
                    if(cursor==K-1)state<=DECIDE;else cursor<=cursor+1'b1;
                end
            end
            DECIDE:begin
                if(op==NEW_ORDER)begin
                    if(found)reject(DUPLICATE);
                    else if(!free_seen)reject(FULL);
                    else begin slot<=free_slot;private_op<=1;state<=SEND;end
                end else if(!found)reject(NOT_FOUND);
                else if(op==ACK&&(saved_phase!=PENDING_NEW||quantity!=saved_quantity||offered_buy!=buy))reject(BAD_STATE);
                else if(op==REJECT&&saved_phase!=PENDING_NEW)reject(BAD_STATE);
                else if(op==CANCEL_REQUEST&&saved_phase!=LIVE)reject(BAD_STATE);
                else if(op==CANCEL_REJECT&&saved_phase!=PENDING_CANCEL)reject(BAD_STATE);
                else if((op==FILL||op==CANCEL_ACK)&&saved_phase==PENDING_NEW)reject(BAD_STATE);
                else if((op==FILL||op==CANCEL_ACK)&&quantity==0)reject(BAD_QUANTITY);
                else if((op==FILL||op==CANCEL_ACK)&&quantity>saved_quantity)reject(EXCESS);
                else begin
                    private_op<=(op==FILL)?2:((op==REJECT||op==CANCEL_ACK)?3:5);state<=SEND;
                end
            end
            SEND:if(pc_ready)state<=WAIT_REPLY;
            WAIT_REPLY:if(pr_valid)begin
                if(isolate)begin r_status<=INTERNAL;state<=RESPONSE;end
                else if(pr_op!=private_op||pr_tag!=r_tag) isolation();
                else if(pr_status!=0)begin
                    if(op==NEW_ORDER||op==CONFIG||op==GET_CONTEXT)begin
                        r_status<={1'b0,pr_status};state<=RESPONSE;
                        if(ledger_fault)own_fault<=1;
                    end else isolation();
                end else if(op==CLEAR)begin occupied<=0;count<=0;r_live<=0;own_fault<=0;state<=RESPONSE;end
                else if(op==INVALIDATE)begin own_fault<=1;state<=RESPONSE;end
                else if(op==CONFIG||op==GET_CONTEXT)begin snapshot();state<=RESPONSE;end
                else if(pr_ticket!=private_ticket||pr_context!=context_id||pr_buy!=buy) isolation();
                else if(op==CANCEL_ACK&&!second&&saved_quantity>quantity)begin
                    // One owner spans release/re-reserve. The smaller hold must fit.
                    if(pr_remaining!=0||pr_live!=count-1'b1) isolation();
                    else begin private_op<=1;second<=1;state<=SEND;end
                end else begin
                    if((op==NEW_ORDER&&pr_remaining!=quantity)||
                       ((op==ACK||op==CANCEL_REQUEST||op==CANCEL_REJECT||op==GET_ORDER)&&pr_remaining!=saved_quantity)||
                       ((op==REJECT||(op==CANCEL_ACK&&!second))&&pr_remaining!=0)||
                       ((op==FILL||(op==CANCEL_ACK&&second))&&pr_remaining!=saved_quantity-quantity)||
                       pr_live!=((op==NEW_ORDER)?count+1'b1:((pr_remaining==0)?count-1'b1:count))) isolation();
                    else begin
                        snapshot();r_buy<=buy;r_remaining<=pr_remaining;state<=RESPONSE;
                        if(op==NEW_ORDER)begin
                            occupied[slot]<=1;tokens[slot]<=token;contexts[slot]<=context_id;
                            directions[slot]<=buy;quantities[slot]<=quantity;phases[slot]<=PENDING_NEW;
                            count<=count+1'b1;r_live<=count+1'b1;r_phase<=PENDING_NEW;
                        end else if(pr_remaining==0)begin
                            occupied[slot]<=0;count<=count-1'b1;r_live<=count-1'b1;r_phase<=0;
                        end else begin
                            quantities[slot]<=pr_remaining;
                            if(op==ACK||op==CANCEL_REJECT||op==CANCEL_ACK)begin phases[slot]<=LIVE;r_phase<=LIVE;end
                            else if(op==CANCEL_REQUEST)begin phases[slot]<=PENDING_CANCEL;r_phase<=PENDING_CANCEL;end
                            else r_phase<=saved_phase;
                        end
                    end
                end
            end
            RESPONSE:if(r_ready)state<=IDLE;
            default:isolation();
        endcase
    end
endmodule
`default_nettype wire
