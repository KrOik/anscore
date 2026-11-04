// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Exact immutable block identity, bounded references, serialized RAM ports.
module block_intern_store #(
    parameter integer SLOTS=16,WORDS=4,DATA_W=32,REF_W=8,TAG_W=8,
    localparam integer IW=SLOTS>1?$clog2(SLOTS):1,
    localparam integer WW=WORDS>1?$clog2(WORDS):1,
    localparam integer CW=SLOTS>1?$clog2(SLOTS+1):1
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire [1:0] c_op,input wire [31:0] c_handle,input wire [TAG_W-1:0] c_tag,
    input wire d_valid,output wire d_ready,input wire [DATA_W-1:0] d_data,
    output wire r_valid,input wire r_ready,
    output reg [1:0] r_op,output reg [2:0] r_status,
    output reg [31:0] r_handle,output reg [TAG_W-1:0] r_tag,
    output reg [REF_W-1:0] r_refs,output wire [CW-1:0] r_count,
    output reg r_shared,output wire r_keep,r_first,r_last,
    output wire [WW-1:0] r_index,output wire [DATA_W-1:0] r_data
);
    localparam [3:0] INIT=0,IDLE=1,LOAD=2,META_READ=3,META_CHECK=4,
        COMPARE_READ=5,COMPARE_CHECK=6,INCREMENT=7,COPY_READ=8,COPY_WRITE=9,
        PUBLISH=10,RELEASE_WRITE=11,READ_WORD=12,READ_HOLD=13,ACK=14;
    localparam [2:0] OK=0,BAD_HANDLE=1,NOT_LIVE=2,REFCOUNT_FULL=3,FULL=4;
    reg [3:0] state;
    reg [REF_W-1:0] refs[0:SLOTS-1];
    reg [DATA_W-1:0] payload[0:SLOTS*WORDS-1],scratch[0:WORDS-1];
    reg [REF_W-1:0] refs_q;
    reg [DATA_W-1:0] payload_q,scratch_q;
    reg [IW-1:0] slot_index,free_slot,init_index;
    reg [WW-1:0] word_index;
    reg [CW-1:0] occupancy;
    reg free_seen,clear_response;
    wire replay=state==READ_HOLD;
    localparam integer AW=SLOTS*WORDS>1?$clog2(SLOTS*WORDS):1;
    wire [AW-1:0] payload_address=slot_index*WORDS+word_index;
    assign c_ready=!rst && state==IDLE;
    assign d_ready=!rst && state==LOAD;
    assign r_valid=!rst && (state==ACK || replay);
    assign r_count=occupancy;
    assign r_keep=replay;
    assign r_first=!replay || word_index==0;
    assign r_last=!replay || word_index==WORDS-1;
    assign r_index=replay?word_index:{WW{1'b0}};
    assign r_data=replay?payload_q:{DATA_W{1'b0}};
    generate if(SLOTS<1 || SLOTS>32 || WORDS<1 || WORDS>16 || DATA_W<1 || DATA_W>32 ||
        REF_W<1 || REF_W>16 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        block_intern_store_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    task reject(input [2:0] code);
        begin r_status<=code;r_handle<=0;r_refs<=0;r_shared<=0;state<=ACK;end
    endtask
    task absent;
        begin
            if(free_seen || refs_q==0)begin
                slot_index<=free_seen?free_slot:slot_index;
                word_index<=0;state<=COPY_READ;
            end else reject(FULL);
        end
    endtask
    task advance_slot;
        begin
            if(slot_index==SLOTS-1)absent();
            else begin slot_index<=slot_index+1'b1;word_index<=0;state<=META_READ;end
        end
    endtask

    // Each bank has one scheduled synchronous access; no collision result is used.
    // Unreset payload/scratch are consumed only after validity/full loading.
    always @(posedge clk)if(!rst)begin
        if(state==META_READ)refs_q<=refs[slot_index];
        if(state==INIT)refs[init_index]<=0;
        else if(state==INCREMENT)refs[slot_index]<=refs_q+1'b1;
        else if(state==PUBLISH)refs[slot_index]<=1;
        else if(state==RELEASE_WRITE)refs[slot_index]<=refs_q-1'b1;
        if(state==LOAD && d_valid)scratch[word_index]<=d_data;
        if(state==COMPARE_READ || state==COPY_READ)scratch_q<=scratch[word_index];
        if(state==COMPARE_READ || state==READ_WORD)payload_q<=payload[payload_address];
        if(state==COPY_WRITE)payload[payload_address]<=scratch_q;
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=INIT;slot_index<=0;free_slot<=0;init_index<=0;word_index<=0;
            occupancy<=0;free_seen<=0;clear_response<=0;
            r_op<=0;r_status<=0;r_handle<=0;r_tag<=0;r_refs<=0;r_shared<=0;
        end else case(state)
            INIT:if(init_index==SLOTS-1)state<=clear_response?ACK:IDLE;
                 else init_index<=init_index+1'b1;
            IDLE:if(c_valid)begin
                r_op<=c_op;r_tag<=c_tag;r_status<=OK;r_handle<=0;r_refs<=0;r_shared<=0;
                word_index<=0;slot_index<=c_handle[IW-1:0];free_seen<=0;
                if(c_op==0)begin slot_index<=0;state<=LOAD;end
                else if(c_op==3)begin
                    occupancy<=0;init_index<=0;clear_response<=1;state<=INIT;
                end else if(c_handle>=SLOTS)reject(BAD_HANDLE);
                else state<=META_READ;
            end
            LOAD:if(d_valid)begin
                if(word_index==WORDS-1)begin word_index<=0;state<=META_READ;end
                else word_index<=word_index+1'b1;
            end
            META_READ:state<=META_CHECK;
            META_CHECK:if(r_op==0)begin
                if(refs_q==0)begin
                    if(!free_seen)begin free_seen<=1;free_slot<=slot_index;end
                    advance_slot();
                end else begin word_index<=0;state<=COMPARE_READ;end
            end else if(refs_q==0)reject(NOT_LIVE);
            else begin
                r_handle<=slot_index;r_refs<=refs_q;
                if(r_op==1)state<=READ_WORD;else state<=RELEASE_WRITE;
            end
            COMPARE_READ:state<=COMPARE_CHECK;
            COMPARE_CHECK:if(payload_q!=scratch_q)advance_slot();
                else if(word_index==WORDS-1)begin
                    if(&refs_q)reject(REFCOUNT_FULL);else state<=INCREMENT;
                end else begin word_index<=word_index+1'b1;state<=COMPARE_READ;end
            INCREMENT:begin
                r_handle<=slot_index;r_refs<=refs_q+1'b1;r_shared<=1;state<=ACK;
            end
            COPY_READ:state<=COPY_WRITE;
            COPY_WRITE:if(word_index==WORDS-1)state<=PUBLISH;
                else begin word_index<=word_index+1'b1;state<=COPY_READ;end
            PUBLISH:begin
                occupancy<=occupancy+1'b1;r_handle<=slot_index;r_refs<=1;state<=ACK;
            end
            RELEASE_WRITE:begin
                r_refs<=refs_q-1'b1;if(refs_q==1)occupancy<=occupancy-1'b1;state<=ACK;
            end
            READ_WORD:state<=READ_HOLD;
            READ_HOLD:if(r_ready)begin
                if(word_index==WORDS-1)state<=IDLE;
                else begin word_index<=word_index+1'b1;state<=READ_WORD;end
            end
            ACK:if(r_ready)state<=IDLE;
            default:begin state<=INIT;init_index<=0;occupancy<=0;clear_response<=0;end
        endcase
    end
endmodule
