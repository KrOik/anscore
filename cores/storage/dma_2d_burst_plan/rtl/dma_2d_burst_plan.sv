// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Original address-planning service; no bus or payload transactions are issued.
module dma_2d_burst_plan #(
    parameter integer ADDR_W=32,
    parameter integer DATA_BYTES=4,
    parameter integer MAX_BURST_BEATS=16,
    parameter integer TAG_W=8
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [ADDR_W-1:0] s_base,
    input wire [31:0] s_row_bytes,
    input wire [15:0] s_rows,
    input wire signed [ADDR_W:0] s_stride,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [1:0] m_status,
    output reg [TAG_W-1:0] m_tag,
    output reg m_keep,
    output reg [ADDR_W-1:0] m_addr,
    output reg [8:0] m_beats,
    output reg [14:0] m_bytes,
    output reg [DATA_BYTES-1:0] m_first_mask,m_last_mask,
    output reg [15:0] m_row,
    output reg [31:0] m_row_offset,
    output reg [47:0] m_offset,
    output reg m_row_first,m_row_last,m_first,m_last
);
    generate
        if(ADDR_W<12 || ADDR_W>64 || DATA_BYTES<1 || DATA_BYTES>64 ||
           (DATA_BYTES & (DATA_BYTES-1))!=0 || MAX_BURST_BEATS<1 ||
           MAX_BURST_BEATS>256 || TAG_W<1 || TAG_W>32) begin: bad_parameter
            dma_2d_burst_plan_invalid_parameter__see_README reject();
        end
    endgenerate
    localparam integer EXT_W=(ADDR_W+18>34)?ADDR_W+18:34;
    localparam [2:0] IDLE=0,MUL=1,CHECK=2,PLAN=3,HOLD=4;
    localparam [1:0] OK=0,EMPTY=1,RANGE=2;
    reg [2:0] state;
    reg [ADDR_W-1:0] base,row_start,cursor;
    reg signed [ADDR_W:0] stride;
    reg [31:0] row_bytes,remaining,row_offset;
    reg [15:0] rows,row_index;
    reg [47:0] offset;
    reg [EXT_W-1:0] product,term;
    reg [15:0] factor;
    reg [3:0] mul_bit;
    reg negative;
    wire signed [EXT_W-1:0] input_stride={{(EXT_W-ADDR_W-1){s_stride[ADDR_W]}},s_stride};
    wire signed [EXT_W-1:0] first_start=$signed({{(EXT_W-ADDR_W){1'b0}},base});
    wire signed [EXT_W-1:0] last_start=first_start+
        (negative ? -$signed(product) : $signed(product));
    wire signed [EXT_W-1:0] min_start=(last_start<first_start)?last_start:first_start;
    wire signed [EXT_W-1:0] max_start=(last_start>first_start)?last_start:first_start;
    // Context extends unsigned row_bytes before adding; no 32-bit truncation.
    wire signed [EXT_W-1:0] last_byte=max_start+$signed({{(EXT_W-32){1'b0}},row_bytes})-1;
    wire signed [EXT_W-1:0] address_limit=({{(EXT_W-1){1'b0}},1'b1} << ADDR_W);

    // The only variable loop is the fixed DATA_BYTES mask decoder. All division
    // and remainder operands below are compile-time powers of two.
    integer head,limit_beats,capacity,covered,beats,tail,lane;
    reg [DATA_BYTES-1:0] first_mask,last_mask;
    always @* begin
        head=cursor & (DATA_BYTES-1);
        limit_beats=(4096-(cursor[11:0] & ~(DATA_BYTES-1)))/DATA_BYTES;
        if(limit_beats>MAX_BURST_BEATS)limit_beats=MAX_BURST_BEATS;
        capacity=limit_beats*DATA_BYTES-head;
        covered=capacity;
        // Unsigned 32-bit compare keeps lengths above 2^31 positive.
        if(remaining<$unsigned(capacity))covered=remaining;
        beats=(head+covered+DATA_BYTES-1)/DATA_BYTES;
        tail=(head+covered-1)%DATA_BYTES;
        first_mask=0;last_mask=0;
        for(lane=0;lane<DATA_BYTES;lane=lane+1)begin
            first_mask[lane]=(lane>=head) && ((beats>1)||(lane<=tail));
            last_mask[lane]=(lane<=tail) && ((beats>1)||(lane>=head));
        end
    end
    assign s_ready=(state==IDLE) && !rst;
    assign m_valid=(state==HOLD) && !rst;

    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;base<=0;row_start<=0;cursor<=0;stride<=0;
            row_bytes<=0;remaining<=0;row_offset<=0;rows<=0;row_index<=0;offset<=0;
            product<=0;term<=0;factor<=0;mul_bit<=0;negative<=0;
            m_status<=0;m_tag<=0;m_keep<=0;m_addr<=0;m_beats<=0;m_bytes<=0;
            m_first_mask<=0;m_last_mask<=0;m_row<=0;m_row_offset<=0;m_offset<=0;
            m_row_first<=0;m_row_last<=0;m_first<=0;m_last<=0;
        end else case(state)
            IDLE: if(s_valid)begin
                base<=s_base;row_start<=s_base;cursor<=s_base;stride<=s_stride;
                row_bytes<=s_row_bytes;remaining<=s_row_bytes;rows<=s_rows;
                row_index<=0;row_offset<=0;offset<=0;m_tag<=s_tag;
                m_status<=EMPTY;m_keep<=0;m_addr<=0;m_beats<=0;m_bytes<=0;
                m_first_mask<=0;m_last_mask<=0;m_row<=0;m_row_offset<=0;m_offset<=0;
                m_row_first<=0;m_row_last<=0;m_first<=1;m_last<=1;
                if(s_rows==0 || s_row_bytes==0)state<=HOLD;
                else begin
                    product<=0;term<=s_stride[ADDR_W] ? -input_stride : input_stride;
                    factor<=s_rows-16'd1;negative<=s_stride[ADDR_W];mul_bit<=0;
                    state<=MUL;
                end
            end
            MUL: begin
                if(factor[0])product<=product+term;
                term<=term<<1;factor<=factor>>1;mul_bit<=mul_bit+1'b1;
                if(mul_bit==15)state<=CHECK;
            end
            CHECK: begin
                if(min_start<0 || last_byte>=address_limit)begin
                    m_status<=RANGE;state<=HOLD;
                end else state<=PLAN;
            end
            PLAN: begin
                m_status<=OK;m_keep<=1;m_addr<=(cursor/DATA_BYTES)*DATA_BYTES;
                m_beats<=beats;m_bytes<=covered;m_first_mask<=first_mask;m_last_mask<=last_mask;
                m_row<=row_index;m_row_offset<=row_offset;m_offset<=offset;
                m_row_first<=row_offset==0;m_row_last<=remaining==$unsigned(covered);
                m_first<=(row_index==0 && row_offset==0);
                m_last<=(row_index==rows-1'b1 && remaining==$unsigned(covered));
                state<=HOLD;
            end
            HOLD: if(m_ready)begin
                if(m_last)state<=IDLE;
                else begin
                    offset<=offset+m_bytes;
                    if(m_row_last)begin
                        row_index<=row_index+1'b1;row_offset<=0;remaining<=row_bytes;
                        // Preflight proved every row start representable. Modular
                        // addition is then the exact low ADDR_W-bit row address.
                        row_start<=row_start+stride;cursor<=row_start+stride;
                    end else begin
                        row_offset<=row_offset+m_bytes;remaining<=remaining-m_bytes;
                        cursor<=cursor+m_bytes;
                    end
                    state<=PLAN;
                end
            end
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
