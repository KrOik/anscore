// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Strict signed LIS, serial lower-bound tail search and predecessor traceback.
module longest_increasing_subsequence #(
    parameter integer VALUE_W = 16,
    parameter integer MAX_SAMPLES = 64,
    parameter integer TAG_W = 8,
    localparam integer IW = (MAX_SAMPLES > 1) ? $clog2(MAX_SAMPLES) : 1,
    localparam integer CW = (MAX_SAMPLES > 0) ? $clog2(MAX_SAMPLES+1) : 1
)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire signed [VALUE_W-1:0] s_value,
    input wire s_keep, input wire s_first, input wire s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg signed [VALUE_W-1:0] m_value,
    output reg [IW-1:0] m_index, output reg [IW-1:0] m_rank,
    output reg [CW-1:0] m_length, output reg [CW-1:0] m_count,
    output reg m_keep, output reg m_first, output reg m_last,
    output reg [TAG_W-1:0] m_tag, output reg [1:0] m_errors
);
    generate if (VALUE_W<1 || VALUE_W>32 || MAX_SAMPLES<1 ||
                 MAX_SAMPLES>256 || TAG_W<1 || TAG_W>32) begin: invalid
        longest_increasing_subsequence_invalid_parameters__see_README bad();
    end endgenerate
    localparam integer MW=VALUE_W+IW;
    localparam [3:0] CAPTURE=0, SEARCH=1, COMPARE=2, PREV=3,
        WRITE=4, FINISH=5, TRACE_START=6, TRACE_READ=7, TRACE_SAVE=8,
        OUT_READ=9, OUT_LOAD=10, HOLD=11;
    reg [3:0] state;
    reg [MW-1:0] tails [0:MAX_SAMPLES-1];
    reg [MW-1:0] history [0:MAX_SAMPLES-1];
    reg [MW-1:0] witness [0:MAX_SAMPLES-1];
    reg [MW-1:0] tail_q, history_q, witness_q;
    reg signed [VALUE_W-1:0] current_value;
    reg [IW-1:0] current_index, predecessor, trace_index, out_pos;
    reg [CW-1:0] count, length, lo, hi, mid, position, remaining;
    reg frame_open, pending_last;
    reg [TAG_W-1:0] tag;
    reg [1:0] errors;
    wire [CW:0] mid_sum={1'b0,lo}+{1'b0,hi};
    wire [CW-1:0] midpoint=mid_sum[CW:1];
    wire [1:0] offered_errors=errors |
        ((s_first != !frame_open) ? 2'b01 : 2'b00) |
        ((s_keep && count==MAX_SAMPLES) ? 2'b10 : 2'b00);
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;
    always @(posedge clk) begin
        if (rst) begin
            state<=CAPTURE; count<=0; length<=0; lo<=0; hi<=0;
            mid<=0; position<=0; remaining<=0;
            frame_open<=0; pending_last<=0; tag<=0; errors<=0;
            current_value<=0; current_index<=0; predecessor<=0;
            trace_index<=0; out_pos<=0;
            tail_q<=0; history_q<=0; witness_q<=0;
            m_value<=0; m_index<=0; m_rank<=0; m_length<=0; m_count<=0;
            m_keep<=0; m_first<=0; m_last<=0; m_tag<=0; m_errors<=0;
        end else begin
            case (state)
                CAPTURE: if (s_valid) begin
                    if (!frame_open) tag<=s_tag;
                    frame_open<=1;
                    errors<=offered_errors;
                    if (offered_errors!=0 || !s_keep) begin
                        // Keep overflow detection independent of earlier marker errors.
                        if (s_keep && count<MAX_SAMPLES) count<=count+1'b1;
                        if (s_last) state<=FINISH;
                    end else begin
                        current_value<=s_value;
                        current_index<=count[IW-1:0];
                        pending_last<=s_last;
                        lo<=0; hi<=length; state<=SEARCH;
                    end
                end
                SEARCH: begin
                    if (lo<hi) begin
                        mid<=midpoint;
                        tail_q<=tails[midpoint];
                        state<=COMPARE;
                    end else begin
                        position<=lo;
                        if (lo==0) begin predecessor<=0; state<=WRITE; end
                        else begin tail_q<=tails[lo-1'b1]; state<=PREV; end
                    end
                end
                COMPARE: begin
                    // Lower bound >= current; equal samples never extend length.
                    if ($signed(tail_q[MW-1:IW]) < current_value) lo<=mid+1'b1;
                    else hi<=mid;
                    state<=SEARCH;
                end
                PREV: begin predecessor<=tail_q[IW-1:0]; state<=WRITE; end
                WRITE: begin
                    history[current_index]<={current_value,predecessor};
                    tails[position]<={current_value,current_index};
                    count<=count+1'b1;
                    if (position==length) length<=length+1'b1;
                    if (pending_last) state<=FINISH;
                    else state<=CAPTURE;
                end
                FINISH: begin
                    if (errors!=0 || length==0) begin
                        m_value<=0; m_index<=0; m_rank<=0;
                        m_length<=0; m_count<=0;
                        m_keep<=0; m_first<=1; m_last<=1;
                        m_tag<=tag; m_errors<=errors; state<=HOLD;
                    end else begin
                        tail_q<=tails[length-1'b1]; state<=TRACE_START;
                    end
                end
                TRACE_START: begin
                    trace_index<=tail_q[IW-1:0]; remaining<=length;
                    state<=TRACE_READ;
                end
                TRACE_READ: begin history_q<=history[trace_index]; state<=TRACE_SAVE; end
                TRACE_SAVE: begin
                    witness[remaining-1'b1]<={history_q[MW-1:IW],trace_index};
                    if (remaining==1) begin out_pos<=0; state<=OUT_READ; end
                    else begin
                        trace_index<=history_q[IW-1:0];
                        remaining<=remaining-1'b1; state<=TRACE_READ;
                    end
                end
                OUT_READ: begin witness_q<=witness[out_pos]; state<=OUT_LOAD; end
                OUT_LOAD: begin
                    m_value<=witness_q[MW-1:IW]; m_index<=witness_q[IW-1:0];
                    m_rank<=out_pos; m_length<=length; m_count<=count;
                    m_keep<=1; m_first<=(out_pos==0);
                    m_last<=(out_pos==length-1'b1); m_tag<=tag;
                    m_errors<=0; state<=HOLD;
                end
                HOLD: if (m_ready) begin
                    if (m_last) begin
                        state<=CAPTURE; frame_open<=0; errors<=0;
                        count<=0; length<=0;
                    end else begin out_pos<=out_pos+1'b1; state<=OUT_READ; end
                end
                default: state<=CAPTURE;
            endcase
        end
    end
endmodule
