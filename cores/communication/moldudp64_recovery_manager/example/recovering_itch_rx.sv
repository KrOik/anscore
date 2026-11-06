// SPDX-License-Identifier: Apache-2.0
// Existing strict receiver + bounded recovery metadata + 20-byte request header.
`default_nettype none
module recovering_itch_rx #(
    parameter integer REQUEST_MAX=1024,TAG_W=8
)(
    input wire clk,rst,
    input wire cfg_valid,output wire cfg_ready,
    input wire [79:0] cfg_session,input wire [63:0] cfg_next,
    input wire [TAG_W-1:0] cfg_tag,
    input wire retry_valid,output wire retry_ready,input wire [TAG_W-1:0] retry_tag,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,
    input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [7:0] m_type,output wire [63:0] m_sequence,
    output wire [15:0] m_locate,m_tracking,output wire [47:0] m_timestamp,
    output wire [63:0] m_order,m_new_order,output wire [31:0] m_quantity,m_price,
    output wire [63:0] m_stock,output wire [31:0] m_attribution,
    output wire [63:0] m_match,output wire m_sell,m_printable,
    output wire m_price_valid,m_stock_valid,m_attribution_valid,m_match_valid,
    output wire m_last,output wire [TAG_W-1:0] m_tag,
    output wire request_valid,input wire request_ready,output wire [7:0] request_data,
    output wire request_last,output wire [TAG_W-1:0] request_tag,
    output wire rsp_valid,input wire rsp_ready,
    output reg [1:0] rsp_kind,output reg [3:0] rsp_status,rsp_recovery_status,
    output reg [79:0] rsp_session,output reg [63:0] rsp_sequence,
    output reg [15:0] rsp_messages,rsp_events,output reg [63:0] rsp_next,
    output reg rsp_end,output reg [TAG_W-1:0] rsp_tag,
    output reg [63:0] recovery_next,recovery_target,recovery_until,
    output reg recovery_outstanding,recovery_closed,output reg rsp_requested,
    output wire busy
);
    localparam [3:0] IDLE=0,RECEIVE=1,SEND_MGMT=2,WAIT_MGMT=3,
        SEND_ISSUE=4,WAIT_ISSUE=5,REQUEST=6,RESPONSE=7;
    reg [3:0] state,management_op;
    reg [79:0] management_session;
    reg [63:0] management_sequence,management_next;
    reg [15:0] management_messages;
    reg [4:0] byte_index;
    wire rx_cfg_ready,rx_s_ready,rx_rsp_valid;
    wire [3:0] rx_status;
    wire [79:0] rx_session;
    wire [63:0] rx_sequence,rx_next;
    wire [15:0] rx_messages,rx_events;
    wire rx_end;
    wire [TAG_W-1:0] rx_tag;
    wire admission=!rst && state==IDLE;
    wire packet_gate=(admission&&!cfg_valid&&!retry_valid)||(!rst&&state==RECEIVE);
    wire manager_ready,manager_valid,manager_emit;
    wire [3:0] manager_status;
    wire [79:0] manager_session;
    wire [63:0] manager_next,manager_target,manager_until,manager_sequence;
    wire [15:0] manager_count;
    wire manager_outstanding,manager_closed;
    wire [159:0] request_frame={manager_session,manager_sequence,manager_count};
    assign cfg_ready=admission&&rx_cfg_ready;
    assign retry_ready=admission&&!cfg_valid;
    assign s_ready=packet_gate&&rx_s_ready;
    assign request_valid=!rst&&state==REQUEST;
    assign request_data=request_frame[159-byte_index*8-:8];
    assign request_last=byte_index==19;
    assign request_tag=rsp_tag;
    assign rsp_valid=!rst&&state==RESPONSE;
    assign busy=!rst&&state!=IDLE;
    moldudp64_itch_rx #(.MAX_PACKET_BYTES(2048),.TAG_W(TAG_W)) receiver(
        .clk(clk),.rst(rst),.cfg_valid(admission&&cfg_valid),.cfg_ready(rx_cfg_ready),
        .cfg_session(cfg_session),.cfg_next(cfg_next),
        .s_valid(s_valid&&packet_gate),.s_ready(rx_s_ready),.s_data(s_data),
        .s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_type(m_type),.m_sequence(m_sequence),
        .m_locate(m_locate),.m_tracking(m_tracking),.m_timestamp(m_timestamp),
        .m_order(m_order),.m_new_order(m_new_order),.m_quantity(m_quantity),.m_price(m_price),
        .m_stock(m_stock),.m_attribution(m_attribution),.m_match(m_match),.m_sell(m_sell),
        .m_printable(m_printable),.m_price_valid(m_price_valid),.m_stock_valid(m_stock_valid),
        .m_attribution_valid(m_attribution_valid),.m_match_valid(m_match_valid),.m_last(m_last),.m_tag(m_tag),
        .rsp_valid(rx_rsp_valid),.rsp_ready(state==RECEIVE),.rsp_status(rx_status),
        .rsp_session(rx_session),.rsp_sequence(rx_sequence),.rsp_messages(rx_messages),
        .rsp_events(rx_events),.rsp_next(rx_next),.rsp_end(rx_end),.rsp_tag(rx_tag),.busy());
    moldudp64_recovery_manager #(.CONTEXTS(1),.REQUEST_MAX(REQUEST_MAX),.TAG_W(TAG_W)) recovery(
        .clk(clk),.rst(rst),.c_valid(!rst&&(state==SEND_MGMT||state==SEND_ISSUE)),.c_ready(manager_ready),
        .c_op(state==SEND_ISSUE?4'd3:management_op),.c_context(32'd0),.c_session(management_session),
        .c_sequence(management_sequence),.c_next(management_next),.c_messages(management_messages),.c_tag(rsp_tag),
        .r_valid(manager_valid),.r_ready((state==WAIT_MGMT||state==WAIT_ISSUE)?!manager_emit:
            state==REQUEST&&request_ready&&byte_index==19),.r_op(),.r_status(manager_status),
        .r_context(),.r_configured(),.r_session(manager_session),.r_next(manager_next),
        .r_target(manager_target),.r_outstanding(manager_outstanding),.r_until(manager_until),
        .r_closed(manager_closed),.r_emit(manager_emit),.r_request_sequence(manager_sequence),
        .r_request_count(manager_count),.r_tag(),.busy());
    task recovery_snapshot;
        begin
            rsp_recovery_status<=manager_status;recovery_next<=manager_next;
            recovery_target<=manager_target;recovery_until<=manager_until;
            recovery_outstanding<=manager_outstanding;recovery_closed<=manager_closed;
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;management_op<=0;management_session<=0;management_sequence<=0;
            management_next<=0;management_messages<=0;byte_index<=0;
            rsp_kind<=0;rsp_status<=0;rsp_recovery_status<=0;rsp_session<=0;rsp_sequence<=0;
            rsp_messages<=0;rsp_events<=0;rsp_next<=0;rsp_end<=0;rsp_tag<=0;
            recovery_next<=0;recovery_target<=0;recovery_until<=0;
            recovery_outstanding<=0;recovery_closed<=0;rsp_requested<=0;
        end else case(state)
            IDLE:begin
                if(cfg_valid&&cfg_ready)begin
                    rsp_kind<=0;rsp_status<=0;rsp_session<=cfg_session;rsp_sequence<=cfg_next;
                    rsp_messages<=0;rsp_events<=0;rsp_next<=cfg_next;rsp_end<=0;rsp_tag<=cfg_tag;rsp_requested<=0;
                    management_op<=0;management_session<=cfg_session;management_next<=cfg_next;
                    management_sequence<=0;management_messages<=0;state<=SEND_MGMT;
                end else if(retry_valid&&retry_ready)begin
                    rsp_kind<=2;rsp_status<=0;rsp_sequence<=0;rsp_messages<=0;rsp_events<=0;
                    rsp_tag<=retry_tag;rsp_requested<=0;management_op<=4;state<=SEND_MGMT;
                end else if(s_valid&&s_ready)begin rsp_requested<=0;state<=RECEIVE;end
            end
            RECEIVE:if(rx_rsp_valid)begin
                rsp_kind<=1;rsp_status<=rx_status;rsp_session<=rx_session;rsp_sequence<=rx_sequence;
                rsp_messages<=rx_messages;rsp_events<=rx_events;rsp_next<=rx_next;rsp_end<=rx_end;rsp_tag<=rx_tag;
                management_sequence<=rx_sequence;management_next<=rx_next;management_messages<=rx_messages;
                if(rx_status==0)begin management_op<=rx_end?7:2;state<=SEND_MGMT;end
                else if(rx_status==6||rx_status==7)begin management_op<=1;state<=SEND_MGMT;end
                else begin rsp_recovery_status<=0;state<=RESPONSE;end
            end
            SEND_MGMT:if(manager_ready)state<=WAIT_MGMT;
            WAIT_MGMT:if(manager_valid)begin
                recovery_snapshot();
                if(rsp_kind==2)begin rsp_session<=manager_session;rsp_next<=manager_next;rsp_end<=manager_closed;end
                if(manager_emit)begin byte_index<=0;rsp_requested<=1;state<=REQUEST;end
                else if(rsp_kind!=1||management_op==7||(manager_status!=0&&manager_status!=5))state<=RESPONSE;
                else state<=SEND_ISSUE;
            end
            SEND_ISSUE:if(manager_ready)state<=WAIT_ISSUE;
            WAIT_ISSUE:if(manager_valid)begin
                recovery_snapshot();
                if(manager_emit)begin byte_index<=0;rsp_requested<=1;state<=REQUEST;end
                else state<=RESPONSE;
            end
            REQUEST:if(request_ready)begin
                if(byte_index==19)state<=RESPONSE;
                else byte_index<=byte_index+1'b1;
            end
            RESPONSE:if(rsp_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
