// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ram_replay_window #(
    parameter integer CONTEXTS=16,WINDOW_BITS=64,TAG_W=8,
    localparam integer IW=CONTEXTS>1?$clog2(CONTEXTS):1,
    localparam integer SW=WINDOW_BITS>1?$clog2(WINDOW_BITS):1
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_context,input wire [63:0] c_sequence,
    input wire [TAG_W-1:0] c_tag,
    output wire m_valid,input wire m_ready,output reg [2:0] m_op,m_status,
    output reg [31:0] m_context,output reg [63:0] m_sequence,
    output reg [TAG_W-1:0] m_tag,output wire m_accepted,m_marked,
    output reg m_active,output reg [63:0] m_head,
    output reg [WINDOW_BITS-1:0] m_seen
);
    localparam [2:0] IDLE=0,READ=1,EVAL=2,WRITE=3,HOLD=4;
    reg [2:0] state;
    reg [CONTEXTS-1:0] live;
    reg [IW-1:0] index;
    reg [63+WINDOW_BITS:0] rows[0:CONTEXTS-1],row_q;
    wire [63:0] old_head=row_q[WINDOW_BITS+:64];
    wire [WINDOW_BITS-1:0] old_seen=row_q[WINDOW_BITS-1:0];
    wire [63:0] gap=m_sequence-old_head,age=old_head-m_sequence;
    wire [WINDOW_BITS-1:0] one={{(WINDOW_BITS-1){1'b0}},1'b1};
    wire [2:0] classification=!live[index]?3'd0:
        m_sequence>old_head?3'd1:age>=WINDOW_BITS?3'd4:
        old_seen[age[SW-1:0]]?3'd3:3'd2;
    assign c_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==HOLD;
    assign m_accepted=m_op<2 && m_status<3;
    assign m_marked=m_op==0 && m_status<3;
    generate if(CONTEXTS<1 || CONTEXTS>64 || WINDOW_BITS<1 || WINDOW_BITS>256 ||
        TAG_W<1 || TAG_W>32)begin:bad_parameters
        ram_replay_window_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    // Disjoint synchronous read/write phases. Unowned words are never exposed.
    always @(posedge clk)if(!rst)begin
        if(state==READ)row_q<=rows[index];
        if(state==WRITE)rows[index]<={m_head,m_seen};
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;live<=0;index<=0;
            m_op<=0;m_status<=0;m_context<=0;m_sequence<=0;m_tag<=0;
            m_active<=0;m_head<=0;m_seen<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                m_op<=c_op;m_context<=c_context;m_sequence<=c_sequence;m_tag<=c_tag;
                m_status<=0;m_active<=0;m_head<=0;m_seen<=0;
                if(c_op>3)begin m_status<=7;state<=HOLD;end
                else if(c_op==3)begin live<=0;m_status<=5;state<=HOLD;end
                else if(c_context>=CONTEXTS)begin m_status<=6;state<=HOLD;end
                else if(c_op==2)begin
                    live[c_context[IW-1:0]]<=0;m_status<=5;state<=HOLD;
                end else begin index<=c_context[IW-1:0];state<=READ;end
            end
            READ:state<=EVAL;
            EVAL:begin
                m_status<=classification;
                if(m_op==0 && classification<3)begin
                    m_active<=1;
                    if(!live[index])begin m_head<=m_sequence;m_seen<=one;end
                    else if(m_sequence>old_head)begin
                        m_head<=m_sequence;
                        m_seen<=gap>=WINDOW_BITS?one:(old_seen<<gap[SW-1:0])|one;
                    end else begin m_head<=old_head;m_seen<=old_seen|(one<<age[SW-1:0]);end
                    state<=WRITE;
                end else begin
                    m_active<=live[index];
                    m_head<=live[index]?old_head:64'd0;
                    m_seen<=live[index]?old_seen:{WINDOW_BITS{1'b0}};
                    state<=HOLD;
                end
            end
            WRITE:begin live[index]<=1;state<=HOLD;end
            HOLD:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
