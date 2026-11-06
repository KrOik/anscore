// SPDX-License-Identifier: Apache-2.0
// Original bounded account/ticket hold ledger. Amounts are exact unsigned64.
`default_nettype none
module pretrade_credit_ledger #(
    parameter integer ACCOUNTS=16, TICKETS=32, TAG_W=8
) (
    input wire clk, input wire rst_n,
    input wire c_valid, output wire c_ready,
    input wire [2:0] c_op,
    input wire [15:0] c_account,
    input wire [63:0] c_ticket, c_amount, c_limit,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid, input wire r_ready,
    output reg [2:0] r_op, output reg [3:0] r_status,
    output reg [15:0] r_account,
    output reg [63:0] r_ticket, r_amount, r_limit, r_used, r_available,
    output reg [31:0] r_live,
    output reg [TAG_W-1:0] r_tag,
    output wire busy, output reg faulted
);
    localparam integer A=(ACCOUNTS>=1 && ACCOUNTS<=16)?ACCOUNTS:1;
    localparam integer K=(TICKETS>=1 && TICKETS<=64)?TICKETS:1;
    localparam integer AW=(A>1)?$clog2(A):1;
    localparam integer KW=(K>1)?$clog2(K):1;
    localparam integer CW=$clog2(K+1);
    localparam [2:0] CONFIG=0,RESERVE=1,RELEASE=2,GET_ACCOUNT=3,
        GET_TICKET=4,CLEAR=5,INVALIDATE=6;
    localparam [3:0] OK=0,BAD_ACCOUNT=1,NOT_CONFIGURED=2,BAD_AMOUNT=3,
        DUPLICATE=4,LIMIT_EXCEEDED=5,FULL=6,NOT_FOUND=7,BAD_LIMIT=8,
        INVALID_STATE=9,BAD_OP=10,BACKEND_FAULT=11;
    localparam [3:0] IDLE=0,A_READ=1,A_WAIT=2,SCAN=3,T_READ=4,T_WAIT=5,
        SCAN_END=6,T_WRITE=7,T_WRITE_WAIT=8,A_WRITE=9,A_WRITE_WAIT=10,RESPONSE=11;
    generate if(ACCOUNTS<1 || ACCOUNTS>16 || TICKETS<1 || TICKETS>64 || TAG_W<1 || TAG_W>32)begin: invalid
        pretrade_credit_ledger_invalid_parameters__see_README rejected();
    end endgenerate

    reg [3:0] state;
    reg [A-1:0] configured;
    reg [K-1:0] live;
    reg [CW-1:0] count;
    reg [2:0] op;
    reg [15:0] account;
    reg [63:0] ticket,amount,new_limit,old_limit,old_used,new_used;
    reg [KW-1:0] cursor,free_slot,found_slot;
    reg free_seen;
    wire ar_ready,ar_valid,ar_error,tr_ready,tr_valid,tr_error;
    wire [127:0] ar_data;
    wire [135:0] tr_data;
    wire [7:0] stored_account=tr_data[135:128];
    wire [63:0] stored_amount=tr_data[127:64];
    wire [64:0] reserve_sum={1'b0,old_used}+{1'b0,amount};
    wire account_request=(state==A_READ || state==A_WRITE);
    wire ticket_request=(state==T_READ || state==T_WRITE);
    wire [127:0] account_write={(op==CONFIG)?new_limit:old_limit,new_used};
    wire [135:0] ticket_write={account[7:0],amount,ticket};
    wire [KW-1:0] ticket_address=(state==T_WRITE)?free_slot:cursor;
    cip_sync_sp_ram #(.DATA_WIDTH(128),.ADDR_WIDTH(AW),.DEPTH(A)) account_ram(
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
        .req_valid(rst_n&&account_request),.req_ready(ar_ready),
        .req_write(state==A_WRITE),.req_addr(account[AW-1:0]),
        .req_wdata(account_write),.req_wstrb(16'hffff),
        .rsp_valid(ar_valid),.rsp_ready(state==A_WAIT || state==A_WRITE_WAIT),
        .rsp_rdata(ar_data),.rsp_error(ar_error));
    cip_sync_sp_ram #(.DATA_WIDTH(136),.ADDR_WIDTH(KW),.DEPTH(K)) ticket_ram(
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
        .req_valid(rst_n&&ticket_request),.req_ready(tr_ready),
        .req_write(state==T_WRITE),.req_addr(ticket_address),
        .req_wdata(ticket_write),.req_wstrb(17'h1ffff),
        .rsp_valid(tr_valid),.rsp_ready(state==T_WAIT || state==T_WRITE_WAIT),
        .rsp_rdata(tr_data),.rsp_error(tr_error));
    assign c_ready=rst_n && state==IDLE;
    assign r_valid=rst_n && state==RESPONSE;
    assign busy=rst_n && state!=IDLE;

    task backend_fault;
        begin r_status<=BACKEND_FAULT;faulted<=1;state<=RESPONSE;end
    endtask
    task advance_scan;
        begin
            if(cursor==K-1)state<=SCAN_END;
            else begin cursor<=cursor+1'b1;state<=SCAN;end
        end
    endtask
    task account_result(input [63:0] result_limit,input [63:0] result_used);
        begin
            r_account<=account;r_limit<=result_limit;r_used<=result_used;
            r_available<=result_limit-result_used;
        end
    endtask

    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;configured<=0;live<=0;count<=0;faulted<=0;
            op<=0;account<=0;ticket<=0;amount<=0;new_limit<=0;
            old_limit<=0;old_used<=0;new_used<=0;
            cursor<=0;free_slot<=0;found_slot<=0;free_seen<=0;
            r_op<=0;r_status<=0;r_account<=0;r_ticket<=0;r_amount<=0;
            r_limit<=0;r_used<=0;r_available<=0;r_live<=0;r_tag<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                op<=c_op;account<=c_account;ticket<=c_ticket;amount<=c_amount;new_limit<=c_limit;
                r_op<=c_op;r_status<=OK;r_tag<=c_tag;r_account<=0;r_ticket<=0;r_amount<=0;
                r_limit<=0;r_used<=0;r_available<=0;r_live<=count;
                cursor<=0;free_seen<=0;free_slot<=0;found_slot<=0;
                if(c_op==CLEAR)begin
                    configured<=0;live<=0;count<=0;faulted<=0;r_live<=0;state<=RESPONSE;
                end else if(c_op==INVALIDATE)begin faulted<=1;state<=RESPONSE;end
                else if(c_op>INVALIDATE)begin r_status<=BAD_OP;state<=RESPONSE;end
                else if(faulted)begin r_status<=INVALID_STATE;state<=RESPONSE;end
                else if(c_op==RELEASE || c_op==GET_TICKET)state<=SCAN;
                else if(c_account>=A)begin r_status<=BAD_ACCOUNT;state<=RESPONSE;end
                else if(c_op==RESERVE && c_amount==0)begin r_status<=BAD_AMOUNT;state<=RESPONSE;end
                else if(!configured[c_account])begin
                    if(c_op==CONFIG)begin new_used<=0;state<=A_WRITE;end
                    else begin r_status<=NOT_CONFIGURED;state<=RESPONSE;end
                end else state<=A_READ;
            end
            A_READ:if(ar_ready)state<=A_WAIT;
            A_WAIT:if(ar_valid)begin
                if(ar_error || ar_data[63:0]>ar_data[127:64])backend_fault();
                else begin
                    old_limit<=ar_data[127:64];old_used<=ar_data[63:0];
                    if(op==CONFIG)begin
                        if(new_limit<ar_data[63:0])begin r_status<=BAD_LIMIT;state<=RESPONSE;end
                        else begin new_used<=ar_data[63:0];state<=A_WRITE;end
                    end else if(op==GET_ACCOUNT)begin
                        account_result(ar_data[127:64],ar_data[63:0]);state<=RESPONSE;
                    end else if(op==RESERVE)begin cursor<=0;state<=SCAN;end
                    else if(amount==0 || amount>ar_data[63:0])backend_fault();
                    else if(op==GET_TICKET)begin
                        account_result(ar_data[127:64],ar_data[63:0]);
                        r_ticket<=ticket;r_amount<=amount;state<=RESPONSE;
                    end else begin new_used<=ar_data[63:0]-amount;state<=A_WRITE;end
                end
            end
            SCAN:begin
                if(live[cursor])state<=T_READ;
                else begin
                    if(!free_seen)begin free_seen<=1;free_slot<=cursor;end
                    advance_scan();
                end
            end
            T_READ:if(tr_ready)state<=T_WAIT;
            T_WAIT:if(tr_valid)begin
                if(tr_error)backend_fault();
                else if(tr_data[63:0]==ticket)begin
                    if(op==RESERVE)begin r_status<=DUPLICATE;state<=RESPONSE;end
                    else if(stored_account>=A || stored_amount==0)backend_fault();
                    else if(!configured[stored_account])backend_fault();
                    else begin
                        account<={8'd0,stored_account};amount<=stored_amount;
                        found_slot<=cursor;state<=A_READ;
                    end
                end else advance_scan();
            end
            SCAN_END:begin
                if(op!=RESERVE)begin r_status<=NOT_FOUND;state<=RESPONSE;end
                else if(reserve_sum>{1'b0,old_limit})begin r_status<=LIMIT_EXCEEDED;state<=RESPONSE;end
                else if(!free_seen)begin r_status<=FULL;state<=RESPONSE;end
                else begin new_used<=reserve_sum[63:0];state<=T_WRITE;end
            end
            T_WRITE:if(tr_ready)state<=T_WRITE_WAIT;
            T_WRITE_WAIT:if(tr_valid)begin
                if(tr_error)backend_fault();else state<=A_WRITE;
            end
            A_WRITE:if(ar_ready)state<=A_WRITE_WAIT;
            A_WRITE_WAIT:if(ar_valid)begin
                if(ar_error)backend_fault();
                else begin
                    if(op==CONFIG)begin
                        configured[account]<=1;account_result(new_limit,new_used);
                    end else begin
                        account_result(old_limit,new_used);r_ticket<=ticket;r_amount<=amount;
                        if(op==RESERVE)begin
                            live[free_slot]<=1;count<=count+1'b1;r_live<=count+1'b1;
                        end else begin
                            live[found_slot]<=0;count<=count-1'b1;r_live<=count-1'b1;
                        end
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
