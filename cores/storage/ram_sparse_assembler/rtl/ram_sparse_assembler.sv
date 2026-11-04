// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ram_sparse_assembler #(
    parameter integer DEPTH=64,DATA_W=8,TAG_W=8,
    localparam integer AW=DEPTH>1?$clog2(DEPTH):1,
    localparam integer CW=$clog2(DEPTH+1)
)(
    input wire clk,rst,c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [63:0] c_length,c_offset,input wire [DATA_W-1:0] c_data,
    input wire [TAG_W-1:0] c_tag,
    output wire m_valid,input wire m_ready,output reg [2:0] m_op,m_status,
    output reg [TAG_W-1:0] m_tag,output wire m_keep,m_first,m_last,
    output wire [AW-1:0] m_index,output reg [DATA_W-1:0] m_data,
    output reg [CW-1:0] m_total,m_filled
);
    localparam [2:0] IDLE=0,STORE=1,DUP_READ=2,DUP_CHECK=3,ACK=4,
        REPLAY_READ=5,REPLAY_LOAD=6,DATA_OUT=7;
    reg [2:0] state;
    reg [DEPTH-1:0] owned;
    reg [AW-1:0] index;
    reg [CW-1:0] length,filled;
    reg [DATA_W-1:0] words[0:DEPTH-1],row_q;
    assign c_ready=!rst && state==IDLE;
    assign m_valid=!rst && (state==ACK || state==DATA_OUT);
    assign m_keep=!rst && state==DATA_OUT;
    assign m_first=m_valid && (!m_keep || index==0);
    assign m_last=m_valid && (!m_keep || index==length-1'b1);
    assign m_index=m_keep?index:{AW{1'b0}};
    generate if(DEPTH<1 || DEPTH>256 || DATA_W<1 || DATA_W>64 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        ram_sparse_assembler_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    // The output-data register doubles as the pending PUT operand while invalid.
    // Reads and writes are disjoint; no collision mode or payload reset is used.
    always @(posedge clk)if(!rst)begin
        if(state==STORE)words[index]<=m_data;
        if(state==DUP_READ || state==REPLAY_READ)row_q<=words[index];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;owned<=0;index<=0;length<=0;filled<=0;
            m_op<=0;m_status<=0;m_tag<=0;m_data<=0;m_total<=0;m_filled<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                m_op<=c_op;m_tag<=c_tag;m_status<=0;m_data<=0;
                m_total<=length;m_filled<=filled;
                if(c_op>4)begin m_status<=7;state<=ACK;end
                else case(c_op)
                    0:begin
                        if(length!=0)m_status<=5;
                        else if(c_length==0 || c_length>DEPTH)m_status<=6;
                        else begin
                            length<=c_length[CW-1:0];filled<=0;owned<=0;
                            m_total<=c_length[CW-1:0];m_filled<=0;
                        end
                        state<=ACK;
                    end
                    1:begin
                        if(length==0)begin m_status<=4;state<=ACK;end
                        else if(c_offset>=length)begin m_status<=6;state<=ACK;end
                        else begin
                            index<=c_offset[AW-1:0];m_data<=c_data;
                            state<=owned[c_offset[AW-1:0]]?DUP_READ:STORE;
                        end
                    end
                    2:begin
                        if(length==0)begin m_status<=4;state<=ACK;end
                        else if(filled!=length)begin m_status<=3;state<=ACK;end
                        else begin index<=0;state<=REPLAY_READ;end
                    end
                    3:begin
                        length<=0;filled<=0;owned<=0;m_total<=0;m_filled<=0;state<=ACK;
                    end
                    4:state<=ACK;
                    default:state<=ACK;
                endcase
            end
            STORE:begin
                owned[index]<=1;filled<=filled+1'b1;m_filled<=filled+1'b1;
                m_data<=0;state<=ACK;
            end
            DUP_READ:state<=DUP_CHECK;
            DUP_CHECK:begin m_status<=row_q==m_data?3'd1:3'd2;m_data<=0;state<=ACK;end
            ACK:if(m_ready)state<=IDLE;
            REPLAY_READ:state<=REPLAY_LOAD;
            REPLAY_LOAD:begin m_data<=row_q;state<=DATA_OUT;end
            DATA_OUT:if(m_ready)begin
                if(m_last)begin length<=0;filled<=0;owned<=0;state<=IDLE;end
                else begin index<=index+1'b1;state<=REPLAY_READ;end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
