// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Original exact-length address ownership service; no payload memory.
module extent_pool_allocator #(
    parameter integer UNITS=64,
    parameter integer TAG_W=8
)(
    input wire clk,rst,
    input wire s_valid, output wire s_ready,
    input wire [2:0] s_op, // allocate, release, query, clear; others rejected
    input wire [31:0] s_length,s_base,
    input wire [3:0] s_align_order,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg [2:0] m_op,m_status,
    output reg [31:0] m_length,m_base,
    output reg [3:0] m_align_order,
    output reg [TAG_W-1:0] m_tag,
    output reg [$clog2(UNITS+1)-1:0] m_free_units,m_largest_gap
);
    localparam integer N=(UNITS>=1 && UNITS<=256)?UNITS:1;
    localparam integer IW=(N>1)?$clog2(N):1;
    localparam integer CW=$clog2(N+1);
    localparam [3:0] IDLE=0,INIT=1,SCAN_READ=2,SCAN_CHECK=3,MARK=4,
        HEAD_READ=5,HEAD_CHECK=6,SUM_READ=7,SUM_CHECK=8,RESPONSE=9;
    generate if(UNITS<1 || UNITS>256 || TAG_W<1 || TAG_W>32)begin:bad_parameter
        extent_pool_allocator_invalid_parameters__see_README rejected();
    end endgenerate

    // {busy, head_length}; interior busy units and free units have length zero.
    reg [CW:0] rows[0:N-1];
    reg [CW:0] row_q;
    reg [3:0] state;
    reg [IW-1:0] cursor,run_base,mark_base;
    reg [CW-1:0] length_q,run_length,mark_left;
    reg [CW-1:0] sum_free,sum_run,sum_largest;
    reg mark_allocate,clear_response;
    wire [31:0] cursor_full=cursor;
    wire [31:0] align_mask=(32'd1<<m_align_order)-1'b1;
    wire aligned=(cursor_full & align_mask)==0;
    wire [32:0] release_end={1'b0,s_base}+{1'b0,s_length};
    wire free_row=!row_q[CW];
    wire [CW-1:0] next_free=sum_free+free_row;
    wire [CW-1:0] next_run=free_row?sum_run+1'b1:{CW{1'b0}};
    wire [CW-1:0] next_largest=(next_run>sum_largest)?next_run:sum_largest;
    wire read_enable=!rst && (state==SCAN_READ || state==HEAD_READ || state==SUM_READ);
    wire [CW-1:0] mark_length=(cursor==mark_base)?length_q:{CW{1'b0}};

    // One synchronous read and one synchronous write port, never concurrent.
    // Reset cancels privately; INIT clears all rows before accepting a command.
    always @(posedge clk)begin
        if(!rst && state==INIT)rows[cursor]<=0;
        else if(!rst && state==MARK)
            rows[cursor]<=mark_allocate?{1'b1,mark_length}:{(CW+1){1'b0}};
        if(read_enable)row_q<=rows[cursor];
    end
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==RESPONSE;

    task summarize;
        begin
            cursor<=0;sum_free<=0;sum_run<=0;sum_largest<=0;state<=SUM_READ;
        end
    endtask
    task found_extent(input [IW-1:0] base_index);
        begin
            mark_base<=base_index;cursor<=base_index;mark_left<=length_q;
            mark_allocate<=1;m_base<=base_index;state<=MARK;
        end
    endtask
    task continue_search;
        begin
            if(cursor==N-1)begin m_status<=2;summarize();end
            else begin cursor<=cursor+1'b1;state<=SCAN_READ;end
        end
    endtask

    always @(posedge clk)begin
        if(rst)begin
            state<=INIT;cursor<=0;run_base<=0;mark_base<=0;
            length_q<=0;run_length<=0;mark_left<=0;
            sum_free<=0;sum_run<=0;sum_largest<=0;
            mark_allocate<=0;clear_response<=0;
            m_op<=0;m_status<=0;m_length<=0;m_base<=0;
            m_align_order<=0;m_tag<=0;m_free_units<=0;m_largest_gap<=0;
        end else case(state)
            INIT:begin
                if(cursor==N-1)begin
                    m_free_units<=N;m_largest_gap<=N;
                    state<=clear_response?RESPONSE:IDLE;
                end else cursor<=cursor+1'b1;
            end
            IDLE:if(s_valid)begin
                m_op<=s_op;m_status<=0;m_length<=s_length;m_base<=0;
                m_align_order<=s_align_order;m_tag<=s_tag;
                length_q<=s_length;cursor<=0;run_length<=0;
                if(s_op==3)begin clear_response<=1;state<=INIT;end
                else if(s_op>3)begin m_status<=4;summarize();end
                else if(s_op==2)summarize();
                else if(s_length==0 || s_length>N ||
                    (s_op==0 && s_align_order>8) ||
                    (s_op==1 && (s_base>=N || release_end>N)))begin
                    m_status<=1;summarize();
                end else if(s_op==0)state<=SCAN_READ;
                else begin cursor<=s_base;state<=HEAD_READ;end
            end
            SCAN_READ:state<=SCAN_CHECK;
            SCAN_CHECK:begin
                if(!free_row)begin run_length<=0;continue_search();end
                else if(run_length!=0)begin
                    if(run_length+1'b1==length_q)found_extent(run_base);
                    else begin run_length<=run_length+1'b1;continue_search();end
                end else if(aligned)begin
                    if(length_q==1)found_extent(cursor);
                    else begin run_base<=cursor;run_length<=1;continue_search();end
                end else continue_search();
            end
            HEAD_READ:state<=HEAD_CHECK;
            HEAD_CHECK:begin
                if(row_q!={1'b1,length_q})begin m_status<=3;summarize();end
                else begin
                    mark_base<=cursor;mark_left<=length_q;mark_allocate<=0;
                    m_base<=cursor;state<=MARK;
                end
            end
            MARK:begin
                if(mark_left==1)summarize();
                else begin mark_left<=mark_left-1'b1;cursor<=cursor+1'b1;end
            end
            SUM_READ:state<=SUM_CHECK;
            SUM_CHECK:begin
                sum_free<=next_free;sum_run<=next_run;sum_largest<=next_largest;
                if(cursor==N-1)begin
                    m_free_units<=next_free;m_largest_gap<=next_largest;state<=RESPONSE;
                end else begin cursor<=cursor+1'b1;state<=SUM_READ;end
            end
            RESPONSE:if(m_ready)state<=IDLE;
            default:state<=INIT;
        endcase
    end
endmodule
`default_nettype wire
