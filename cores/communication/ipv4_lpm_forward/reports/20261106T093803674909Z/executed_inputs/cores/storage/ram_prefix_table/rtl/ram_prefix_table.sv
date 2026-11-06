// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ram_prefix_table #(
    parameter integer SLOTS=32, KEY_W=32, VALUE_W=32, TAG_W=8,
    localparam integer PW=(KEY_W>1?$clog2(KEY_W+1):1),
    localparam integer CW=(SLOTS>1?$clog2(SLOTS+1):1)
)(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [1:0] c_op,
    input wire [KEY_W-1:0] c_key,
    input wire [31:0] c_length,
    input wire [VALUE_W-1:0] c_value,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,
    output reg [1:0] r_status,
    output reg r_found,r_inserted,
    output reg [KEY_W-1:0] r_prefix,
    output reg [PW-1:0] r_length,
    output reg [VALUE_W-1:0] r_value,
    output wire [CW-1:0] r_count,
    output reg [TAG_W-1:0] r_tag
);
    localparam integer IW=(SLOTS>1?$clog2(SLOTS):1), EW=1+KEY_W+PW+VALUE_W;
    localparam [2:0] CLEAR=0,IDLE=1,READ=2,CHECK=3,FINISH=4,WRITE=5,ERASE=6,RESPONSE=7;
    reg [2:0] state;
    reg [EW-1:0] entries[0:SLOTS-1];
    reg [EW-1:0] entry_q;
    reg [IW-1:0] scan_index,free_index,matched_index,write_index;
    reg [KEY_W-1:0] key_q;
    reg [PW-1:0] length_q;
    reg [VALUE_W-1:0] value_q;
    reg [1:0] op_q;
    reg free_seen,new_insert,clear_response;
    reg [CW-1:0] occupancy;
    wire live=entry_q[EW-1];
    wire [KEY_W-1:0] prefix=entry_q[VALUE_W+PW +:KEY_W];
    wire [PW-1:0] length=entry_q[VALUE_W +:PW];
    wire [VALUE_W-1:0] value=entry_q[VALUE_W-1:0];
    function automatic [KEY_W-1:0] canonical(input [KEY_W-1:0] key,input [PW-1:0] len);
        integer b;
        begin
            canonical=0;
            // Bit-domain definition avoids /0 and full-width shift corner cases.
            for(b=0;b<KEY_W;b=b+1)if(b>=KEY_W-len)canonical[b]=key[b];
        end
    endfunction
    assign c_ready=!rst && state==IDLE;
    assign r_valid=!rst && state==RESPONSE;
    assign r_count=occupancy;
    // Read and mutation states are disjoint; no RAM collision mode is assumed.
    always @(posedge clk)if(!rst)begin
        if(state==READ)entry_q<=entries[scan_index];
        if(state==CLEAR)entries[scan_index]<=0;
        if(state==WRITE)entries[write_index]<={1'b1,key_q,length_q,value_q};
        if(state==ERASE)entries[matched_index]<=0;
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;scan_index<=0;free_index<=0;matched_index<=0;write_index<=0;
            key_q<=0;length_q<=0;value_q<=0;op_q<=0;
            free_seen<=0;new_insert<=0;clear_response<=0;occupancy<=0;
            r_status<=0;r_found<=0;r_inserted<=0;r_prefix<=0;r_length<=0;r_value<=0;r_tag<=0;
        end else case(state)
            CLEAR:begin
                if(scan_index==SLOTS-1)state<=clear_response?RESPONSE:IDLE;
                else scan_index<=scan_index+1'b1;
            end
            IDLE:if(c_valid)begin
                op_q<=c_op;key_q<=c_op==0?c_key:canonical(c_key,c_length[PW-1:0]);
                length_q<=c_length[PW-1:0];value_q<=c_value;r_tag<=c_tag;
                r_status<=0;r_found<=0;r_inserted<=0;r_prefix<=0;r_length<=0;r_value<=0;
                scan_index<=0;free_seen<=0;new_insert<=0;
                if(c_op==3)begin clear_response<=1;occupancy<=0;state<=CLEAR;end
                else if(c_op!=0 && c_length>KEY_W)begin r_status<=3;state<=RESPONSE;end
                else state<=READ;
            end
            READ:state<=CHECK;
            CHECK:begin
                if(!live && !free_seen)begin free_seen<=1;free_index<=scan_index;end
                if(live && ((op_q==0 && canonical(key_q,length)==prefix && (!r_found || length>r_length)) ||
                            (op_q!=0 && length==length_q && prefix==key_q)))begin
                    r_found<=1;r_prefix<=prefix;r_length<=length;r_value<=value;matched_index<=scan_index;
                end
                if(scan_index==SLOTS-1)state<=FINISH;
                else begin scan_index<=scan_index+1'b1;state<=READ;end
            end
            FINISH:begin
                if(op_q==0)begin r_status<=r_found?0:1;state<=RESPONSE;end
                else if(op_q==1)begin
                    if(r_found || free_seen)begin
                        write_index<=r_found?matched_index:free_index;
                        new_insert<=!r_found;r_inserted<=!r_found;state<=WRITE;
                    end else begin r_status<=2;state<=RESPONSE;end
                end else if(r_found)state<=ERASE;
                else begin r_status<=1;state<=RESPONSE;end
            end
            WRITE:begin if(new_insert)occupancy<=occupancy+1'b1;state<=RESPONSE;end
            ERASE:begin occupancy<=occupancy-1'b1;state<=RESPONSE;end
            RESPONSE:if(r_ready)state<=IDLE;
        endcase
    end
    generate if(SLOTS<1 || SLOTS>128 || KEY_W<1 || KEY_W>64 || VALUE_W<1 || VALUE_W>64 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        ram_prefix_table_invalid_parameters__see_README rejected();
    end endgenerate
endmodule
