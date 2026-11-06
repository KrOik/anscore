// SPDX-License-Identifier: Apache-2.0
`default_nettype none
// One complete, nonempty OUCH message per s_last-delimited frame.
// The fixed-size byte cache has no reset requirement: no stale byte is exposed.
module nasdaq_ouch42_server_rx #(parameter integer TAG_W=8)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_data, input wire s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire r_valid, input wire r_ready,
    output wire [2:0] r_status, output wire [7:0] r_type,
    output wire [15:0] r_length, output wire [TAG_W-1:0] r_tag,
    output reg [719:0] r_event
);
    generate if (TAG_W<1 || TAG_W>32) begin : bad_parameters
        OUCH42_REQUIRES_TAG1_TO32 invalid_parameters();
    end endgenerate
    localparam [1:0] RECEIVE=0, CHECK=1, RESULT=2;
    localparam [2:0] OK=0, BAD_TYPE=1, BAD_LENGTH=2, BAD_FIELD=3;
    reg [1:0] state;
    reg [639:0] frame;
    reg [15:0] count;
    reg [TAG_W-1:0] tag_reg;
    reg [2:0] status_reg;
    wire [7:0] message_type=frame[639:632];
    reg [15:0] required_length;
    reg [2:0] checked_status;
    wire [7:0] side=frame[455:448];     // byte 23
    wire [7:0] order_state=frame[127:120]; // byte 64
    wire [7:0] cancel_reason=frame[423:416]; // byte 27
    wire [7:0] reject_reason=frame[455:448]; // byte 23
    wire cancel_alpha=cancel_reason>=8'h41 && cancel_reason<=8'h5a;
    wire reject_alpha=(reject_reason>=8'h41 && reject_reason<=8'h5a) ||
                      (reject_reason>=8'h61 && reject_reason<=8'h7a);
    always @* begin
        required_length=0;
        case (message_type)
            8'h53: required_length=10;
            8'h41: required_length=66;
            8'h55: required_length=80;
            8'h43: required_length=28;
            8'h45: required_length=40;
            8'h4a: required_length=24;
            default: required_length=0;
        endcase
        checked_status=OK;
        if (required_length==0) checked_status=BAD_TYPE;
        else if (count!=required_length) checked_status=BAD_LENGTH;
        else case (message_type)
            8'h53: if (frame[567:560]!=8'h53 && frame[567:560]!=8'h45)
                       checked_status=BAD_FIELD;
            8'h41,8'h55: begin
                if (side!=8'h42 && side!=8'h53 && side!=8'h54 && side!=8'h45)
                    checked_status=BAD_FIELD;
                if (order_state!=8'h4c && order_state!=8'h44) checked_status=BAD_FIELD;
            end
            8'h43: if (!cancel_alpha) checked_status=BAD_FIELD;
            8'h4a: if (!reject_alpha) checked_status=BAD_FIELD;
            default: begin end
        endcase
    end
    assign s_ready=!rst && state==RECEIVE;
    assign r_valid=!rst && state==RESULT;
    assign r_status=status_reg;
    assign r_type=message_type;
    assign r_length=count;
    assign r_tag=tag_reg;

    // Event ABI is documented in README. Every absent field is explicitly zero.
    always @* begin
        r_event=720'd0;
        if (r_valid && status_reg==OK) begin
            r_event[719:656]=frame[631:568]; // timestamp, bytes 1..8
            if (message_type==8'h53) r_event[79:72]=frame[567:560];
            else r_event[655:544]=frame[567:456]; // current token, bytes 9..22
            case (message_type)
                8'h41,8'h55: begin
                    r_event[431:96]=frame[455:120]; // common bytes 23..64
                    if (message_type==8'h41) r_event[95:88]=frame[119:112];
                    else begin
                        r_event[543:432]=frame[119:8]; // previous token, bytes 65..78
                        r_event[95:88]=frame[7:0];
                    end
                end
                8'h43: begin
                    r_event[423:392]=frame[455:424]; // decrement shares
                    r_event[87:80]=frame[423:416];
                end
                8'h45: begin
                    r_event[423:392]=frame[455:424]; // executed shares
                    r_event[327:296]=frame[423:392]; // execution price
                    r_event[71:64]=frame[391:384];
                    r_event[63:0]=frame[383:320];
                end
                8'h4a: r_event[87:80]=frame[455:448];
                default: begin end
            endcase
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            state<=RECEIVE; count<=0; tag_reg<=0; status_reg<=OK;
        end else begin
            if (s_valid && s_ready) begin
                if (count==0) tag_reg<=s_tag;
                if (count<16'd80) frame[639-8*count[6:0] -: 8]<=s_data;
                // Saturation allows an arbitrarily long frame to drain without wrap.
                if (count!=16'hffff) count<=count+16'd1;
                if (s_last) state<=CHECK;
            end
            if (state==CHECK) begin status_reg<=checked_status; state<=RESULT; end
            if (r_valid && r_ready) begin state<=RECEIVE; count<=0; end
        end
    end
endmodule
`default_nettype wire
