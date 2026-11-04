// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Atomic SG table replacement and exact logical-range to physical-span mapping.
module ram_sg_range_map #(
    parameter integer MAX_SEGS=16,ADDR_W=32,LEN_W=16,TAG_W=8,
    localparam integer IW=MAX_SEGS>1?$clog2(MAX_SEGS):1,
    localparam integer CW=$clog2(MAX_SEGS+1),
    localparam integer TW=LEN_W+(MAX_SEGS>1?$clog2(MAX_SEGS):0)
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [1:0] c_op,
    input wire [63:0] c_offset,c_bytes,input wire [TAG_W-1:0] c_tag,
    input wire e_valid,output wire e_ready,input wire e_keep,e_first,e_last,
    input wire [ADDR_W-1:0] e_base,input wire [LEN_W-1:0] e_bytes,
    output wire m_valid,input wire m_ready,output reg [1:0] m_op,
    output reg [2:0] m_status,output wire [2:0] m_load_errors,
    output wire m_keep,m_first,m_last,output reg [TAG_W-1:0] m_tag,
    output reg [ADDR_W-1:0] m_addr,output reg [LEN_W-1:0] m_bytes,
    output wire [TW-1:0] m_offset,m_total,output wire [IW-1:0] m_segment,
    output wire [CW-1:0] m_segments
);
    localparam [2:0] IDLE=0,LOAD=1,PUBLISH=2,READ=3,CHECK=4,OUTPUT=5,ACK=6;
    localparam integer AW=$clog2(2*MAX_SEGS),EW=(ADDR_W>LEN_W?ADDR_W:LEN_W)+1;
    localparam integer MW=(ADDR_W>TW?ADDR_W:TW)+1;
    reg [2:0] state;
    reg bank;
    reg [CW-1:0] active_count,shadow_count;
    reg [TW-1:0] active_total,shadow_total,residual,logical_cursor,remaining;
    reg [IW-1:0] scan_index;
    reg [2:0] load_errors;
    reg entry_started,first_fragment;
    reg [ADDR_W+LEN_W-1:0] rows[0:2*MAX_SEGS-1],row_q;
    wire [AW-1:0] read_address=bank*MAX_SEGS+scan_index;
    wire [AW-1:0] write_address=(!bank)*MAX_SEGS+shadow_count[IW-1:0];
    wire [EW-1:0] entry_last={{(EW-ADDR_W){1'b0}},e_base}+
        {{(EW-LEN_W){1'b0}},e_bytes}-1'b1;
    wire entry_range_bad=e_bytes!=0 && (entry_last>>ADDR_W)!=0;
    wire [2:0] incoming_errors=load_errors |
        ((e_keep && entry_range_bad)?3'b001:3'b000) |
        ((e_first!=!entry_started)?3'b010:3'b000) |
        ((e_keep && shadow_count==MAX_SEGS)?3'b100:3'b000);
    wire [64:0] query_end={1'b0,c_offset}+{1'b0,c_bytes};
    wire query_bad=query_end>{{(65-TW){1'b0}},active_total};
    wire [LEN_W-1:0] row_bytes=row_q[LEN_W-1:0];
    wire [TW-1:0] available={{(TW-LEN_W){1'b0}},row_bytes}-residual;
    wire [MW-1:0] physical_address={{(MW-ADDR_W){1'b0}},row_q[ADDR_W+LEN_W-1:LEN_W]}+
        {{(MW-TW){1'b0}},residual};
    wire replay=state==OUTPUT;
    assign c_ready=!rst && state==IDLE;
    assign e_ready=!rst && state==LOAD;
    assign m_valid=!rst && (replay || state==ACK);
    assign m_keep=replay;
    assign m_first=!replay || first_fragment;
    assign m_last=!replay || remaining=={{(TW-LEN_W){1'b0}},m_bytes};
    assign m_load_errors=m_op==0?load_errors:3'b000;
    assign m_offset=replay?logical_cursor:{TW{1'b0}};
    assign m_segment=replay?scan_index:{IW{1'b0}};
    assign m_total=active_total;
    assign m_segments=active_count;
    generate if(MAX_SEGS<1 || MAX_SEGS>32 || ADDR_W<1 || ADDR_W>64 ||
        LEN_W<1 || LEN_W>32 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        ram_sg_range_map_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    // One packed banked RAM. Loading only writes the inactive bank. Read and
    // write phases never overlap; there is one synchronous read-output register.
    always @(posedge clk)if(!rst)begin
        if(state==READ)row_q<=rows[read_address];
        if(state==LOAD && e_valid && e_keep && shadow_count<MAX_SEGS)
            rows[write_address]<={e_base,e_bytes};
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;bank<=0;active_count<=0;shadow_count<=0;
            active_total<=0;shadow_total<=0;residual<=0;logical_cursor<=0;remaining<=0;
            scan_index<=0;load_errors<=0;entry_started<=0;first_fragment<=0;
            m_op<=0;m_status<=0;m_tag<=0;m_addr<=0;m_bytes<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                m_op<=c_op;m_tag<=c_tag;m_status<=0;m_addr<=0;m_bytes<=0;
                first_fragment<=1;load_errors<=0;scan_index<=0;
                if(c_op==0)begin
                    shadow_count<=0;shadow_total<=0;entry_started<=0;state<=LOAD;
                end else if(c_op==1)begin
                    if(c_bytes==0)begin m_status<=1;state<=ACK;end
                    else if(query_bad)begin m_status<=2;state<=ACK;end
                    else begin
                        residual<=c_offset[TW-1:0];logical_cursor<=c_offset[TW-1:0];
                        remaining<=c_bytes[TW-1:0];state<=READ;
                    end
                end else if(c_op==2)begin active_count<=0;active_total<=0;state<=ACK;end
                else begin m_status<=3;state<=ACK;end
            end
            LOAD:if(e_valid)begin
                load_errors<=incoming_errors;entry_started<=1;
                if(e_keep && shadow_count<MAX_SEGS)begin
                    shadow_count<=shadow_count+1'b1;
                    shadow_total<=shadow_total+{{(TW-LEN_W){1'b0}},e_bytes};
                end
                if(e_last)state<=PUBLISH;
            end
            PUBLISH:begin
                if(load_errors==0)begin
                    bank<=!bank;active_count<=shadow_count;active_total<=shadow_total;
                end else m_status<=4;
                state<=ACK;
            end
            READ:state<=CHECK;
            CHECK:if(residual>={{(TW-LEN_W){1'b0}},row_bytes})begin
                residual<=residual-{{(TW-LEN_W){1'b0}},row_bytes};
                scan_index<=scan_index+1'b1;state<=READ;
            end else begin
                m_addr<=physical_address[ADDR_W-1:0];
                m_bytes<=remaining<available?remaining[LEN_W-1:0]:available[LEN_W-1:0];
                state<=OUTPUT;
            end
            OUTPUT:if(m_ready)begin
                if(m_last)state<=IDLE;
                else begin
                    remaining<=remaining-{{(TW-LEN_W){1'b0}},m_bytes};
                    logical_cursor<=logical_cursor+{{(TW-LEN_W){1'b0}},m_bytes};
                    residual<=0;scan_index<=scan_index+1'b1;first_fragment<=0;state<=READ;
                end
            end
            ACK:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
