// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Real old BLC instance; synthetic row SOF is translated back to frame markers.
module raw_ob_black_frontend #(
    parameter integer WIDTH=128,HEIGHT=64,BITS=10,OB_LEFT=8,OB_RIGHT=8,TAG_W=8
)(
    input wire clk,rst,input wire c_valid,output wire c_ready,
    input wire [BITS-1:0] c_low,c_high,c_target,input wire [5:0] c_min_count,
    input wire [1:0] c_pattern,input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,input wire [BITS-1:0] s_data,input wire s_sof,s_eol,s_last,
    output wire m_valid,input wire m_ready,output wire [BITS-1:0] m_data,m_black,
    output wire m_sof,m_eol,m_last,output wire [15:0] m_x,m_y,
    output wire [1:0] m_pattern,output wire [TAG_W-1:0] m_tag,
    output wire d_valid,input wire d_ready,output wire [3:0] d_error,
    output wire [9:0] d_rows,output wire [16:0] d_pixels,output wire [TAG_W-1:0] d_tag,
    output wire [31:0] clip_low_count,clip_high_count,output wire busy
);
    wire row_valid,row_ready,row_end_valid,row_end_ready,raw_valid,raw_ready,raw_eol,raw_sof,raw_last,core_busy;
    wire [BITS-1:0] black0,black1,target,raw_data;
    wire [15:0] row_y,raw_x;
    wire [1:0] pattern;wire [TAG_W-1:0] tag;
    reg row_active;reg [1:0] owned;reg [15:0] out_x;
    wire blc_cr,blc_sr,blc_mv,blc_sof,blc_eol;
    wire [15:0] blc_frame;
    wire [31:0] blc_low,blc_high;
    reg [31:0] base_low,base_high;
    wire empty=owned==0&&!blc_mv;
    assign row_ready=!rst&&!row_active&&empty&&blc_cr;
    assign row_end_ready=!rst&&row_active&&empty;
    assign raw_ready=!rst&&row_active&&blc_sr;
    assign m_valid=!rst&&row_active&&blc_mv;
    assign m_sof=row_y==0&&blc_sof;assign m_eol=blc_eol;assign m_last=row_y==HEIGHT-1&&blc_eol;
    assign m_x=out_x;assign m_y=row_y;assign m_pattern=pattern;assign m_tag=tag;
    assign m_black=out_x[0]?black1:black0;
    assign clip_low_count=blc_low-base_low;assign clip_high_count=blc_high-base_high;
    assign busy=!rst&&(core_busy||row_active||owned!=0||blc_mv);
    raw_optical_black_rows #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.OB_LEFT(OB_LEFT),.OB_RIGHT(OB_RIGHT),.TAG_W(TAG_W)) calibrate(
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_low(c_low),.c_high(c_high),.c_target(c_target),.c_min_count(c_min_count),.c_pattern(c_pattern),.c_tag(c_tag),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
        .row_valid(row_valid),.row_ready(row_ready),.row_black0(black0),.row_black1(black1),.row_target(target),.row_y(row_y),.row_pattern(pattern),.row_tag(tag),
        .row_end_valid(row_end_valid),.row_end_ready(row_end_ready),
        .m_valid(raw_valid),.m_ready(raw_ready),.m_data(raw_data),.m_black(),.m_sof(raw_sof),.m_eol(raw_eol),.m_last(raw_last),.m_x(raw_x),.m_y(),.m_pattern(),.m_tag(),
        .d_valid(d_valid),.d_ready(d_ready),.d_error(d_error),.d_rows(d_rows),.d_pixels(d_pixels),.d_tag(d_tag),.busy(core_busy));
    // Pattern0 + synthetic SOF per row uses only plane0/1. Repeat the offsets
    // into plane2/3 as well; no frame-dependent y parity leaks across row epochs.
    raw_black_level_stream #(.RAW_BITS(BITS)) blc(
        .clk(clk),.rst_n(!rst),.cfg_valid(row_valid&&!row_active&&empty),.cfg_ready(blc_cr),.cfg_pattern(2'd0),
        .cfg_levels({black1,black0,black1,black0}),.cfg_target(target),.cfg_bypass(1'b0),
        .s_valid(raw_valid&&row_active),.s_ready(blc_sr),.s_data(raw_data),.s_sof(raw_x==0),.s_eol(raw_eol),.s_frame_id(16'(tag)),
        .m_valid(blc_mv),.m_ready(m_ready&&row_active&&!rst),.m_data(m_data),.m_sof(blc_sof),.m_eol(blc_eol),.m_frame_id(blc_frame),
        .clip_low_count(blc_low),.clip_high_count(blc_high));
    always @(posedge clk)begin
        if(rst)begin row_active<=0;owned<=0;out_x<=0;base_low<=0;base_high<=0;end
        else begin
            if(c_valid&&c_ready)begin base_low<=blc_low;base_high<=blc_high;end
            if(row_valid&&row_ready)begin row_active<=1;out_x<=0;end
            if(row_end_valid&&row_end_ready)row_active<=0;
            case({raw_valid&&raw_ready,m_valid&&m_ready})
                2'b10:owned<=owned+1'b1;
                2'b01:owned<=owned-1'b1;
                default:owned<=owned;
            endcase
            if(m_valid&&m_ready)out_x<=out_x+1'b1;
        end
    end
endmodule
