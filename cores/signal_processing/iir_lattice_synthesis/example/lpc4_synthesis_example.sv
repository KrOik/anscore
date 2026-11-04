// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Feed four FRAC16 reflection codes in k1..k4 order, then excitation samples.
module lpc4_synthesis_example (
    input wire clk,rst,
    input wire reflection_valid,output wire reflection_ready,
    input wire signed [16:0] reflection_q16,
    output wire configuration_done,configuration_error,configured,
    input wire excitation_valid,output wire excitation_ready,
    input wire signed [15:0] excitation,
    input wire excitation_last,
    output wire sample_valid,input wire sample_ready,
    output wire signed [23:0] sample,
    output wire sample_last,sample_clipped
);
    wire [7:0] tag;
    iir_lattice_synthesis #(.DATA_W(16),.STATE_W(24),.FRAC(16),.ORDER(4)) synth (
        .clk(clk),.rst(rst),.c_valid(reflection_valid),.c_ready(reflection_ready),.c_k(reflection_q16),
        .c_done(configuration_done),.c_error(configuration_error),.configured(configured),
        .s_valid(excitation_valid),.s_ready(excitation_ready),.s_data(excitation),.s_last(excitation_last),.s_tag(8'd0),
        .m_valid(sample_valid),.m_ready(sample_ready),.m_data(sample),.m_last(sample_last),.m_clipped(sample_clipped),.m_tag(tag)
    );
endmodule
