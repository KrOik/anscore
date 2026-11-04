// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module transactional_scratchpad #(
    parameter integer CONTEXTS=4,DEPTH=16,DATA_W=32,TAG_W=8,
    localparam integer TW=CONTEXTS>1?$clog2(CONTEXTS):1,
    localparam integer AW=DEPTH>1?$clog2(DEPTH):1,
    localparam integer CW=DEPTH>1?$clog2(DEPTH+1):1
)(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [2:0] c_op,input wire [7:0] c_context,input wire [31:0] c_address,
    input wire [DATA_W-1:0] c_data,input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,
    output reg [2:0] r_op,r_status,output reg [7:0] r_context,
    output reg [31:0] r_address,output reg [TAG_W-1:0] r_tag,
    output reg [DATA_W-1:0] r_data,output reg [CW-1:0] r_written,
    output reg r_active,r_conflict
);
    localparam integer TOTAL=CONTEXTS*DEPTH,FW=TOTAL>1?$clog2(TOTAL):1;
    localparam [3:0] INIT=0,IDLE=1,BEGIN_CLEAR=2,LOOKUP_READ=3,LOOKUP_CHECK=4,
        SNAPSHOT_WRITE=5,STAGE_WRITE=6,COMMIT_READ=7,COMMIT_CHECK=8,APPLY=9,
        INVALIDATE_READ=10,INVALIDATE_CHECK=11,FINISH=12,ACK=13;
    localparam [2:0] OK=0,BAD_OP=1,BAD_CONTEXT=2,BAD_ADDRESS=3,
        NOT_ACTIVE=4,ALREADY_ACTIVE=5,CONFLICT=6;
    reg [3:0] state;
    reg [DATA_W-1:0] committed[0:DEPTH-1],read_log[0:TOTAL-1],write_log[0:TOTAL-1];
    reg read_mask[0:TOTAL-1],write_mask[0:TOTAL-1];
    reg [CONTEXTS-1:0] active,conflicted;
    reg [CW-1:0] write_count[0:CONTEXTS-1];
    reg [TW-1:0] context_q,invalidate_context;
    reg [AW-1:0] address_q,sweep;
    reg [FW-1:0] init_index;
    reg [DATA_W-1:0] data_q,committed_q,read_q,write_q;
    reg read_bit_q,write_bit_q,invalidate_bit_q,clear_response;
    wire [FW-1:0] log_address=context_q*DEPTH+address_q;
    wire [FW-1:0] clear_address=context_q*DEPTH+sweep;
    wire [FW-1:0] invalidate_address=invalidate_context*DEPTH+address_q;
    assign c_ready=!rst && state==IDLE;
    assign r_valid=!rst && state==ACK;
    generate if(CONTEXTS<1 || CONTEXTS>8 || DEPTH<1 || DEPTH>64 ||
        DATA_W<1 || DATA_W>32 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        transactional_scratchpad_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    task reject(input [2:0] code);
        begin r_status<=code;state<=ACK;end
    endtask
    task next_commit_word;
        begin
            if(address_q==DEPTH-1)state<=FINISH;
            else begin address_q<=address_q+1'b1;state<=COMMIT_READ;end
        end
    endtask
    // Independent banks each have one selected synchronous access per phase.
    // No payload-array reset or read/write collision behavior is required.
    always @(posedge clk)if(!rst)begin
        if(state==INIT)begin
            read_mask[init_index]<=0;write_mask[init_index]<=0;
            if(init_index<DEPTH)committed[init_index]<=0;
        end else if(state==BEGIN_CLEAR)begin read_mask[clear_address]<=0;write_mask[clear_address]<=0;end
        else if(state==SNAPSHOT_WRITE)begin read_log[log_address]<=committed_q;read_mask[log_address]<=1;end
        else if(state==STAGE_WRITE)begin write_log[log_address]<=data_q;write_mask[log_address]<=1;end
        if(state==LOOKUP_READ)begin
            committed_q<=committed[address_q];read_q<=read_log[log_address];write_q<=write_log[log_address];
            read_bit_q<=read_mask[log_address];write_bit_q<=write_mask[log_address];
        end
        if(state==COMMIT_READ)begin write_q<=write_log[log_address];write_bit_q<=write_mask[log_address];end
        if(state==APPLY)committed[address_q]<=write_q;
        if(state==INVALIDATE_READ)invalidate_bit_q<=read_mask[invalidate_address];
    end
    integer k;
    always @(posedge clk)begin
        if(rst)begin
            state<=INIT;context_q<=0;invalidate_context<=0;address_q<=0;sweep<=0;init_index<=0;
            data_q<=0;active<=0;conflicted<=0;clear_response<=0;
            r_op<=0;r_status<=0;r_context<=0;r_address<=0;r_tag<=0;r_data<=0;r_written<=0;r_active<=0;r_conflict<=0;
            for(k=0;k<CONTEXTS;k=k+1)write_count[k]<=0;
        end else case(state)
            INIT:if(init_index==TOTAL-1)state<=clear_response?ACK:IDLE;else init_index<=init_index+1'b1;
            IDLE:if(c_valid)begin
                r_op<=c_op;r_context<=c_context;r_address<=c_address;r_tag<=c_tag;
                r_status<=OK;r_data<=0;r_written<=0;r_active<=0;r_conflict<=0;
                context_q<=c_context[TW-1:0];address_q<=c_address[AW-1:0];data_q<=c_data;
                if(c_op==7)reject(BAD_OP);
                else if(c_op==6)begin
                    active<=0;conflicted<=0;init_index<=0;clear_response<=1;state<=INIT;
                    for(k=0;k<CONTEXTS;k=k+1)write_count[k]<=0;
                end else if(c_op!=5 && c_context>=CONTEXTS)reject(BAD_CONTEXT);
                else begin
                    // PEEK ignores context entirely, including its narrowed log address.
                    if(c_op==5)context_q<=0;
                    else begin r_active<=active[c_context[TW-1:0]];r_conflict<=conflicted[c_context[TW-1:0]];end
                    if((c_op==1 || c_op==2 || c_op==5) && c_address>=DEPTH)reject(BAD_ADDRESS);
                    else if(c_op==5)state<=LOOKUP_READ;
                    else if(c_op==0)begin
                        if(active[c_context[TW-1:0]])reject(ALREADY_ACTIVE);
                        else begin sweep<=0;state<=BEGIN_CLEAR;end
                    end else if(!active[c_context[TW-1:0]])reject(NOT_ACTIVE);
                    else if(c_op==4 || (c_op==3 && conflicted[c_context[TW-1:0]]))begin
                        active[c_context[TW-1:0]]<=0;conflicted[c_context[TW-1:0]]<=0;write_count[c_context[TW-1:0]]<=0;
                        r_active<=0;r_conflict<=0;
                        if(c_op==3)reject(CONFLICT);else state<=ACK;
                    end else if(conflicted[c_context[TW-1:0]])reject(CONFLICT);
                    else if(c_op==3)begin address_q<=0;state<=COMMIT_READ;end
                    else state<=LOOKUP_READ;
                end
            end
            BEGIN_CLEAR:if(sweep==DEPTH-1)begin
                active[context_q]<=1;conflicted[context_q]<=0;write_count[context_q]<=0;
                r_active<=1;r_conflict<=0;state<=ACK;
            end else sweep<=sweep+1'b1;
            LOOKUP_READ:state<=LOOKUP_CHECK;
            LOOKUP_CHECK:if(r_op==5)begin r_data<=committed_q;state<=ACK;end
                else if(r_op==2)state<=STAGE_WRITE;
                else if(write_bit_q)begin r_data<=write_q;state<=ACK;end
                else if(read_bit_q)begin r_data<=read_q;state<=ACK;end
                else state<=SNAPSHOT_WRITE;
            SNAPSHOT_WRITE:begin r_data<=committed_q;state<=ACK;end
            STAGE_WRITE:begin
                if(!write_bit_q)write_count[context_q]<=write_count[context_q]+1'b1;state<=ACK;
            end
            COMMIT_READ:state<=COMMIT_CHECK;
            COMMIT_CHECK:if(write_bit_q)state<=APPLY;else next_commit_word();
            APPLY:begin invalidate_context<=0;state<=INVALIDATE_READ;end
            INVALIDATE_READ:state<=INVALIDATE_CHECK;
            INVALIDATE_CHECK:begin
                if(invalidate_context!=context_q && active[invalidate_context] && invalidate_bit_q)
                    conflicted[invalidate_context]<=1;
                if(invalidate_context==CONTEXTS-1)next_commit_word();
                else begin invalidate_context<=invalidate_context+1'b1;state<=INVALIDATE_READ;end
            end
            FINISH:begin
                r_written<=write_count[context_q];write_count[context_q]<=0;active[context_q]<=0;conflicted[context_q]<=0;
                r_active<=0;r_conflict<=0;state<=ACK;
            end
            ACK:if(r_ready)state<=IDLE;
            default:begin state<=INIT;init_index<=0;active<=0;conflicted<=0;clear_response<=0;end
        endcase
    end
endmodule
