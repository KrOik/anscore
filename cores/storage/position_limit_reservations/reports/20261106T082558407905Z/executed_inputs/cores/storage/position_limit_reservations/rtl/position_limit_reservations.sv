// SPDX-License-Identifier: Apache-2.0
// Original signed-position service. Opposing unfilled reservations never net.
`default_nettype none
module position_limit_reservations #(
    parameter integer CONTEXTS=8, TICKETS=32, TAG_W=8
) (
    input wire clk,rst_n,
    input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_context,input wire [63:0] c_ticket,
    input wire c_buy,input wire [31:0] c_quantity,
    input wire signed [63:0] c_position,c_min_position,c_max_position,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,
    output reg [2:0] r_op,output reg [3:0] r_status,
    output reg [31:0] r_context,output reg [63:0] r_ticket,
    output reg r_buy,output reg [31:0] r_remaining,
    output reg signed [63:0] r_position,r_min_position,r_max_position,
    output reg [37:0] r_buy_open,r_sell_open,
    output reg [31:0] r_live,output reg [TAG_W-1:0] r_tag,
    output wire busy,output reg faulted
);
    localparam integer A=(CONTEXTS>=1&&CONTEXTS<=16)?CONTEXTS:1;
    localparam integer K=(TICKETS>=1&&TICKETS<=64)?TICKETS:1;
    localparam integer AW=(A>1)?$clog2(A):1,KW=(K>1)?$clog2(K):1,CW=$clog2(K+1);
    localparam [2:0] CONFIG=0,RESERVE=1,FILL=2,CANCEL=3,GET_CONTEXT=4,GET_TICKET=5,CLEAR=6,INVALIDATE=7;
    localparam [3:0] OK=0,BAD_CONTEXT=1,NOT_CONFIGURED=2,BAD_QUANTITY=3,DUPLICATE=4,
        LIMIT_EXCEEDED=5,FULL=6,NOT_FOUND=7,BAD_LIMITS=8,INVALID_STATE=9,
        OPEN_RESERVATIONS=10,BACKEND_FAULT=11,EXCESS_FILL=12;
    localparam [3:0] IDLE=0,A_READ=1,A_WAIT=2,SCAN=3,T_WAIT=4,SCAN_END=5,
        T_WRITE=6,T_WRITE_WAIT=7,A_WRITE=8,A_WRITE_WAIT=9,RESPONSE=10;
    generate if(CONTEXTS<1||CONTEXTS>16||TICKETS<1||TICKETS>64||TAG_W<1||TAG_W>32)begin:invalid
        position_limit_reservations_invalid_parameters__see_README rejected();
    end endgenerate
    reg [3:0] state;
    reg [A-1:0] configured;
    reg [K-1:0] live;
    reg [CW-1:0] count;
    reg [2:0] op;
    reg [31:0] context_id,quantity,remaining,next_remaining;
    reg [63:0] ticket;
    reg buy;
    reg signed [63:0] old_position,old_min,old_max,next_position,next_min,next_max;
    reg [37:0] old_buy,old_sell,next_buy,next_sell;
    reg [KW-1:0] cursor,free_slot,found_slot;
    reg free_seen;
    wire ar_ready,ar_valid,ar_error,tr_ready,tr_valid,tr_error;
    wire [271:0] ar_data;
    wire [103:0] tr_data;
    wire signed [63:0] rd_position=ar_data[267:204],rd_min=ar_data[203:140],rd_max=ar_data[139:76];
    wire [37:0] rd_buy=ar_data[75:38],rd_sell=ar_data[37:0];
    wire [3:0] stored_context=tr_data[100:97];
    wire stored_buy=tr_data[96];
    wire [31:0] stored_remaining=tr_data[95:64];
    wire signed [64:0] rd_p65={rd_position[63],rd_position};
    wire signed [64:0] rd_lo65={rd_min[63],rd_min},rd_hi65={rd_max[63],rd_max};
    wire signed [64:0] rd_upper=rd_p65+$signed({27'd0,rd_buy});
    wire signed [64:0] rd_lower=rd_p65-$signed({27'd0,rd_sell});
    wire signed [64:0] filled_position=buy?(rd_p65+$signed({33'd0,quantity})):
        (rd_p65-$signed({33'd0,quantity}));
    // The pre-capacity candidate can contain a 65th quantity, hence 39 bits.
    wire [38:0] candidate_buy={1'b0,old_buy}+(buy?{7'd0,quantity}:39'd0);
    wire [38:0] candidate_sell={1'b0,old_sell}+(buy?39'd0:{7'd0,quantity});
    wire signed [64:0] old_p65={old_position[63],old_position};
    wire signed [64:0] candidate_upper=old_p65+$signed({26'd0,candidate_buy});
    wire signed [64:0] candidate_lower=old_p65-$signed({26'd0,candidate_sell});
    wire account_request=(state==A_READ||state==A_WRITE);
    wire ticket_read=(state==SCAN&&live[cursor]);
    wire ticket_request=ticket_read||state==T_WRITE;
    wire [271:0] account_write={4'd0,next_position,next_min,next_max,next_buy,next_sell};
    wire [103:0] ticket_write={3'd0,context_id[3:0],buy,next_remaining,ticket};
    wire [KW-1:0] ticket_address=(state==T_WRITE)?((op==RESERVE)?free_slot:found_slot):cursor;
    cip_sync_sp_ram #(.DATA_WIDTH(272),.ADDR_WIDTH(AW),.DEPTH(A)) context_ram(
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.req_valid(rst_n&&account_request),.req_ready(ar_ready),
        .req_write(state==A_WRITE),.req_addr(context_id[AW-1:0]),.req_wdata(account_write),.req_wstrb(34'h3ffffffff),
        .rsp_valid(ar_valid),.rsp_ready(state==A_WAIT||state==A_WRITE_WAIT),.rsp_rdata(ar_data),.rsp_error(ar_error));
    cip_sync_sp_ram #(.DATA_WIDTH(104),.ADDR_WIDTH(KW),.DEPTH(K)) ticket_ram(
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.req_valid(rst_n&&ticket_request),.req_ready(tr_ready),
        .req_write(state==T_WRITE),.req_addr(ticket_address),.req_wdata(ticket_write),.req_wstrb(13'h1fff),
        .rsp_valid(tr_valid),.rsp_ready(state==T_WAIT||state==T_WRITE_WAIT),.rsp_rdata(tr_data),.rsp_error(tr_error));
    assign c_ready=rst_n&&state==IDLE;
    assign r_valid=rst_n&&state==RESPONSE;
    assign busy=rst_n&&state!=IDLE;
    task backend_fault;
        begin r_status<=BACKEND_FAULT;faulted<=1;state<=RESPONSE;end
    endtask
    task advance_scan;
        begin if(cursor==K-1)state<=SCAN_END;else begin cursor<=cursor+1'b1;state<=SCAN;end end
    endtask
    task context_result(input signed [63:0] p,lo,hi,input [37:0] b,s);
        begin r_context<=context_id;r_position<=p;r_min_position<=lo;r_max_position<=hi;r_buy_open<=b;r_sell_open<=s;end
    endtask
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;configured<=0;live<=0;count<=0;faulted<=0;
            op<=0;context_id<=0;ticket<=0;buy<=0;quantity<=0;remaining<=0;next_remaining<=0;
            old_position<=0;old_min<=0;old_max<=0;old_buy<=0;old_sell<=0;
            next_position<=0;next_min<=0;next_max<=0;next_buy<=0;next_sell<=0;
            cursor<=0;free_slot<=0;found_slot<=0;free_seen<=0;
            r_op<=0;r_status<=0;r_context<=0;r_ticket<=0;r_buy<=0;r_remaining<=0;
            r_position<=0;r_min_position<=0;r_max_position<=0;r_buy_open<=0;r_sell_open<=0;r_live<=0;r_tag<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                op<=c_op;context_id<=c_context;ticket<=c_ticket;buy<=c_buy;quantity<=c_quantity;
                next_position<=c_position;next_min<=c_min_position;next_max<=c_max_position;next_buy<=0;next_sell<=0;
                remaining<=0;next_remaining<=c_quantity;cursor<=0;free_seen<=0;free_slot<=0;found_slot<=0;
                r_op<=c_op;r_status<=OK;r_tag<=c_tag;r_context<=0;r_ticket<=0;r_buy<=0;r_remaining<=0;
                r_position<=0;r_min_position<=0;r_max_position<=0;r_buy_open<=0;r_sell_open<=0;r_live<=count;
                if(c_op==CLEAR)begin configured<=0;live<=0;count<=0;faulted<=0;r_live<=0;state<=RESPONSE;end
                else if(c_op==INVALIDATE)begin faulted<=1;state<=RESPONSE;end
                else if(faulted)begin r_status<=INVALID_STATE;state<=RESPONSE;end
                else if(c_op==FILL&&c_quantity==0)begin r_status<=BAD_QUANTITY;state<=RESPONSE;end
                else if(c_op==FILL||c_op==CANCEL||c_op==GET_TICKET)state<=SCAN;
                else if(c_context>=A)begin r_status<=BAD_CONTEXT;state<=RESPONSE;end
                else if(c_op==RESERVE&&c_quantity==0)begin r_status<=BAD_QUANTITY;state<=RESPONSE;end
                else if(c_op==CONFIG&&(c_min_position>c_position||c_position>c_max_position))begin r_status<=BAD_LIMITS;state<=RESPONSE;end
                else if(!configured[c_context])begin
                    if(c_op==CONFIG)state<=A_WRITE;
                    else begin r_status<=NOT_CONFIGURED;state<=RESPONSE;end
                end else state<=A_READ;
            end
            A_READ:if(ar_ready)state<=A_WAIT;
            A_WAIT:if(ar_valid)begin
                if(ar_error||ar_data[271:268]!=0||rd_min>rd_position||rd_position>rd_max||rd_upper>rd_hi65||rd_lower<rd_lo65)backend_fault();
                else begin
                    old_position<=rd_position;old_min<=rd_min;old_max<=rd_max;old_buy<=rd_buy;old_sell<=rd_sell;
                    if(op==CONFIG)begin
                        if(rd_buy!=0||rd_sell!=0)begin r_status<=OPEN_RESERVATIONS;state<=RESPONSE;end
                        else state<=A_WRITE;
                    end else if(op==GET_CONTEXT)begin context_result(rd_position,rd_min,rd_max,rd_buy,rd_sell);state<=RESPONSE;end
                    else if(op==RESERVE)state<=SCAN;
                    else if((buy&&rd_buy<{6'd0,remaining})||(!buy&&rd_sell<{6'd0,remaining})||count==0)backend_fault();
                    else if(op==GET_TICKET)begin
                        context_result(rd_position,rd_min,rd_max,rd_buy,rd_sell);r_ticket<=ticket;r_buy<=buy;r_remaining<=remaining;state<=RESPONSE;
                    end else if(op==FILL&&quantity>remaining)begin r_status<=EXCESS_FILL;state<=RESPONSE;end
                    else begin
                        next_min<=rd_min;next_max<=rd_max;
                        if(op==FILL)begin
                            // Exact 65-bit value must fit signed64 before committing.
                            if(filled_position[64]!=filled_position[63])backend_fault();
                            else begin
                                next_position<=filled_position[63:0];next_remaining<=remaining-quantity;
                                next_buy<=buy?(rd_buy-{6'd0,quantity}):rd_buy;
                                next_sell<=buy?rd_sell:(rd_sell-{6'd0,quantity});
                                state<=(quantity==remaining)?A_WRITE:T_WRITE;
                            end
                        end else begin
                            next_position<=rd_position;next_remaining<=0;
                            next_buy<=buy?(rd_buy-{6'd0,remaining}):rd_buy;
                            next_sell<=buy?rd_sell:(rd_sell-{6'd0,remaining});state<=A_WRITE;
                        end
                    end
                end
            end
            SCAN:begin
                if(live[cursor])begin if(tr_ready)state<=T_WAIT;end
                else begin if(!free_seen)begin free_seen<=1;free_slot<=cursor;end advance_scan();end
            end
            T_WAIT:if(tr_valid)begin
                if(tr_error||tr_data[103:101]!=0||stored_context>=A||stored_remaining==0)backend_fault();
                else if(!configured[stored_context])backend_fault();
                else if(tr_data[63:0]==ticket)begin
                    if(op==RESERVE)begin r_status<=DUPLICATE;state<=RESPONSE;end
                    else begin context_id<={28'd0,stored_context};buy<=stored_buy;remaining<=stored_remaining;found_slot<=cursor;state<=A_READ;end
                end else advance_scan();
            end
            SCAN_END:begin
                if(op!=RESERVE)begin r_status<=NOT_FOUND;state<=RESPONSE;end
                else if(candidate_upper>$signed({old_max[63],old_max})||candidate_lower<$signed({old_min[63],old_min}))begin r_status<=LIMIT_EXCEEDED;state<=RESPONSE;end
                else if(!free_seen)begin r_status<=FULL;state<=RESPONSE;end
                else if(candidate_buy[38]||candidate_sell[38])backend_fault();
                else begin
                    next_position<=old_position;next_min<=old_min;next_max<=old_max;
                    next_buy<=candidate_buy[37:0];next_sell<=candidate_sell[37:0];next_remaining<=quantity;state<=T_WRITE;
                end
            end
            T_WRITE:if(tr_ready)state<=T_WRITE_WAIT;
            T_WRITE_WAIT:if(tr_valid)begin if(tr_error)backend_fault();else state<=A_WRITE;end
            A_WRITE:if(ar_ready)state<=A_WRITE_WAIT;
            A_WRITE_WAIT:if(ar_valid)begin
                if(ar_error)backend_fault();
                else begin
                    context_result(next_position,next_min,next_max,next_buy,next_sell);
                    if(op==CONFIG)configured[context_id]<=1;
                    else begin
                        r_ticket<=ticket;r_buy<=buy;r_remaining<=next_remaining;
                        if(op==RESERVE)begin live[free_slot]<=1;count<=count+1'b1;r_live<=count+1'b1;end
                        else if(next_remaining==0)begin live[found_slot]<=0;count<=count-1'b1;r_live<=count-1'b1;end
                    end
                    state<=RESPONSE;
                end
            end
            RESPONSE:if(r_ready)state<=IDLE;
            default:backend_fault();
        endcase
    end
endmodule
`default_nettype wire
