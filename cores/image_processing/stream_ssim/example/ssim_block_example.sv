`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// A caller sends one pair per accepted beat and marks the final pair in a block.
module ssim_block_example(
    input wire clk,rst,
    input wire pair_valid,output wire pair_ready,
    input wire [7:0] reference_pixel,processed_pixel,
    input wire pair_last,
    output wire score_valid,input wire score_ready,
    output wire signed [16:0] score_q15,
    output wire overflow
);
    wire [6:0] selected_count;
    wire empty; wire [7:0] tag;
    stream_ssim #(.BITS(8),.MAX_SAMPLES(64),.Q_BITS(15)) metric(
        .clk(clk),.rst(rst),.s_valid(pair_valid),.s_ready(pair_ready),
        .s_x(reference_pixel),.s_y(processed_pixel),.s_mask(1'b1),
        .s_last(pair_last),.s_tag(8'd0),.m_valid(score_valid),
        .m_ready(score_ready),.m_score(score_q15),.m_count(selected_count),
        .m_empty(empty),.m_overflow(overflow),.m_tag(tag)
    );
endmodule
