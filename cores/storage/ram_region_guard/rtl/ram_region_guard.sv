// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ram_region_guard #(
    parameter integer ADDR_W=32,SLOTS=16,TAG_W=8,
    localparam integer IW=SLOTS>1?$clog2(SLOTS):1,
    localparam integer CW=$clog2(SLOTS+1),RW=2*ADDR_W+3
)(
    input wire clk,rst,c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_slot,input wire [63:0] c_base,input wire [64:0] c_bytes,
    input wire [2:0] c_perm,c_access,input wire [TAG_W-1:0] c_tag,
    output wire m_valid,input wire m_ready,output reg [2:0] m_op,
    output reg [3:0] m_status,output reg [TAG_W-1:0] m_tag,
    output wire m_allow,m_found,output wire [31:0] m_slot,
    output wire [ADDR_W-1:0] m_base,output wire [ADDR_W:0] m_bytes,
    output wire [2:0] m_perm,output reg [CW-1:0] m_count
);
    localparam [2:0] IDLE=0,READ=1,CHECK=2,WRITE=3,ACK=4;
    localparam [65:0] LIMIT=66'd1<<ADDR_W;
    reg [2:0] state,request_access,out_perm;
    reg [SLOTS-1:0] live;
    reg [IW-1:0] index;
    reg [CW-1:0] count;
    reg [RW-1:0] rules[0:SLOTS-1],row_q;
    reg found;
    // Descriptor registers are pending CHECK/SET operands while output is invalid.
    reg [ADDR_W-1:0] out_base,out_last;
    wire [65:0] full_end={2'b0,c_base}+{1'b0,c_bytes};
    wire [65:0] full_last=full_end-66'd1;
    wire bad_range=c_bytes==0 || {2'b0,c_base}>=LIMIT || full_end>LIMIT;
    wire [ADDR_W-1:0] row_base=row_q[RW-1:ADDR_W+3],row_last=row_q[ADDR_W+2:3];
    wire [2:0] row_perm=row_q[2:0];
    assign c_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==ACK;
    assign m_allow=m_valid && m_op==0 && m_status==0;
    assign m_found=m_valid && found;
    assign m_slot=m_found?index:32'd0;
    assign m_base=m_found?out_base:{ADDR_W{1'b0}};
    assign m_bytes=m_found?({1'b0,out_last}-{1'b0,out_base}+{{ADDR_W{1'b0}},1'b1}):{(ADDR_W+1){1'b0}};
    assign m_perm=m_found?out_perm:3'd0;
    generate if(ADDR_W<1 || ADDR_W>64 || SLOTS<1 || SLOTS>64 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        ram_region_guard_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    // One owned synchronous read or one write, in disjoint phases; no payload reset.
    always @(posedge clk)if(!rst)begin
        if(state==READ && live[index])row_q<=rules[index];
        if(state==WRITE)rules[index]<={out_base,out_last,out_perm};
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;request_access<=0;out_perm<=0;live<=0;index<=0;count<=0;
            found<=0;out_base<=0;out_last<=0;m_op<=0;m_status<=0;m_tag<=0;m_count<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                m_op<=c_op;m_status<=0;m_tag<=c_tag;m_count<=count;
                found<=0;out_base<=0;out_last<=0;out_perm<=0;state<=ACK;
                if(c_op>5)m_status<=4;
                else if((c_op==1 || c_op==2 || c_op==3) && c_slot>=SLOTS)m_status<=5;
                else if((c_op==0 || c_op==1) && bad_range)m_status<=6;
                else if(c_op==0 && c_access==0)m_status<=7;
                else case(c_op)
                    0:begin
                        index<=0;out_base<=c_base[ADDR_W-1:0];out_last<=full_last[ADDR_W-1:0];
                        request_access<=c_access;state<=READ;
                    end
                    1:begin
                        index<=c_slot[IW-1:0];out_base<=c_base[ADDR_W-1:0];out_last<=full_last[ADDR_W-1:0];
                        out_perm<=c_perm;state<=WRITE;
                    end
                    2:begin
                        if(!live[c_slot[IW-1:0]])m_status<=8;
                        else begin live[c_slot[IW-1:0]]<=0;count<=count-1'b1;m_count<=count-1'b1;end
                    end
                    3:begin
                        if(!live[c_slot[IW-1:0]])m_status<=8;
                        else begin index<=c_slot[IW-1:0];state<=READ;end
                    end
                    4:begin live<=0;count<=0;m_count<=0;end
                    5:state<=ACK;
                    default:state<=ACK;
                endcase
            end
            READ:state<=CHECK;
            CHECK:begin
                if(m_op==3 || (live[index] && out_base<=row_last && row_base<=out_last))begin
                    found<=1;out_base<=row_base;out_last<=row_last;out_perm<=row_perm;state<=ACK;
                    if(m_op==0)begin
                        if(out_base<row_base || out_last>row_last)m_status<=2;
                        else if((request_access & ~row_perm)!=0)m_status<=3;
                    end
                end else if(index==SLOTS-1)begin
                    m_status<=1;out_base<=0;out_last<=0;out_perm<=0;state<=ACK;
                end else begin index<=index+1'b1;state<=READ;end
            end
            WRITE:begin
                live[index]<=1;count<=count+!live[index];m_count<=count+!live[index];found<=1;state<=ACK;
            end
            ACK:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
