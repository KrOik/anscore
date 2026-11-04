// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ecc_scrub_scratchpad #(
    parameter integer DEPTH=256,
    parameter integer TAG_W=8,
    localparam integer COUNT_W=(DEPTH<2)?1:$clog2(DEPTH+1)
)(
    input wire clk,rst,
    input wire c_valid,
    output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_address,c_data,
    input wire [3:0] c_strobe,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,
    input wire r_ready,
    output reg [31:0] r_data,
    output reg [1:0] r_status,
    output reg [COUNT_W-1:0] r_corrected,r_uncorrectable,
    output reg [31:0] r_first_uncorrectable,
    output reg [TAG_W-1:0] r_tag
);
    localparam integer AW=(DEPTH<2)?1:$clog2(DEPTH);
    localparam [3:0] INIT=0,IDLE=1,RAM_READ=2,DECODE_SEND=3,DECODE_WAIT=4,
        ENCODE_SEND=5,ENCODE_WAIT=6,RESPONSE=7;
    reg [3:0] state;
    reg [AW-1:0] word_index;
    reg [31:0] write_data,encode_data;
    reg [3:0] write_strobe;
    reg write_q,scrub_q;
    reg [38:0] code_ram [0:DEPTH-1];
    reg [38:0] ram_q;
    wire enc_s_ready,enc_m_valid,dec_s_ready,dec_m_valid;
    wire [38:0] enc_code,dec_code;
    wire [31:0] dec_data;
    wire [1:0] dec_status;
    wire [5:0] unused_syndrome;
    wire unused_parity,unused_enc_last,unused_enc_tag,unused_dec_last,unused_dec_tag;
    wire enc_take=!rst && state==ENCODE_WAIT && enc_m_valid;
    wire dec_take=!rst && state==DECODE_WAIT && dec_m_valid;
    wire [31:0] byte_mask={{8{write_strobe[3]}},{8{write_strobe[2]}},
                          {8{write_strobe[1]}},{8{write_strobe[0]}}};
    wire repair=dec_take && dec_status==1 && (scrub_q || !write_q);

    stream_secded_encode #(.DATA_W(32),.TAG_W(1)) encoder(
        .clk(clk),.rst(rst),.s_valid(!rst && state==ENCODE_SEND),.s_ready(enc_s_ready),
        .s_data(encode_data),.s_last(1'b1),.s_tag(1'b0),
        .m_valid(enc_m_valid),.m_ready(!rst && state==ENCODE_WAIT),
        .m_code(enc_code),.m_last(unused_enc_last),.m_tag(unused_enc_tag)
    );
    stream_secded_decode #(.DATA_W(32),.TAG_W(1)) decoder(
        .clk(clk),.rst(rst),.s_valid(!rst && state==DECODE_SEND),.s_ready(dec_s_ready),
        .s_code(ram_q),.s_last(1'b1),.s_tag(1'b0),
        .m_valid(dec_m_valid),.m_ready(!rst && state==DECODE_WAIT),
        .m_data(dec_data),.m_code(dec_code),.m_status(dec_status),
        .m_syndrome(unused_syndrome),.m_parity(unused_parity),
        .m_last(unused_dec_last),.m_tag(unused_dec_tag)
    );

    // All RAM actions use one selected address; no payload reset tree.
    // All-zero payload has an all-zero valid extended Hamming codeword.
    always @(posedge clk) begin
        if (!rst) begin
            if (state==RAM_READ) ram_q<=code_ram[word_index];
            if (state==INIT) code_ram[word_index]<=39'd0;
            else if (enc_take) code_ram[word_index]<=enc_code;
            else if (repair) code_ram[word_index]<=dec_code;
        end
    end

    assign c_ready=!rst && state==IDLE;
    assign r_valid=!rst && state==RESPONSE;
    always @(posedge clk) begin
        if (rst) begin
            state<=INIT;word_index<=0;
            write_data<=0;encode_data<=0;write_strobe<=0;write_q<=0;scrub_q<=0;
            r_data<=0;r_status<=0;r_corrected<=0;r_uncorrectable<=0;
            r_first_uncorrectable<=0;r_tag<=0;
        end else begin
            case (state)
                INIT: begin
                    if (word_index==DEPTH-1) state<=IDLE;
                    else word_index<=word_index+1'b1;
                end
                IDLE: if (c_valid && c_ready) begin
                    r_data<=0;r_status<=0;r_corrected<=0;r_uncorrectable<=0;
                    r_first_uncorrectable<=0;r_tag<=c_tag;
                    write_data<=c_data;write_strobe<=c_strobe;
                    write_q<=(c_op==1);scrub_q<=(c_op==2);
                    word_index<=c_address >> 2;
                    if (c_op==2) begin word_index<=0;state<=RAM_READ;end
                    else if (c_op==3 || c_address[1:0]!=0 || (c_address>>2)>=DEPTH) begin
                        r_status<=3;state<=RESPONSE;
                    end else if (c_op==1 && c_strobe==0) state<=RESPONSE;
                    else if (c_op==1 && c_strobe==15) begin
                        encode_data<=c_data;state<=ENCODE_SEND;
                    end else state<=RAM_READ;
                end
                RAM_READ: state<=DECODE_SEND;
                DECODE_SEND: if (dec_s_ready) state<=DECODE_WAIT;
                DECODE_WAIT: if (dec_take) begin
                    if (dec_status==1) begin
                        r_corrected<=r_corrected+1'b1;
                        if (r_status!=2) r_status<=1;
                    end else if (dec_status==2) begin
                        r_uncorrectable<=r_uncorrectable+1'b1;
                        if (r_uncorrectable==0)
                            r_first_uncorrectable<=({{(32-AW){1'b0}},word_index} << 2);
                        r_status<=2;
                    end
                    if (scrub_q) begin
                        if (word_index==DEPTH-1) state<=RESPONSE;
                        else begin word_index<=word_index+1'b1;state<=RAM_READ;end
                    end else if (dec_status==2) state<=RESPONSE;
                    else if (write_q) begin
                        encode_data<=(dec_data & ~byte_mask) | (write_data & byte_mask);
                        state<=ENCODE_SEND;
                    end else begin r_data<=dec_data;state<=RESPONSE;end
                end
                ENCODE_SEND: if (enc_s_ready) state<=ENCODE_WAIT;
                ENCODE_WAIT: if (enc_take) state<=RESPONSE;
                RESPONSE: if (r_valid && r_ready) state<=IDLE;
                default: state<=INIT;
            endcase
        end
    end
    generate if (DEPTH<1 || DEPTH>4096 || TAG_W<1 || TAG_W>32) begin : invalid_parameters
        ecc_scrub_scratchpad_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
