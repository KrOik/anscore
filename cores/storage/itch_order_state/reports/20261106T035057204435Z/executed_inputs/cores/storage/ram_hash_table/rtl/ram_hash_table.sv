// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ram_hash_table #(
    parameter integer SLOTS=32,
    parameter integer KEY_W=32,
    parameter integer VALUE_W=32,
    parameter integer TAG_W=8,
    localparam integer COUNT_W=(SLOTS<2)?1:$clog2(SLOTS+1)
)(
    input wire clk,rst,
    input wire c_valid,
    output wire c_ready,
    input wire [1:0] c_op,
    input wire [KEY_W-1:0] c_key,
    input wire [VALUE_W-1:0] c_value,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,
    input wire r_ready,
    output reg [1:0] r_status,
    output reg r_found,r_inserted,
    output reg [VALUE_W-1:0] r_old_value,
    output wire [COUNT_W-1:0] r_count,
    output reg [TAG_W-1:0] r_tag
);
    localparam integer IW=(SLOTS<2)?1:$clog2(SLOTS);
    localparam [2:0] CLEAR=0,IDLE=1,PROBE_READ=2,PROBE_CHECK=3,
        WRITE=4,ERASE=5,RESPONSE=6;
    localparam [1:0] EMPTY=0,LIVE=1,TOMBSTONE=2;
    reg [2:0] state;
    reg [KEY_W+VALUE_W-1:0] entries [0:SLOTS-1];
    reg [1:0] slot_state [0:SLOTS-1];
    reg [KEY_W+VALUE_W-1:0] entry_q;
    reg [1:0] slot_q;
    reg [KEY_W-1:0] key_q;
    reg [VALUE_W-1:0] value_q;
    reg [1:0] op_q;
    reg [IW-1:0] probe_index,clear_index,tomb_index,write_index;
    reg [COUNT_W-1:0] visited,occupancy;
    reg tomb_seen,new_insert,clear_response;

    function automatic [IW-1:0] hash_key(input [KEY_W-1:0] key);
        integer bit_index;
        begin
            hash_key=0;
            if (SLOTS>1)
                for (bit_index=0;bit_index<KEY_W;bit_index=bit_index+1)
                    hash_key[bit_index%IW]=hash_key[bit_index%IW]^key[bit_index];
        end
    endfunction

    wire match_slot=(slot_q==LIVE && entry_q[KEY_W+VALUE_W-1:VALUE_W]==key_q);
    wire last_probe=(visited==SLOTS-1);
    wire reusable=tomb_seen || slot_q==TOMBSTONE || slot_q==EMPTY;
    wire [IW-1:0] ram_address=(state==WRITE)?write_index:
        (state==CLEAR)?clear_index:probe_index;
    assign c_ready=!rst && state==IDLE;
    assign r_valid=!rst && state==RESPONSE;
    assign r_count=occupancy;

    // A single selected address is read synchronously; mutations use a
    // separate phase. Metadata clearing does not reset the payload RAM.
    always @(posedge clk) begin
        if (!rst) begin
            if (state==PROBE_READ) begin
                entry_q<=entries[ram_address];slot_q<=slot_state[ram_address];
            end
            if (state==CLEAR) slot_state[ram_address]<=EMPTY;
            else if (state==WRITE) begin
                entries[ram_address]<={key_q,value_q};slot_state[ram_address]<=LIVE;
            end else if (state==ERASE) slot_state[ram_address]<=TOMBSTONE;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state<=CLEAR;clear_index<=0;probe_index<=0;write_index<=0;tomb_index<=0;
            visited<=0;occupancy<=0;tomb_seen<=0;new_insert<=0;clear_response<=0;
            key_q<=0;value_q<=0;op_q<=0;
            r_status<=0;r_found<=0;r_inserted<=0;r_old_value<=0;r_tag<=0;
        end else begin
            case (state)
                CLEAR: begin
                    if (clear_index==SLOTS-1)
                        state<=clear_response?RESPONSE:IDLE;
                    else clear_index<=clear_index+1'b1;
                end
                IDLE: if (c_valid && c_ready) begin
                    key_q<=c_key;value_q<=c_value;op_q<=c_op;r_tag<=c_tag;
                    r_status<=0;r_found<=0;r_inserted<=0;r_old_value<=0;
                    tomb_seen<=0;new_insert<=0;visited<=0;
                    probe_index<=hash_key(c_key);
                    if (c_op==3) begin
                        clear_response<=1;clear_index<=0;occupancy<=0;state<=CLEAR;
                    end else state<=PROBE_READ;
                end
                PROBE_READ: state<=PROBE_CHECK;
                PROBE_CHECK: begin
                    if (match_slot) begin
                        r_found<=1;r_old_value<=entry_q[VALUE_W-1:0];
                        if (op_q==0) state<=RESPONSE;
                        else if (op_q==1) begin write_index<=probe_index;state<=WRITE;end
                        else state<=ERASE;
                    end else if (slot_q==EMPTY || last_probe) begin
                        if (op_q==1 && reusable) begin
                            // A current last-slot tombstone is usable even
                            // before it has been recorded in tomb_index.
                            write_index<=tomb_seen?tomb_index:probe_index;
                            new_insert<=1;r_inserted<=1;state<=WRITE;
                        end else begin
                            r_status<=(op_q==1)?2'd2:2'd1;
                            state<=RESPONSE;
                        end
                    end else begin
                        if (slot_q==TOMBSTONE && !tomb_seen) begin
                            tomb_seen<=1;tomb_index<=probe_index;
                        end
                        probe_index<=probe_index+1'b1;
                        visited<=visited+1'b1;state<=PROBE_READ;
                    end
                end
                WRITE: begin
                    if (new_insert) occupancy<=occupancy+1'b1;
                    state<=RESPONSE;
                end
                ERASE: begin occupancy<=occupancy-1'b1;state<=RESPONSE;end
                RESPONSE: if (r_valid && r_ready) state<=IDLE;
                default: state<=CLEAR;
            endcase
        end
    end
    generate if (SLOTS<1 || SLOTS>256 || (SLOTS&(SLOTS-1))!=0 ||
                 KEY_W<1 || KEY_W>64 || VALUE_W<1 || VALUE_W>64 ||
                 TAG_W<1 || TAG_W>32) begin : invalid_parameters
        ram_hash_table_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
