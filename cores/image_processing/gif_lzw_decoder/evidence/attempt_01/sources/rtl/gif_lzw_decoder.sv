// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module gif_lzw_decoder #(
    parameter integer COUNT_W=32,
    parameter integer TAG_W=8
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [7:0] s_data,
    input wire s_last,s_bad,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [7:0] m_index,
    output wire [TAG_W-1:0] m_tag,
    output wire done_valid,input wire done_ready,
    output wire [4:0] done_errors,
    output wire [COUNT_W-1:0] done_count,
    output wire [7:0] done_min_code_size,
    output wire [TAG_W-1:0] done_tag
);
    localparam [3:0] FIRST=0,GET_BYTE=1,NEED_CODE=2,DISPATCH=3,
        KW_EXTRA=4,ROOT_CHECK=5,DICT_READ=6,DICT_USE=7,BASE_PUSH=8,
        DICT_WRITE=9,STACK_READ=10,STACK_USE=11,OUT_HOLD=12,
        SKIP_BYTE=13,DRAIN=14,DONE=15;
    localparam [4:0] ERR_MIN=5'b00001,ERR_LZW=5'b00010,
        ERR_FORMAT=5'b00100,ERR_UPSTREAM=5'b01000,ERR_LIMIT=5'b10000;
    reg [3:0] state;
    reg [7:0] minimum,block_left;
    reg need_length,previous_valid;
    reg [8:0] clear_code,end_code;
    reg [12:0] next_code,stack_count;
    reg [3:0] code_width;
    reg [4:0] bit_count,errors;
    reg [18:0] bit_buffer;
    reg [11:0] current_code,previous_code,walk;
    reg [7:0] previous_first,current_first;
    reg [COUNT_W-1:0] output_count;
    reg [TAG_W-1:0] tag;

    // Exactly one synchronous read OR write per memory per edge. No payload reset.
    reg [19:0] dictionary[0:4095],dictionary_q;
    reg [7:0] reverse_stack[0:4095],stack_q;
    wire [11:0] stack_top=stack_count[11:0]-12'd1;
    wire count_full=&output_count;
    always @(posedge clk)if(!rst)begin
        if(state==DICT_READ)dictionary_q<=dictionary[walk];
        else if(state==DICT_WRITE && previous_valid && next_code<13'd4096)
            dictionary[next_code[11:0]]<={previous_code,current_first};
        if(state==KW_EXTRA)reverse_stack[stack_count[11:0]]<=previous_first;
        else if(state==DICT_USE)reverse_stack[stack_count[11:0]]<=dictionary_q[7:0];
        else if(state==BASE_PUSH)reverse_stack[stack_count[11:0]]<=walk[7:0];
        else if(state==STACK_READ && !count_full)stack_q<=reverse_stack[stack_top];
    end

    wire [11:0] code_mask=12'hfff>>(4'd12-code_width);
    wire [12:0] width_limit=13'd1<<code_width;
    wire input_state=state==FIRST || state==GET_BYTE || state==SKIP_BYTE || state==DRAIN;
    wire legal_minimum=s_data>=8'd2 && s_data<=8'd8;
    wire [4:0] first_errors=(legal_minimum?5'd0:ERR_MIN)
        |(s_last?ERR_FORMAT:5'd0)|(s_bad?ERR_UPSTREAM:5'd0);
    assign s_ready=!rst && input_state;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_tag=tag;
    assign done_valid=!rst && state==DONE;
    assign done_errors=errors;
    assign done_count=output_count;
    assign done_min_code_size=minimum;
    assign done_tag=tag;

    always @(posedge clk)begin
        if(rst)state<=FIRST;
        else case(state)
            FIRST:if(s_valid)begin
                minimum<=s_data;tag<=s_tag;errors<=first_errors;output_count<=0;
                bit_buffer<=0;bit_count<=0;need_length<=1;block_left<=0;
                previous_valid<=0;stack_count<=0;
                clear_code<=9'd1<<s_data[3:0];end_code<=(9'd1<<s_data[3:0])+9'd1;
                next_code<=(13'd1<<s_data[3:0])+13'd2;code_width<=s_data[3:0]+4'd1;
                if(first_errors!=0)state<=s_last?DONE:DRAIN;
                else state<=GET_BYTE;
            end
            GET_BYTE,SKIP_BYTE:if(s_valid)begin
                if(s_bad)begin
                    errors<=errors|ERR_UPSTREAM;state<=s_last?DONE:DRAIN;
                end else if(need_length)begin
                    if(s_data==0)begin
                        if(state!=SKIP_BYTE || !s_last)errors<=errors|ERR_FORMAT;
                        state<=s_last?DONE:DRAIN;
                    end else if(s_last)begin
                        errors<=errors|ERR_FORMAT;state<=DONE;
                    end else begin block_left<=s_data;need_length<=0;end
                end else if(s_last)begin
                    // A final packet byte must be a zero block length, never payload.
                    errors<=errors|ERR_FORMAT;state<=DONE;
                end else begin
                    block_left<=block_left-8'd1;
                    if(block_left==1)need_length<=1;
                    if(state==GET_BYTE)begin
                        // Refill only below code_width<=12: at most 19 live bits.
                        bit_buffer<=bit_buffer|({11'd0,s_data}<<bit_count);
                        bit_count<=bit_count+5'd8;state<=NEED_CODE;
                    end
                end
            end
            NEED_CODE:begin
                if(bit_count<code_width)state<=GET_BYTE;
                else begin
                    current_code<=bit_buffer[11:0]&code_mask;
                    bit_buffer<=bit_buffer>>code_width;bit_count<=bit_count-code_width;
                    state<=DISPATCH;
                end
            end
            DISPATCH:begin
                if(current_code==clear_code)begin
                    next_code<={4'd0,clear_code}+13'd2;
                    code_width<=minimum[3:0]+4'd1;previous_valid<=0;
                    // CLEAR keeps unconsumed bits from the same payload byte.
                    state<=NEED_CODE;
                end else if(current_code==end_code)begin
                    bit_buffer<=0;bit_count<=0;state<=SKIP_BYTE;
                end else if(current_code<clear_code || (previous_valid && {1'b0,current_code}<next_code))begin
                    walk<=current_code;stack_count<=0;state<=ROOT_CHECK;
                end else if(previous_valid && {1'b0,current_code}==next_code && next_code<13'd4096)begin
                    stack_count<=0;state<=KW_EXTRA;
                end else begin errors<=errors|ERR_LZW;state<=DRAIN;end
            end
            KW_EXTRA:begin
                stack_count<=stack_count+13'd1;walk<=previous_code;state<=ROOT_CHECK;
            end
            ROOT_CHECK:begin
                if(walk<clear_code)state<=BASE_PUSH;
                else state<=DICT_READ;
            end
            DICT_READ:state<=DICT_USE;
            DICT_USE:begin
                stack_count<=stack_count+13'd1;walk<=dictionary_q[19:8];state<=ROOT_CHECK;
            end
            BASE_PUSH:begin
                stack_count<=stack_count+13'd1;current_first<=walk[7:0];state<=DICT_WRITE;
            end
            DICT_WRITE:begin
                if(previous_valid && next_code<13'd4096)begin
                    next_code<=next_code+13'd1;
                    if(code_width<12 && next_code+13'd1==width_limit)code_width<=code_width+4'd1;
                end
                previous_code<=current_code;previous_first<=current_first;previous_valid<=1;
                state<=STACK_READ;
            end
            STACK_READ:begin
                if(count_full)begin errors<=errors|ERR_LIMIT;state<=DRAIN;end
                else state<=STACK_USE;
            end
            STACK_USE:begin m_index<=stack_q;state<=OUT_HOLD;end
            OUT_HOLD:if(m_ready)begin
                output_count<=output_count+1'b1;stack_count<=stack_count-13'd1;
                state<=stack_count==1?NEED_CODE:STACK_READ;
            end
            DRAIN:if(s_valid)begin
                if(s_bad)errors<=errors|ERR_UPSTREAM;
                if(s_last)state<=DONE;
            end
            DONE:if(done_ready)state<=FIRST;
            default:state<=FIRST;
        endcase
    end
    generate if(COUNT_W<1 || COUNT_W>32 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        gif_lzw_decoder_invalid_parameters__see_README invalid_configuration();
    end endgenerate
endmodule
`default_nettype wire
