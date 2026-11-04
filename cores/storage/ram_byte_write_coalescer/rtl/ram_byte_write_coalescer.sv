// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Frame-private byte stores; exact last-writer merge and acknowledged flush.
module ram_byte_write_coalescer #(
    parameter integer MAX_BEATS=16, ADDR_W=32, DATA_BYTES=4, TAG_W=8,
    localparam integer IW=MAX_BEATS>1?$clog2(MAX_BEATS):1,
    localparam integer CW=$clog2(MAX_BEATS+1),
    localparam integer DW=8*DATA_BYTES,
    localparam integer RW=ADDR_W+9*DATA_BYTES,
    localparam integer LG=DATA_BYTES>1?$clog2(DATA_BYTES):0
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [63:0] s_addr,input wire [7:0] s_data,
    input wire s_keep,s_first,s_last,input wire [TAG_W-1:0] s_tag,
    output wire q_valid,input wire q_ready,
    output wire [ADDR_W-1:0] q_addr,
    output wire [DW-1:0] q_data,output wire [DATA_BYTES-1:0] q_strb,
    input wire p_valid,output wire p_ready,input wire p_error,
    output wire m_valid,input wire m_ready,
    output wire [4:0] m_status,output wire [TAG_W-1:0] m_tag,
    output wire [CW-1:0] m_beats,output wire [MAX_BEATS-1:0] m_error_mask
);
    localparam [3:0] IDLE=0,LOAD=1,SCAN_READ=2,SCAN_CHECK=3,
        APPEND=4,MERGE=5,PREP=6,OUT_READ=7,REQUEST=8,WAIT_ACK=9,RESULT=10;
    reg [3:0] state;
    reg [RW-1:0] rows[0:MAX_BEATS-1],row_q;
    reg [CW-1:0] count;
    reg [IW-1:0] scan_index,out_index;
    reg [TAG_W-1:0] tag_q;
    reg [ADDR_W-1:0] current_addr;
    reg [7:0] current_data;
    reg tail_q;
    reg [2:0] frame_errors;
    reg [MAX_BEATS-1:0] error_mask;

    wire input_fire=s_valid && s_ready;
    // Check the full host address before the capture below narrows it.
    wire address_valid=ADDR_W==64 || (s_addr >> ADDR_W)==64'd0;
    wire [ADDR_W-1:0] current_base=(current_addr >> LG) << LG;
    wire [IW-1:0] read_index=state==OUT_READ?out_index:scan_index;
    wire [IW-1:0] write_index=state==APPEND?count[IW-1:0]:scan_index;
    reg [DW-1:0] merged_data;
    reg [DATA_BYTES-1:0] merged_strobe;
    integer lane;
    always @* begin
        merged_data=state==APPEND?{DW{1'b0}}:row_q[DW+DATA_BYTES-1:DATA_BYTES];
        merged_strobe=state==APPEND?{DATA_BYTES{1'b0}}:row_q[DATA_BYTES-1:0];
        for(lane=0;lane<DATA_BYTES;lane=lane+1)
            if((current_addr & (DATA_BYTES-1))==lane)begin
                merged_data[8*lane+:8]=current_data;
                merged_strobe[lane]=1'b1;
            end
    end

    assign s_ready=!rst && (state==IDLE || state==LOAD);
    assign q_valid=!rst && state==REQUEST;
    assign q_addr=row_q[RW-1:DW+DATA_BYTES];
    assign q_data=row_q[DW+DATA_BYTES-1:DATA_BYTES];
    assign q_strb=row_q[DATA_BYTES-1:0];
    assign p_ready=!rst && state==WAIT_ACK;
    assign m_valid=!rst && state==RESULT;
    assign m_status=frame_errors!=0?{1'b0,frame_errors,1'b0}:
        count==0?5'd1:error_mask!=0?5'd16:5'd0;
    assign m_tag=tag_q;
    assign m_beats=frame_errors!=0?{CW{1'b0}}:count;
    assign m_error_mask=frame_errors!=0?{MAX_BEATS{1'b0}}:error_mask;

    generate if(MAX_BEATS<1 || MAX_BEATS>32 || ADDR_W<1 || ADDR_W>64 ||
        !(DATA_BYTES==1 || DATA_BYTES==2 || DATA_BYTES==4 || DATA_BYTES==8) ||
        LG>ADDR_W || TAG_W<1 || TAG_W>32)begin:bad_parameters
        ram_byte_write_coalescer_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    // Every row is fully initialized before count makes it readable. The only
    // read/write phases are disjoint; the bank/read register have no reset.
    always @(posedge clk)if(!rst)begin
        if(state==SCAN_READ || state==OUT_READ)row_q<=rows[read_index];
        if(state==APPEND || state==MERGE)
            rows[write_index]<={current_base,merged_data,merged_strobe};
    end

    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;count<=0;scan_index<=0;out_index<=0;tag_q<=0;
            current_addr<=0;current_data<=0;tail_q<=0;frame_errors<=0;error_mask<=0;
        end else case(state)
            IDLE:if(input_fire)begin
                count<=0;scan_index<=0;out_index<=0;tag_q<=s_tag;error_mask<=0;
                frame_errors<={1'b0,s_keep && !address_valid,!s_first};
                if(s_keep && address_valid)begin
                    current_addr<=s_addr[ADDR_W-1:0];current_data<=s_data;tail_q<=s_last;
                    state<=APPEND;
                end else state<=s_last?PREP:LOAD;
            end
            LOAD:if(input_fire)begin
                if(s_first)frame_errors[0]<=1'b1;
                if(s_keep && !address_valid)frame_errors[1]<=1'b1;
                if(s_keep && address_valid && !frame_errors[2])begin
                    current_addr<=s_addr[ADDR_W-1:0];current_data<=s_data;tail_q<=s_last;
                    scan_index<=0;state<=count==0?APPEND:SCAN_READ;
                end else state<=s_last?PREP:LOAD;
            end
            SCAN_READ:state<=SCAN_CHECK;
            SCAN_CHECK:begin
                if(row_q[RW-1:DW+DATA_BYTES]==current_base)state<=MERGE;
                else if(scan_index==count-1'b1)begin
                    if(count==MAX_BEATS)begin
                        frame_errors[2]<=1'b1;state<=tail_q?PREP:LOAD;
                    end else state<=APPEND;
                end else begin scan_index<=scan_index+1'b1;state<=SCAN_READ;end
            end
            APPEND:begin count<=count+1'b1;state<=tail_q?PREP:LOAD;end
            MERGE:state<=tail_q?PREP:LOAD;
            PREP:if(frame_errors!=0 || count==0)state<=RESULT;
                else begin out_index<=0;state<=OUT_READ;end
            OUT_READ:state<=REQUEST;
            REQUEST:if(q_ready)state<=WAIT_ACK;
            WAIT_ACK:if(p_valid)begin
                error_mask[out_index]<=p_error;
                if(out_index==count-1'b1)state<=RESULT;
                else begin out_index<=out_index+1'b1;state<=OUT_READ;end
            end
            RESULT:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
