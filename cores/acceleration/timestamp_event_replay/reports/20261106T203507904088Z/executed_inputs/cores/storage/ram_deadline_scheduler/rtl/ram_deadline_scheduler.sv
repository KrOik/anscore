// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Exact keyed event replacement/cancellation and deadline-qualified claiming.
module ram_deadline_scheduler #(
    parameter integer SLOTS=16,ID_W=16,TIME_W=32,DATA_W=32,TAG_W=8
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [2:0] s_op, // 0 upsert,1 cancel,2 next,3 take-due,4 clear
    input wire [ID_W-1:0] s_id,
    input wire [TIME_W-1:0] s_deadline,s_cutoff,
    input wire [DATA_W-1:0] s_data,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [2:0] m_op,m_status,
    output reg m_found,m_replaced,m_due,
    output reg [ID_W-1:0] m_id,
    output reg [TIME_W-1:0] m_deadline,
    output reg [DATA_W-1:0] m_data,
    output reg [TAG_W-1:0] m_tag,
    output wire [$clog2(SLOTS+1)-1:0] m_live,m_free
);
    localparam integer N=(SLOTS>=1 && SLOTS<=128)?SLOTS:1;
    localparam integer IW=(N>1)?$clog2(N):1,CW=$clog2(N+1);
    localparam integer R=ID_W+TIME_W+DATA_W;
    localparam [2:0] IDLE=0,INIT=1,SCAN_READ=2,SCAN_STEP=3,DECIDE=4,WRITE=5,RESPONSE=6;
    generate if(SLOTS<1 || SLOTS>128 || ID_W<1 || ID_W>32 ||
        TIME_W<1 || TIME_W>64 || DATA_W<1 || DATA_W>64 || TAG_W<1 || TAG_W>32)
        begin:bad_parameter
            ram_deadline_scheduler_invalid_parameters__see_README rejected();
        end
    endgenerate

    // {live,id,deadline,payload}; no parallel memory reset or array-wide read.
    reg [R:0] rows[0:N-1];
    reg [R:0] row_q;
    reg [R-1:0] command_record,selected_record;
    reg [TIME_W-1:0] cutoff;
    reg [2:0] state;
    reg [IW-1:0] cursor,selected_index,free_index;
    reg selected_found,free_found,clear_response;
    reg [CW-1:0] live_count;
    wire [ID_W-1:0] row_id=row_q[DATA_W+TIME_W+:ID_W];
    wire [TIME_W-1:0] row_deadline=row_q[DATA_W+:TIME_W];
    wire [ID_W-1:0] command_id=command_record[DATA_W+TIME_W+:ID_W];
    wire [ID_W-1:0] selected_id=selected_record[DATA_W+TIME_W+:ID_W];
    wire [TIME_W-1:0] selected_deadline=selected_record[DATA_W+:TIME_W];
    wire earlier=(row_deadline<selected_deadline) ||
        (row_deadline==selected_deadline && row_id<selected_id);
    wire selected_due=selected_deadline<=cutoff;

    always @(posedge clk)begin
        if(!rst)begin
            if(state==INIT)rows[cursor]<=0;
            else if(state==WRITE)rows[cursor]<=(m_op==0)?{1'b1,command_record}:{(R+1){1'b0}};
            if(state==SCAN_READ)row_q<=rows[cursor];
        end
    end
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==RESPONSE;
    assign m_live=live_count;
    assign m_free=N-live_count;

    always @(posedge clk)begin
        if(rst)begin
            state<=INIT;cursor<=0;selected_index<=0;free_index<=0;
            command_record<=0;selected_record<=0;cutoff<=0;
            selected_found<=0;free_found<=0;clear_response<=0;live_count<=0;
            m_op<=0;m_status<=0;m_found<=0;m_replaced<=0;m_due<=0;
            m_id<=0;m_deadline<=0;m_data<=0;m_tag<=0;
        end else case(state)
            INIT:begin
                if(cursor==N-1)state<=clear_response?RESPONSE:IDLE;
                else cursor<=cursor+1'b1;
            end
            IDLE:if(s_valid)begin
                m_op<=s_op;m_tag<=s_tag;m_status<=0;
                m_found<=0;m_replaced<=0;m_due<=0;m_id<=0;m_deadline<=0;m_data<=0;
                command_record<={s_id,s_deadline,s_data};cutoff<=s_cutoff;
                cursor<=0;selected_found<=0;free_found<=0;
                if(s_op==4)begin live_count<=0;clear_response<=1;state<=INIT;end
                else if(s_op>4)begin m_status<=5;state<=RESPONSE;end
                else state<=SCAN_READ;
            end
            SCAN_READ:state<=SCAN_STEP;
            SCAN_STEP:begin
                if(!row_q[R])begin
                    if(!free_found)begin free_found<=1;free_index<=cursor;end
                end else if((m_op==0 || m_op==1) && row_id==command_id)begin
                    selected_found<=1;selected_index<=cursor;selected_record<=row_q[R-1:0];
                end else if((m_op==2 || m_op==3) && (!selected_found || earlier))begin
                    selected_found<=1;selected_index<=cursor;selected_record<=row_q[R-1:0];
                end
                if(cursor==N-1)state<=DECIDE;
                else begin cursor<=cursor+1'b1;state<=SCAN_READ;end
            end
            DECIDE:begin
                if(m_op==0)begin
                    if(!selected_found && !free_found)begin m_status<=3;state<=RESPONSE;end
                    else begin
                        m_found<=1;m_replaced<=selected_found;
                        {m_id,m_deadline,m_data}<=command_record;
                        cursor<=selected_found?selected_index:free_index;
                        if(!selected_found)live_count<=live_count+1'b1;
                        state<=WRITE;
                    end
                end else if(m_op==1)begin
                    if(!selected_found)begin m_status<=2;state<=RESPONSE;end
                    else begin
                        m_found<=1;{m_id,m_deadline,m_data}<=selected_record;
                        cursor<=selected_index;live_count<=live_count-1'b1;state<=WRITE;
                    end
                end else if(!selected_found)begin m_status<=1;state<=RESPONSE;end
                else begin
                    m_found<=1;m_due<=selected_due;
                    {m_id,m_deadline,m_data}<=selected_record;
                    if(m_op==3 && !selected_due)begin m_status<=4;state<=RESPONSE;end
                    else if(m_op==3)begin
                        cursor<=selected_index;live_count<=live_count-1'b1;state<=WRITE;
                    end else state<=RESPONSE;
                end
            end
            WRITE:state<=RESPONSE;
            RESPONSE:if(m_ready)state<=IDLE;
            default:begin state<=INIT;cursor<=0;clear_response<=0;live_count<=0;end
        endcase
    end
endmodule
`default_nettype wire
