// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module suffix_array_lcp #(
    parameter integer MAX_SYMBOLS=32,SYMBOL_W=8,TAG_W=8
)(
    input wire clk,input wire rst,
    input wire s_valid,output wire s_ready,input wire [SYMBOL_W-1:0] s_symbol,
    input wire s_keep,input wire s_last,input wire s_error,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [31:0] m_suffix,output wire [31:0] m_lcp,
    output wire [31:0] m_rank,output wire [31:0] m_count,
    output wire m_keep,output wire m_first,output wire m_last,
    output wire [1:0] m_error,output wire [TAG_W-1:0] m_tag
);
    localparam integer I=(MAX_SYMBOLS>1)?$clog2(MAX_SYMBOLS):1;
    localparam integer C=$clog2(MAX_SYMBOLS+1);
    generate if(MAX_SYMBOLS<1 || MAX_SYMBOLS>64 || SYMBOL_W<1 || SYMBOL_W>16 || TAG_W<1 || TAG_W>32)begin:bad
        suffix_array_lcp_invalid_parameters__see_README invalid();
    end endgenerate
    localparam [4:0] CAPTURE=0,CHECK=1,INIT=2,INSERT_READ=3,INSERT_START=4,
        PAIR_CHECK=5,PAIR_READ_A=6,PAIR_READ_B=7,PAIR_USE=8,SHIFT=9,WRITE_INSERT=10,
        LCP_READ_A=11,LCP_READ_B=12,LCP_START=13,LCP_WRITE=14,OUT_READ=15,OUT_USE=16,HOLD=17;
    reg [4:0] state;
    reg [SYMBOL_W-1:0] symbols[0:MAX_SYMBOLS-1];
    reg [I-1:0] order[0:MAX_SYMBOLS-1],lcps[0:MAX_SYMBOLS-1];
    reg [SYMBOL_W-1:0] symbol_q,left_char;
    reg [I-1:0] order_q,lcp_q;
    reg [I-1:0] insert_i,hole,rank_i,out_rank,left_base,right_base,offset;
    reg [I-1:0] out_suffix,out_lcp;
    reg [C-1:0] count;
    reg [TAG_W-1:0] tag;
    reg [1:0] errors;
    reg started,comparing_lcp;
    wire [C:0] left_address={{(C+1-I){1'b0}},left_base}+{{(C+1-I){1'b0}},offset};
    wire [C:0] right_address={{(C+1-I){1'b0}},right_base}+{{(C+1-I){1'b0}},offset};
    wire [C:0] next_insert={{(C+1-I){1'b0}},insert_i}+1'b1;
    wire [C:0] next_rank={{(C+1-I){1'b0}},rank_i}+1'b1;
    wire [C:0] next_output={{(C+1-I){1'b0}},out_rank}+1'b1;
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;
    assign m_keep=m_valid && errors==0 && count!=0;
    assign m_first=m_valid && out_rank==0;
    assign m_last=m_valid && (!m_keep || next_output==count);
    assign m_suffix=m_keep?out_suffix:32'd0;
    assign m_lcp=m_keep?out_lcp:32'd0;
    assign m_rank=m_keep?out_rank:32'd0;
    assign m_count=m_keep?count:32'd0;
    assign m_error=errors;
    assign m_tag=tag;
    // Three independent single-port clocked-read banks. No payload reset.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && s_keep && count<MAX_SYMBOLS)symbols[count[I-1:0]]<=s_symbol;
        if(state==PAIR_READ_A)symbol_q<=symbols[left_address[I-1:0]];
        else if(state==PAIR_READ_B)symbol_q<=symbols[right_address[I-1:0]];
        if(state==INIT)begin order[0]<=0;lcps[0]<=0;end
        else begin
            if(state==INSERT_READ)order_q<=order[hole-1'b1];
            else if(state==SHIFT)order[hole]<=order_q;
            else if(state==WRITE_INSERT)order[hole]<=insert_i;
            else if(state==LCP_READ_A)order_q<=order[rank_i-1'b1];
            else if(state==LCP_READ_B)order_q<=order[rank_i];
            else if(state==OUT_READ)order_q<=order[out_rank];
            if(state==LCP_WRITE)lcps[rank_i]<=offset;
            else if(state==OUT_READ)lcp_q<=lcps[out_rank];
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;count<=0;started<=0;errors<=0;tag<=0;
            out_suffix<=0;out_lcp<=0;out_rank<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(!started)begin tag<=s_tag;started<=1;end
                if(s_error)errors[1]<=1;
                if(s_keep)begin
                    if(count<MAX_SYMBOLS)count<=count+1'b1;else errors[0]<=1;
                end
                if(s_last)state<=CHECK;
            end
            CHECK:begin
                out_rank<=0;
                if(errors!=0 || count==0)begin out_suffix<=0;out_lcp<=0;state<=HOLD;end
                else state<=INIT;
            end
            INIT:begin
                insert_i<=I'(1);hole<=I'(1);rank_i<=I'(1);
                if(count==1)state<=OUT_READ;else state<=INSERT_READ;
            end
            INSERT_READ:state<=INSERT_START;
            INSERT_START:begin
                left_base<=insert_i;right_base<=order_q;offset<=0;comparing_lcp<=0;state<=PAIR_CHECK;
            end
            PAIR_CHECK:begin
                if(left_address==count || right_address==count)begin
                    if(comparing_lcp)state<=LCP_WRITE;
                    else if(left_address==count)state<=SHIFT;
                    else state<=WRITE_INSERT;
                end else state<=PAIR_READ_A;
            end
            PAIR_READ_A:state<=PAIR_READ_B;
            PAIR_READ_B:begin left_char<=symbol_q;state<=PAIR_USE;end
            PAIR_USE:begin
                if(left_char==symbol_q)begin offset<=offset+1'b1;state<=PAIR_CHECK;end
                else if(comparing_lcp)state<=LCP_WRITE;
                else if(left_char<symbol_q)state<=SHIFT;
                else state<=WRITE_INSERT;
            end
            SHIFT:begin hole<=hole-1'b1;if(hole==1)state<=WRITE_INSERT;else state<=INSERT_READ;end
            WRITE_INSERT:begin
                if(next_insert==count)begin rank_i<=I'(1);state<=LCP_READ_A;end
                else begin insert_i<=insert_i+1'b1;hole<=insert_i+1'b1;state<=INSERT_READ;end
            end
            LCP_READ_A:state<=LCP_READ_B;
            LCP_READ_B:begin left_base<=order_q;state<=LCP_START;end
            LCP_START:begin right_base<=order_q;offset<=0;comparing_lcp<=1;state<=PAIR_CHECK;end
            LCP_WRITE:begin
                if(next_rank==count)begin out_rank<=0;state<=OUT_READ;end
                else begin rank_i<=rank_i+1'b1;state<=LCP_READ_A;end
            end
            OUT_READ:state<=OUT_USE;
            OUT_USE:begin out_suffix<=order_q;out_lcp<=lcp_q;state<=HOLD;end
            HOLD:if(m_ready)begin
                if(!m_keep || next_output==count)begin state<=CAPTURE;count<=0;started<=0;errors<=0;end
                else begin out_rank<=out_rank+1'b1;state<=OUT_READ;end
            end
        endcase
    end
endmodule
