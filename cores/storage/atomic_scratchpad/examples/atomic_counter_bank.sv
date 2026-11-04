// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Fetch-and-add counters. The parent arbitrates callers and uses their IDs as
// tags; one accepted operation cannot be interleaved with another caller.
module atomic_counter_bank(
    input wire clk,rst,
    output wire initializing,
    input wire request_valid,
    output wire request_ready,
    input wire [7:0] counter_index,
    input wire [31:0] increment,
    input wire [7:0] caller_id,
    output wire response_valid,
    input wire response_ready,
    output wire [31:0] previous_count,
    output wire [7:0] response_caller,
    output wire [1:0] status
);
    wire unused_wrote;
    atomic_scratchpad #(.DATA_W(32),.DEPTH(256),.TAG_W(8)) counters(
        .clk(clk),.rst(rst),.initializing(initializing),.s_valid(request_valid),.s_ready(request_ready),
        .s_op(4'd2),.s_address(counter_index),.s_operand(increment),.s_compare(32'd0),.s_tag(caller_id),
        .m_valid(response_valid),.m_ready(response_ready),.m_old(previous_count),
        .m_wrote(unused_wrote),.m_status(status),.m_tag(response_caller)
    );
endmodule
