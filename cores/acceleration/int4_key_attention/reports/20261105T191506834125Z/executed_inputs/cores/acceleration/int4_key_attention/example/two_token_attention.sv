// SPDX-License-Identifier: Apache-2.0
// Boot-programs K={-1,+1}, V={(-64,+64),(+64,-64)}, score scale=1/32.
`default_nettype none
module two_token_attention (
    input wire clk,rst,input wire q_valid,output wire q_ready,
    input wire [7:0] q_data,q_tag,
    output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
    output wire m_channel,m_last,output wire [7:0] m_tag,
    output wire [2:0] m_error,output wire config_fault
);
    localparam [2:0] BOOT_SEND=0,BOOT_WAIT=1,READY=2,COMMAND=3,QUERY=4,RESULT=5,FAULT=6;
    reg [2:0] state,config_index;
    reg [7:0] query_data,query_tag;
    wire c_ready,c_rsp_valid,cmd_ready,s_ready;
    wire [1:0] c_error;
    wire [15:0] row_index;
    wire score_clip,score_inexact,prob_clip;
    wire [12:0] prob_sum;
    wire [1:0] slot=config_index>=3?config_index-3:config_index;
    wire row=config_index>=3;
    wire [2:0] operation=slot==0?3'd0:slot==1?3'd1:3'd3;
    wire [31:0] data=slot==0?(row?32'h00000001:32'h0000000f):
        slot==2?(row?32'h0000c040:32'h000040c0):32'd0;
    assign q_ready=!rst&&state==READY;
    assign config_fault=state==FAULT;
    assign m_channel=row_index[0];
    int4_key_attention #(.MAX_COLS(1),.MAX_VALUES(2),.TAG_W(8)) attention (
        .clk(clk),.rst(rst),.c_valid(state==BOOT_SEND),.c_ready(c_ready),.c_op(operation),
        .c_row({15'd0,row}),.c_word(16'd0),.c_data(data),.c_bias(32'sd0),
        .c_scale(16'd1),.c_shift(5'd5),.c_zero(8'sd0),
        .c_rsp_valid(c_rsp_valid),.c_rsp_ready(state==BOOT_WAIT),.c_error(c_error),
        .cmd_valid(state==COMMAND),.cmd_ready(cmd_ready),.cmd_tokens(16'd2),.cmd_cols(16'd1),
        .cmd_values(16'd2),.cmd_x_zero(8'd128),.cmd_tag(query_tag),
        .s_valid(state==QUERY),.s_ready(s_ready),.s_data(query_data),.s_last(1'b1),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_index(row_index),.m_last(m_last),
        .m_tag(m_tag),.m_error(m_error),.m_score_clip(score_clip),.m_score_inexact(score_inexact),
        .m_prob_clip(prob_clip),.m_prob_sum(prob_sum));
    always @(posedge clk)begin
        if(rst)begin state<=BOOT_SEND;config_index<=0;query_data<=0;query_tag<=0;end
        else begin
            case(state)
                BOOT_SEND:if(c_ready)state<=BOOT_WAIT;
                BOOT_WAIT:if(c_rsp_valid)begin
                    if(c_error!=0)state<=FAULT;
                    else if(config_index==5)state<=READY;
                    else begin config_index<=config_index+1'b1;state<=BOOT_SEND;end
                end
                READY:if(q_valid)begin query_data<=q_data;query_tag<=q_tag;state<=COMMAND;end
                COMMAND:if(cmd_ready)state<=QUERY;
                QUERY:if(s_ready)state<=RESULT;
                RESULT:begin end
                FAULT:begin end
                default:state<=FAULT;
            endcase
            if(m_valid&&m_ready&&m_last)state<=READY;
        end
    end
endmodule
`default_nettype wire
