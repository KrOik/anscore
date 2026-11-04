// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module exact_binary_permanent #(
    parameter integer N=8,TAG_W=8,
    localparam integer IW=N>1?$clog2(N):1,CW=$clog2(N+1),
    localparam integer FACT=(N>=2?2:1)*(N>=3?3:1)*(N>=4?4:1)*(N>=5?5:1)*
        (N>=6?6:1)*(N>=7?7:1)*(N>=8?8:1)*(N>=9?9:1)*(N>=10?10:1)*(N>=11?11:1)*(N>=12?12:1),
    localparam integer VALUE_W=$clog2(FACT+1),DEPTH=1<<N
)(
    input wire clk,rst,s_valid,output wire s_ready,input wire [N-1:0] s_row,
    input wire s_keep,s_last,s_error,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output reg [VALUE_W-1:0] m_value,
    output wire [2:0] m_error,output wire [CW-1:0] m_rows,output reg [TAG_W-1:0] m_tag
);
    localparam [3:0] CAPTURE=0,INIT=1,MASK_START=2,ROW_READ=3,SCAN=4,
        DP_READ=5,DP_ADD=6,WRITE=7,RESULT_READ=8,RESULT_LOAD=9,OUTPUT=10;
    reg [3:0] state;
    reg [CW-1:0] count;
    reg started;
    reg [2:0] errors;
    reg [N-1:0] mask,row_q;
    reg [IW-1:0] column;
    reg [VALUE_W-1:0] dp_q,acc;
    reg [N-1:0] rows[0:N-1];
    reg [VALUE_W-1:0] dp[0:DEPTH-1];
    function automatic [CW-1:0] population(input [N-1:0] bits);
        integer j;
        begin population=0;for(j=0;j<N;j=j+1)population=population+bits[j];end
    endfunction
    wire [CW-1:0] row_number=population(mask)-1'b1;
    wire [N-1:0] predecessor=mask^(N'(1)<<column);
    wire [VALUE_W:0] widened_sum={1'b0,acc}+{1'b0,dp_q};
    wire [CW-1:0] next_count=count+CW'(s_keep && count<N);
    wire [2:0] accepted_errors=errors|{s_error,(s_keep && count==N),(s_last && next_count<N)};
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUTPUT;
    assign m_error=errors;
    assign m_rows=count;
    generate if(N<1 || N>12 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        exact_binary_permanent_invalid_parameters__see_README rejected();
    end endgenerate
    // Each bank has disjoint write/read phases and a registered read value.
    // Payload and read-q are intentionally unreset; only current ownership reads.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && s_keep && count<N)rows[count]<=s_row;
        if(state==ROW_READ)row_q<=rows[row_number];
        if(state==INIT)dp[0]<=VALUE_W'(1);
        if(state==WRITE)dp[mask]<=acc;
        if(state==DP_READ)dp_q<=dp[predecessor];
        if(state==RESULT_READ)dp_q<=dp[DEPTH-1];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;count<=0;started<=0;errors<=0;m_tag<=0;
            mask<=0;column<=0;acc<=0;m_value<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(!started)begin m_tag<=s_tag;started<=1;end
                count<=next_count;errors<=accepted_errors;
                if(s_last)begin
                    m_value<=0;
                    if(accepted_errors!=0)state<=OUTPUT;
                    else state<=INIT;
                end
            end
            INIT:begin mask<=N'(1);state<=MASK_START;end
            MASK_START:begin column<=0;acc<=0;state<=ROW_READ;end
            ROW_READ:state<=SCAN;
            SCAN:begin
                if(mask[column] && row_q[column])state<=DP_READ;
                else if(column==N-1)state<=WRITE;
                else column<=column+1'b1;
            end
            DP_READ:state<=DP_ADD;
            DP_ADD:begin
                acc<=widened_sum[VALUE_W-1:0];
                if(column==N-1)state<=WRITE;
                else begin column<=column+1'b1;state<=SCAN;end
            end
            WRITE:begin
                if(mask==DEPTH-1)state<=RESULT_READ;
                else begin mask<=mask+1'b1;state<=MASK_START;end
            end
            RESULT_READ:state<=RESULT_LOAD;
            RESULT_LOAD:begin m_value<=dp_q;state<=OUTPUT;end
            OUTPUT:if(m_ready)begin
                state<=CAPTURE;count<=0;started<=0;errors<=0;m_value<=0;m_tag<=0;
            end
            default:state<=CAPTURE;
        endcase
    end
endmodule
