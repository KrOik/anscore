// SPDX-License-Identifier: Apache-2.0
`default_nettype none
// Actual composition with the B45 canonical Soup receiver and its upstream FIFO.
// Public result retirement is the only acknowledgement of the Soup completion.
module soupbintcp_ouch42_rx #(
    parameter integer FIFO_DEPTH=128, parameter integer TAG_W=8
)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_data, input wire [TAG_W-1:0] s_tag,
    output wire r_valid, input wire r_ready,
    output wire [2:0] r_soup_status, output wire [7:0] r_soup_type,
    output wire [7:0] r_soup_reason, output wire [15:0] r_soup_length,
    output wire [63:0] r_sequence, output wire [63:0] r_next,
    output wire [79:0] r_session, output wire [TAG_W-1:0] r_tag,
    output wire r_logged, output wire r_closed, output wire r_faulted,
    output wire r_exhausted, output wire r_is_ouch,
    output wire [2:0] r_ouch_status, output wire [7:0] r_ouch_type,
    output wire [15:0] r_ouch_length, output wire [719:0] r_event
);
    wire mv,mr,ml,sv,sr,dv,dr;
    wire [7:0] md,dt;
    wire [TAG_W-1:0] mt;
    wire [2:0] ds;
    wire [15:0] payload_bytes,dl;
    wire [719:0] de;
    wire data_frame=r_soup_type==8'h53 && r_soup_status==0;
    wire nonempty=payload_bytes!=0;
    // Nonempty payload decoding and Soup completion join at one public result.
    // Empty sequenced frames never invent a decoder input beat.
    assign r_valid=sv && (!data_frame || !nonempty || dv);
    assign sr=r_ready && (!data_frame || !nonempty || dv);
    assign dr=r_ready && sv && data_frame && nonempty;
    assign r_is_ouch=sv && data_frame;
    assign r_ouch_status=!data_frame ? 3'd0 : (!nonempty ? 3'd2 : ds);
    assign r_ouch_type=data_frame && nonempty ? dt : 8'd0;
    assign r_ouch_length=data_frame && nonempty ? dl : 16'd0;
    assign r_event=data_frame && nonempty && dv ? de : 720'd0;
    soupbintcp_session_rx #(.FIFO_DEPTH(FIFO_DEPTH),.TAG_W(TAG_W)) soup (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_tag(s_tag),
        .m_valid(mv),.m_ready(mr),.m_data(md),.m_last(ml),
        .m_sequence(),.m_session(),.m_tag(mt),
        .r_valid(sv),.r_ready(sr),.r_status(r_soup_status),.r_type(r_soup_type),
        .r_reason(r_soup_reason),.r_length(r_soup_length),.r_payload_bytes(payload_bytes),
        .r_sequence(r_sequence),.r_next(r_next),.r_session(r_session),.r_tag(r_tag),
        .r_logged(r_logged),.r_closed(r_closed),.r_faulted(r_faulted),.r_exhausted(r_exhausted)
    );
    nasdaq_ouch42_server_rx #(.TAG_W(TAG_W)) decoder (
        .clk(clk),.rst(rst),.s_valid(mv),.s_ready(mr),.s_data(md),.s_last(ml),.s_tag(mt),
        .r_valid(dv),.r_ready(dr),.r_status(ds),.r_type(dt),.r_length(dl),.r_tag(),.r_event(de)
    );
endmodule
`default_nettype wire
