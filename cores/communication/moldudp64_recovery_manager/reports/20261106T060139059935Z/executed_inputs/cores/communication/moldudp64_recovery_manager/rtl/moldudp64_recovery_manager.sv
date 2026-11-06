// SPDX-License-Identifier: Apache-2.0
// Original bounded MoldUDP64 request lifecycle. No payload buffering/reordering.
`default_nettype none
module moldudp64_recovery_manager #(
    parameter integer CONTEXTS=16, REQUEST_MAX=1024, TAG_W=8
) (
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [3:0] c_op,
    input wire [31:0] c_context,input wire [79:0] c_session,
    input wire [63:0] c_sequence,c_next,input wire [15:0] c_messages,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output reg [3:0] r_op,r_status,
    output reg [31:0] r_context,output reg r_configured,
    output reg [79:0] r_session,output reg [63:0] r_next,r_target,
    output reg r_outstanding,output reg [63:0] r_until,output reg r_closed,
    output reg r_emit,output reg [63:0] r_request_sequence,
    output reg [15:0] r_request_count,output reg [TAG_W-1:0] r_tag,
    output wire busy
);
    localparam integer N=(CONTEXTS>=1&&CONTEXTS<=32)?CONTEXTS:1;
    localparam integer IW=N>1?$clog2(N):1;
    localparam [3:0] CONFIG=0,HINT=1,PROGRESS=2,ISSUE=3,RETRY=4,
        GET=5,CLEAR_CTX=6,END_SESSION=7,CLEAR_ALL=8;
    localparam [3:0] OK=0,NOT_CONFIGURED=1,BAD_CONTEXT=2,BAD_RANGE=3,
        STALE_PROGRESS=4,NO_ADVANCE=5,OUTSTANDING=6,NO_OUTSTANDING=7,
        CLOSED=8,BAD_OP=9,BACKEND_FAULT=10;
    localparam [2:0] IDLE=0,READ=1,READ_WAIT=2,EVAL=3,WRITE=4,WRITE_WAIT=5,HOLD=6;
    localparam [63:0] REQUEST_LIMIT=REQUEST_MAX;
    generate if(CONTEXTS<1||CONTEXTS>32||REQUEST_MAX<1||REQUEST_MAX>65534||TAG_W<1||TAG_W>32)begin: invalid
        moldudp64_recovery_manager_invalid_parameters__see_README rejected();
    end endgenerate
    reg [2:0] state;
    reg [N-1:0] configured;
    reg [IW-1:0] index;
    reg [3:0] op;
    reg [63:0] sequence_q,next_q;
    reg [15:0] messages;
    reg [279:0] row,candidate;
    wire old_closed=row[273],old_outstanding=row[272];
    wire [79:0] old_session=row[271:192];
    wire [63:0] old_next=row[191:128],old_target=row[127:64],old_until=row[63:0];
    wire [64:0] hint_end={1'b0,sequence_q}+
        ((messages==0||messages==16'hffff)?65'd0:{49'd0,messages});
    wire [63:0] missing=old_target-old_next;
    wire [63:0] retry_missing=old_until-old_next;
    wire [15:0] issue_count=(missing>REQUEST_LIMIT)?REQUEST_MAX:missing[15:0];
    wire [64:0] issue_end={1'b0,old_next}+{49'd0,issue_count};
    wire bad_row=(row[279:274]!=0 || old_target<old_next ||
        (old_outstanding&&(old_until<=old_next||old_until>old_target||retry_missing>REQUEST_LIMIT)) ||
        (!old_outstanding&&old_until!=0) || (old_closed&&(old_outstanding||old_target!=old_next)));
    wire mem_ready,mem_valid,mem_error;
    wire [279:0] mem_data;
    cip_sync_sp_ram #(.DATA_WIDTH(280),.ADDR_WIDTH(IW),.DEPTH(N)) storage(
        .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(!rst&&(state==READ||state==WRITE)),
        .req_ready(mem_ready),.req_write(state==WRITE),.req_addr(index),
        .req_wdata(candidate),.req_wstrb(35'h7ffffffff),.rsp_valid(mem_valid),
        .rsp_ready(state==READ_WAIT||state==WRITE_WAIT),.rsp_rdata(mem_data),.rsp_error(mem_error));
    assign c_ready=!rst&&state==IDLE;
    assign r_valid=!rst&&state==HOLD;
    assign busy=!rst&&state!=IDLE;
    task snapshot(input [279:0] value);
        begin
            r_configured<=1;r_closed<=value[273];r_outstanding<=value[272];
            r_session<=value[271:192];r_next<=value[191:128];
            r_target<=value[127:64];r_until<=value[63:0];
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;configured<=0;index<=0;op<=0;sequence_q<=0;next_q<=0;messages<=0;row<=0;candidate<=0;
            r_op<=0;r_status<=0;r_context<=0;r_configured<=0;r_session<=0;r_next<=0;r_target<=0;
            r_outstanding<=0;r_until<=0;r_closed<=0;r_emit<=0;r_request_sequence<=0;r_request_count<=0;r_tag<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                op<=c_op;sequence_q<=c_sequence;next_q<=c_next;messages<=c_messages;
                r_op<=c_op;r_context<=c_context;r_tag<=c_tag;r_status<=OK;
                r_configured<=0;r_session<=0;r_next<=0;r_target<=0;r_outstanding<=0;r_until<=0;r_closed<=0;
                r_emit<=0;r_request_sequence<=0;r_request_count<=0;index<=c_context[IW-1:0];
                if(c_op>CLEAR_ALL)begin r_status<=BAD_OP;state<=HOLD;end
                else if(c_op==CLEAR_ALL)begin configured<=0;state<=HOLD;end
                else if(c_context>=N)begin r_status<=BAD_CONTEXT;state<=HOLD;end
                else if(c_op==CLEAR_CTX)begin configured[c_context]<=0;state<=HOLD;end
                else if(c_op==CONFIG)begin
                    candidate<={6'd0,1'b0,1'b0,c_session,c_next,c_next,64'd0};state<=WRITE;
                end else if(!configured[c_context])begin r_status<=NOT_CONFIGURED;state<=HOLD;end
                else state<=READ;
            end
            READ:if(mem_ready)state<=READ_WAIT;
            READ_WAIT:if(mem_valid)begin
                if(mem_error)begin r_status<=BACKEND_FAULT;state<=HOLD;end
                else begin row<=mem_data;state<=EVAL;end
            end
            EVAL:begin
                snapshot(row);
                if(bad_row)begin r_configured<=0;r_session<=0;r_next<=0;r_target<=0;
                    r_outstanding<=0;r_until<=0;r_closed<=0;r_status<=BACKEND_FAULT;state<=HOLD;end
                else if(op==GET)state<=HOLD;
                else if(op==END_SESSION)begin
                    candidate<={6'd0,1'b1,1'b0,old_session,old_next,old_next,64'd0};state<=WRITE;
                end else if(old_closed)begin r_status<=CLOSED;state<=HOLD;end
                else case(op)
                    HINT:if(hint_end[64])begin r_status<=BAD_RANGE;state<=HOLD;end
                        else if(hint_end[63:0]<=old_target)begin r_status<=NO_ADVANCE;state<=HOLD;end
                        else begin
                            candidate<={6'd0,old_closed,old_outstanding,old_session,old_next,hint_end[63:0],old_until};state<=WRITE;
                        end
                    PROGRESS:if(next_q<old_next)begin r_status<=STALE_PROGRESS;state<=HOLD;end
                        else if(next_q==old_next)state<=HOLD;
                        else begin
                            // Any real prefix progress enables a new request for
                            // the suffix: one server UDP reply may be shorter than requested.
                            candidate<={6'd0,old_closed,1'b0,old_session,next_q,
                                (next_q>old_target)?next_q:old_target,64'd0};state<=WRITE;
                        end
                    ISSUE:if(old_outstanding)begin r_status<=OUTSTANDING;state<=HOLD;end
                        else if(old_target==old_next)begin r_status<=NO_ADVANCE;state<=HOLD;end
                        else begin
                            candidate<={6'd0,old_closed,1'b1,old_session,old_next,old_target,issue_end[63:0]};
                            r_emit<=1;r_request_sequence<=old_next;r_request_count<=issue_count;state<=WRITE;
                        end
                    RETRY:if(!old_outstanding)begin r_status<=NO_OUTSTANDING;state<=HOLD;end
                        else begin
                            r_emit<=1;r_request_sequence<=old_next;r_request_count<=retry_missing[15:0];state<=HOLD;
                        end
                    default:begin r_status<=BAD_OP;state<=HOLD;end
                endcase
            end
            WRITE:if(mem_ready)state<=WRITE_WAIT;
            WRITE_WAIT:if(mem_valid)begin
                if(mem_error)begin r_status<=BACKEND_FAULT;r_emit<=0;r_request_sequence<=0;r_request_count<=0;state<=HOLD;end
                else begin configured[index]<=1;snapshot(candidate);state<=HOLD;end
            end
            HOLD:if(r_ready)state<=IDLE;
            default:begin r_status<=BACKEND_FAULT;r_emit<=0;state<=HOLD;end
        endcase
    end
endmodule
`default_nettype wire
