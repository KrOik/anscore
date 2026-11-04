// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Overlap-safe full-word memmove on the ANSCORE native acknowledged word port.
module word_memmove #(
    parameter integer COUNT_W=16,
    parameter integer TAG_W=8
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire [31:0] s_source,s_destination,
    input wire [COUNT_W-1:0] s_words,
    input wire [TAG_W-1:0] s_tag,
    output wire done_valid,
    input wire done_ready,
    output reg [1:0] done_status, // 0 OK, 1 command, 2 read, 3 write error
    output reg [COUNT_W-1:0] done_words,
    output reg done_backward,
    output reg [TAG_W-1:0] done_tag,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire mem_req_write,
    output wire [31:0] mem_req_address,mem_req_data,
    output wire [3:0] mem_req_strobe,
    input wire mem_resp_valid,
    output wire mem_resp_ready,
    input wire [31:0] mem_resp_data,
    input wire mem_resp_error
);
    generate if(COUNT_W<1 || COUNT_W>24 || TAG_W<1 || TAG_W>32) begin:g_invalid
        word_memmove_invalid_parameters invalid_configuration();
    end endgenerate
    localparam [2:0] IDLE=0,READ_REQUEST=1,READ_RESPONSE=2,
        WRITE_REQUEST=3,WRITE_RESPONSE=4,DONE=5;
    reg [2:0] state;
    reg [31:0] source,destination,buffered_word;
    reg [COUNT_W-1:0] remaining;
    wire [COUNT_W-1:0] count_minus_one=s_words-1'b1;
    wire [32:0] byte_offset=33'(count_minus_one)<<2;
    wire [32:0] source_last={1'b0,s_source}+byte_offset;
    wire [32:0] destination_last={1'b0,s_destination}+byte_offset;
    wire [32:0] source_end=source_last+33'd4;
    wire backwards=s_destination>s_source && {1'b0,s_destination}<source_end;
    assign s_ready=!rst && state==IDLE;
    assign done_valid=!rst && state==DONE;
    assign mem_req_valid=!rst && (state==READ_REQUEST || state==WRITE_REQUEST);
    assign mem_req_write=state==WRITE_REQUEST;
    assign mem_req_address=mem_req_write?destination:source;
    assign mem_req_data=mem_req_write?buffered_word:32'd0;
    assign mem_req_strobe=mem_req_write?4'b1111:4'b0000;
    assign mem_resp_ready=!rst && (state==READ_RESPONSE || state==WRITE_RESPONSE);

    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;source<=0;destination<=0;buffered_word<=0;remaining<=0;
            done_status<=0;done_words<=0;done_backward<=0;done_tag<=0;
        end else case(state)
            IDLE:if(s_valid) begin
                done_status<=0;done_words<=0;done_backward<=0;done_tag<=s_tag;
                if(s_words==0) state<=DONE;
                else if(s_source[1:0]!=0 || s_destination[1:0]!=0 || source_last[32] || destination_last[32]) begin
                    done_status<=1;state<=DONE;
                end else if(s_source==s_destination) state<=DONE;
                else begin
                    done_backward<=backwards;
                    source<=backwards?source_last[31:0]:s_source;
                    destination<=backwards?destination_last[31:0]:s_destination;
                    remaining<=s_words;state<=READ_REQUEST;
                end
            end
            READ_REQUEST:if(mem_req_ready) state<=READ_RESPONSE;
            READ_RESPONSE:if(mem_resp_valid) begin
                if(mem_resp_error) begin done_status<=2;state<=DONE;end
                else begin buffered_word<=mem_resp_data;state<=WRITE_REQUEST;end
            end
            WRITE_REQUEST:if(mem_req_ready) state<=WRITE_RESPONSE;
            WRITE_RESPONSE:if(mem_resp_valid) begin
                if(mem_resp_error) begin done_status<=3;state<=DONE;end
                else begin
                    done_words<=done_words+1'b1;
                    if(remaining==1) state<=DONE;
                    else begin
                        remaining<=remaining-1'b1;
                        source<=done_backward?source-32'd4:source+32'd4;
                        destination<=done_backward?destination-32'd4:destination+32'd4;
                        state<=READ_REQUEST;
                    end
                end
            end
            DONE:if(done_ready) state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
