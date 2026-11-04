// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module exact_binomial #(
    parameter integer MAX_N=32,
    parameter integer TAG_W=8
)(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire [63:0] s_n,s_k,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg [MAX_N-1:0] m_value,
    output reg m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer KMAX=MAX_N/2;
    localparam integer NW=(MAX_N<1)?1:$clog2(MAX_N+1);
    localparam integer KW=(KMAX<1)?1:$clog2(KMAX+1);
    localparam [3:0] IDLE=0,INIT=1,ROW_SETUP=2,READ_CUR=3,READ_PREV=4,
                     WRITE_SUM=5,RESULT_READ=6,RESULT_LOAD=7,OUTPUT=8;
    generate if(MAX_N<1 || MAX_N>64 || TAG_W<1 || TAG_W>32)begin:g_invalid
        exact_binomial_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    reg [3:0] state;
    reg [NW-1:0] n,row;
    reg [KW-1:0] k,j;
    reg [MAX_N-1:0] coef[0:KMAX];
    reg [MAX_N-1:0] current,row_q;
    wire [NW-1:0] other=s_n[NW-1:0]-s_k[NW-1:0];
    wire [NW-1:0] selected_k=(s_k[NW-1:0]<other)?s_k[NW-1:0]:other;
    wire [MAX_N:0] sum_extended={1'b0,current}+{1'b0,row_q};
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==OUTPUT;

    // Single synchronous port. Every current-owner word is initialized first.
    // Reads and writes occur in disjoint states, with no collision assumption.
    always @(posedge clk)if(!rst)begin
        if(state==INIT)coef[j]<=(j==0)?1:0;
        else if(state==WRITE_SUM)coef[j]<=sum_extended[MAX_N-1:0];
        if(state==READ_CUR)row_q<=coef[j];
        else if(state==READ_PREV)row_q<=coef[j-1'b1];
        else if(state==RESULT_READ)row_q<=coef[k];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;m_value<=0;m_error<=0;m_tag<=0;
        end else case(state)
            IDLE:if(s_valid)begin
                m_tag<=s_tag;m_value<=0;m_error<=0;
                // Preserve full64 priority before any private narrowing.
                if(s_n>MAX_N)begin m_error<=1;state<=OUTPUT;end
                else if(s_k>s_n)state<=OUTPUT;
                else if(s_k==0 || s_k==s_n)begin m_value<=1;state<=OUTPUT;end
                else begin
                    n<=s_n[NW-1:0];k<=selected_k[KW-1:0];j<=0;
                    state<=INIT;
                end
            end
            INIT:if(j==k)begin row<=1;state<=ROW_SETUP;end else j<=j+1'b1;
            ROW_SETUP:begin j<=(row<k)?row[KW-1:0]:k;state<=READ_CUR;end
            READ_CUR:state<=READ_PREV;
            READ_PREV:begin current<=row_q;state<=WRITE_SUM;end
            WRITE_SUM:begin
                if(j==1)begin
                    if(row==n)state<=RESULT_READ;
                    else begin row<=row+1'b1;state<=ROW_SETUP;end
                end else begin j<=j-1'b1;state<=READ_CUR;end
            end
            RESULT_READ:state<=RESULT_LOAD;
            RESULT_LOAD:begin m_value<=row_q;state<=OUTPUT;end
            OUTPUT:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
