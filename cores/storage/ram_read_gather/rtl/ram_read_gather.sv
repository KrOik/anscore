// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Ordered frame gather with exact address reuse and one outstanding external read.
module ram_read_gather #(
    parameter integer MAX_ITEMS=16,ADDR_W=32,DATA_W=32,TAG_W=8,
    localparam integer IW=MAX_ITEMS>1?$clog2(MAX_ITEMS):1,
    localparam integer CW=$clog2(MAX_ITEMS+1)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire s_keep,s_first,s_last,
    input wire [ADDR_W-1:0] s_addr,input wire [TAG_W-1:0] s_tag,
    output wire q_valid,input wire q_ready,output wire [ADDR_W-1:0] q_addr,
    input wire p_valid,output wire p_ready,
    input wire [DATA_W-1:0] p_data,input wire p_error,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_status,output wire m_keep,m_error,m_first,m_last,
    output wire [ADDR_W-1:0] m_addr,output wire [DATA_W-1:0] m_data,
    output wire [TAG_W-1:0] m_tag,output wire [IW-1:0] m_index,
    output wire [CW-1:0] m_count,m_unique
);
    localparam [3:0] IDLE=0,LOAD=1,PREP=2,ITEM_READ=3,ITEM_CHECK=4,
        SCAN_READ=5,SCAN_CHECK=6,REQUEST=7,WAIT_DATA=8,STORE=9,
        OUT_READ=10,OUT_HOLD=11,STATUS_HOLD=12;
    localparam integer RW=ADDR_W+DATA_W+1;
    reg [3:0] state;
    reg [RW-1:0] rows[0:MAX_ITEMS-1],row_q;
    reg [CW-1:0] count,unique_count;
    reg [IW-1:0] item_index,scan_index,out_index;
    reg [1:0] frame_errors;
    reg [TAG_W-1:0] tag_q;
    reg [ADDR_W-1:0] current_addr;
    reg [DATA_W-1:0] result_data;
    reg result_error;
    wire input_fire=s_valid && s_ready;
    wire loading=state==IDLE || state==LOAD;
    wire replay=state==OUT_HOLD;
    wire [IW-1:0] read_index=state==SCAN_READ?scan_index:
        state==OUT_READ?out_index:item_index;
    wire [IW-1:0] load_index=state==IDLE?{IW{1'b0}}:count[IW-1:0];
    wire room=state==IDLE || count<MAX_ITEMS;
    assign s_ready=!rst && loading;
    assign q_valid=!rst && state==REQUEST;
    assign q_addr=current_addr;
    assign p_ready=!rst && state==WAIT_DATA;
    assign m_valid=!rst && (replay || state==STATUS_HOLD);
    assign m_keep=replay;
    assign m_status=replay?3'd0:(frame_errors!=0?{frame_errors,1'b0}:3'd1);
    assign m_error=replay && row_q[DATA_W];
    assign m_addr=replay?row_q[RW-1:DATA_W+1]:{ADDR_W{1'b0}};
    assign m_data=replay?row_q[DATA_W-1:0]:{DATA_W{1'b0}};
    assign m_tag=tag_q;
    assign m_index=replay?out_index:{IW{1'b0}};
    assign m_count=replay?count:{CW{1'b0}};
    assign m_unique=replay?unique_count:{CW{1'b0}};
    assign m_first=!replay || out_index==0;
    assign m_last=!replay || out_index==count-1'b1;
    generate if(MAX_ITEMS<1 || MAX_ITEMS>32 || ADDR_W<1 || ADDR_W>64 ||
        DATA_W<1 || DATA_W>64 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        ram_read_gather_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    // One synchronous packed bank. Reads, loads and result writes are mutually
    // exclusive; no read-during-write value is consumed. No array reset.
    always @(posedge clk)if(!rst)begin
        if(state==ITEM_READ || state==SCAN_READ || state==OUT_READ)
            row_q<=rows[read_index];
        if(input_fire && s_keep && room)
            rows[load_index]<={s_addr,1'b0,{DATA_W{1'b0}}};
        else if(state==STORE)rows[item_index]<={current_addr,result_error,result_data};
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;count<=0;unique_count<=0;item_index<=0;scan_index<=0;
            out_index<=0;frame_errors<=0;tag_q<=0;current_addr<=0;
            result_data<=0;result_error<=0;
        end else case(state)
            IDLE:if(input_fire)begin
                count<=s_keep?1:0;unique_count<=0;frame_errors<={1'b0,!s_first};
                tag_q<=s_tag;item_index<=0;scan_index<=0;out_index<=0;
                state<=s_last?PREP:LOAD;
            end
            LOAD:if(input_fire)begin
                if(s_first)frame_errors[0]<=1;
                if(s_keep)begin
                    if(count<MAX_ITEMS)count<=count+1'b1;
                    else frame_errors[1]<=1;
                end
                if(s_last)state<=PREP;
            end
            PREP:if(frame_errors!=0 || count==0)state<=STATUS_HOLD;
                 else state<=ITEM_READ;
            ITEM_READ:state<=ITEM_CHECK;
            ITEM_CHECK:begin
                current_addr<=row_q[RW-1:DATA_W+1];scan_index<=0;
                state<=item_index==0?REQUEST:SCAN_READ;
            end
            SCAN_READ:state<=SCAN_CHECK;
            SCAN_CHECK:if(row_q[RW-1:DATA_W+1]==current_addr)begin
                result_data<=row_q[DATA_W-1:0];result_error<=row_q[DATA_W];state<=STORE;
            end else if(scan_index==item_index-1'b1)state<=REQUEST;
            else begin scan_index<=scan_index+1'b1;state<=SCAN_READ;end
            REQUEST:if(q_ready)begin unique_count<=unique_count+1'b1;state<=WAIT_DATA;end
            WAIT_DATA:if(p_valid)begin
                result_error<=p_error;result_data<=p_error?{DATA_W{1'b0}}:p_data;state<=STORE;
            end
            STORE:if(item_index==count-1'b1)begin out_index<=0;state<=OUT_READ;end
                else begin item_index<=item_index+1'b1;state<=ITEM_READ;end
            OUT_READ:state<=OUT_HOLD;
            OUT_HOLD:if(m_ready)begin
                if(out_index==count-1'b1)state<=IDLE;
                else begin out_index<=out_index+1'b1;state<=OUT_READ;end
            end
            STATUS_HOLD:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
