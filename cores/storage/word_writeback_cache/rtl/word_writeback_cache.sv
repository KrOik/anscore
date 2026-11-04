// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module word_writeback_cache #(
    parameter integer LINES=16,
    parameter integer LINE_WORDS=4,
    parameter integer TAG_W=8
)(
    input wire clk, rst,
    input wire c_valid,
    output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_address, c_data,
    input wire [3:0] c_strobe,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,
    input wire r_ready,
    output reg [31:0] r_data,
    output reg [1:0] r_status,
    output reg r_hit,
    output reg [TAG_W-1:0] r_tag,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire mem_req_write,
    output wire [31:0] mem_req_address, mem_req_data,
    output wire [3:0] mem_req_strobe,
    input wire mem_resp_valid,
    output wire mem_resp_ready,
    input wire [31:0] mem_resp_data,
    input wire mem_resp_error
);
    localparam integer LB=$clog2(LINES);
    localparam integer WB=$clog2(LINE_WORDS);
    localparam integer LIW=(LB<1)?1:LB;
    localparam integer WIW=(WB<1)?1:WB;
    localparam integer DAW=(LB+WB<1)?1:LB+WB;
    localparam integer CTW=30-LB-WB;
    localparam [3:0] IDLE=0, LOOKUP=1, ACCESS_READ=2, ACCESS_APPLY=3,
        WB_READ=4, WB_REQ=5, WB_WAIT=6, FILL_REQ=7, FILL_WAIT=8,
        FLUSH_SCAN=9, RESPONSE=10;

    reg [3:0] state;
    reg [31:0] address_q, data_q;
    reg [3:0] strobe_q;
    reg write_q, flush_q;
    reg [LIW-1:0] line_index;
    reg [WIW-1:0] word_index;
    reg [CTW-1:0] cache_tag [0:LINES-1];
    reg [LINES-1:0] valid_bits, dirty_bits;
    reg [31:0] data_ram [0:LINES*LINE_WORDS-1];
    reg [31:0] ram_q;

    wire [CTW-1:0] request_tag=address_q >> (2+WB+LB);
    wire [WIW-1:0] access_word=(address_q >> 2) & (LINE_WORDS-1);
    wire access_phase=(state==ACCESS_READ || state==ACCESS_APPLY);
    wire [DAW-1:0] ram_address=line_index*LINE_WORDS+
        (access_phase ? access_word : word_index);
    wire ram_read=(state==ACCESS_READ || state==WB_READ);
    wire ram_write=(state==ACCESS_APPLY && write_q) ||
        (state==FILL_WAIT && mem_resp_valid && mem_resp_ready && !mem_resp_error);
    wire [31:0] byte_mask={{8{strobe_q[3]}},{8{strobe_q[2]}},
                          {8{strobe_q[1]}},{8{strobe_q[0]}}};
    wire [31:0] ram_write_data=(state==ACCESS_APPLY) ?
        ((ram_q & ~byte_mask) | (data_q & byte_mask)) : mem_resp_data;

    // One shared address, one registered read output, no payload reset.
    always @(posedge clk) begin
        if (ram_read && !rst) ram_q <= data_ram[ram_address];
        if (ram_write && !rst) data_ram[ram_address] <= ram_write_data;
    end

    wire [31:0] victim_base=
        ({{(32-CTW){1'b0}},cache_tag[line_index]} << (2+LB+WB)) |
        ({{(32-LIW){1'b0}},line_index} << (2+WB));
    wire [31:0] fill_base=(address_q >> (2+WB)) << (2+WB);
    wire [31:0] byte_offset={{(32-WIW){1'b0}},word_index} << 2;

    assign c_ready=!rst && state==IDLE;
    assign r_valid=!rst && state==RESPONSE;
    assign mem_req_valid=!rst && (state==WB_REQ || state==FILL_REQ);
    assign mem_req_write=(state==WB_REQ);
    assign mem_req_address=((state==WB_REQ)?victim_base:fill_base) | byte_offset;
    assign mem_req_data=(state==WB_REQ)?ram_q:32'd0;
    assign mem_req_strobe=(state==WB_REQ)?4'hf:4'h0;
    assign mem_resp_ready=!rst && (state==WB_WAIT || state==FILL_WAIT);

    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE;
            valid_bits<=0;
            dirty_bits<=0;
            address_q<=0; data_q<=0; strobe_q<=0;
            write_q<=0; flush_q<=0; line_index<=0; word_index<=0;
            r_data<=0; r_status<=0; r_hit<=0; r_tag<=0;
        end else begin
            case (state)
                IDLE: if (c_valid && c_ready) begin
                    address_q<=c_address; data_q<=c_data; strobe_q<=c_strobe;
                    write_q<=(c_op==1); flush_q<=(c_op==2);
                    r_data<=0; r_status<=0; r_hit<=0; r_tag<=c_tag;
                    line_index<=(c_address >> (2+WB)) & (LINES-1);
                    word_index<=0;
                    if (c_op==2) begin
                        line_index<=0;
                        state<=FLUSH_SCAN;
                    end else if (c_op==3 || c_address[1:0]!=0) begin
                        r_status<=1;
                        state<=RESPONSE;
                    end else if (c_op==1 && c_strobe==0) state<=RESPONSE;
                    else state<=LOOKUP;
                end
                LOOKUP: begin
                    if (valid_bits[line_index] && cache_tag[line_index]==request_tag) begin
                        r_hit<=1;
                        state<=ACCESS_READ;
                    end else if (valid_bits[line_index] && dirty_bits[line_index]) begin
                        word_index<=0;
                        state<=WB_READ;
                    end else begin
                        valid_bits[line_index]<=0;
                        dirty_bits[line_index]<=0;
                        word_index<=0;
                        state<=FILL_REQ;
                    end
                end
                ACCESS_READ: state<=ACCESS_APPLY;
                ACCESS_APPLY: begin
                    if (write_q) dirty_bits[line_index]<=1;
                    else r_data<=ram_q;
                    state<=RESPONSE;
                end
                WB_READ: state<=WB_REQ;
                WB_REQ: if (mem_req_valid && mem_req_ready) state<=WB_WAIT;
                WB_WAIT: if (mem_resp_valid && mem_resp_ready) begin
                    if (mem_resp_error) begin
                        // Keep the entire victim valid and dirty for retry.
                        r_status<=2;
                        state<=RESPONSE;
                    end else if (word_index==LINE_WORDS-1) begin
                        valid_bits[line_index]<=0;
                        dirty_bits[line_index]<=0;
                        word_index<=0;
                        if (!flush_q) state<=FILL_REQ;
                        else if (line_index==LINES-1) state<=RESPONSE;
                        else begin
                            line_index<=line_index+1'b1;
                            state<=FLUSH_SCAN;
                        end
                    end else begin
                        word_index<=word_index+1'b1;
                        state<=WB_READ;
                    end
                end
                FILL_REQ: if (mem_req_valid && mem_req_ready) state<=FILL_WAIT;
                FILL_WAIT: if (mem_resp_valid && mem_resp_ready) begin
                    if (mem_resp_error) begin
                        // A partially filled line remains invalid.
                        r_status<=3;
                        state<=RESPONSE;
                    end else if (word_index==LINE_WORDS-1) begin
                        cache_tag[line_index]<=request_tag;
                        valid_bits[line_index]<=1;
                        dirty_bits[line_index]<=0;
                        state<=ACCESS_READ;
                    end else begin
                        word_index<=word_index+1'b1;
                        state<=FILL_REQ;
                    end
                end
                FLUSH_SCAN: begin
                    if (valid_bits[line_index] && dirty_bits[line_index]) begin
                        word_index<=0;
                        state<=WB_READ;
                    end else begin
                        valid_bits[line_index]<=0;
                        dirty_bits[line_index]<=0;
                        if (line_index==LINES-1) state<=RESPONSE;
                        else line_index<=line_index+1'b1;
                    end
                end
                RESPONSE: if (r_valid && r_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end

    generate if (LINES<1 || LINES>64 || (LINES&(LINES-1))!=0 ||
                 LINE_WORDS<1 || LINE_WORDS>16 || (LINE_WORDS&(LINE_WORDS-1))!=0 ||
                 TAG_W<1 || TAG_W>32) begin : invalid_parameters
        word_writeback_cache_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
