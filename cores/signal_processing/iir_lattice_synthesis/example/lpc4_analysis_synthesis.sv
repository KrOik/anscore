// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Real two-core connection: autocorrelation model analysis and all-pole synthesis.
module lpc4_analysis_synthesis (
    input wire clk,rst,
    input wire correlation_valid,output wire correlation_ready,
    input wire signed [15:0] correlation,
    output wire configuration_done,configuration_error,configured,
    output reg model_rejected,
    output reg [1:0] model_error,
    input wire excitation_valid,output wire excitation_ready,
    input wire signed [15:0] excitation,
    input wire excitation_last,
    input wire [7:0] excitation_tag,
    output wire sample_valid,input wire sample_ready,
    output wire signed [23:0] sample,
    output wire sample_last,sample_clipped,
    output wire [7:0] sample_tag
);
    wire coefficient_valid,coefficient_ready,coefficient_last,configuration_ready;
    wire signed [21:0] coefficient;
    wire signed [16:0] reflection;
    wire [2:0] index;
    wire [32:0] energy;
    wire [1:0] analysis_error;
    wire [7:0] analysis_tag;
    // Error blocks are drained completely; no part of a failed model reaches
    // the filter's configuration bank, preserving its previous model/history.
    assign coefficient_ready=(analysis_error!=0)?1'b1:configuration_ready;
    levinson_durbin analysis (
        .clk(clk),.rst(rst),.s_valid(correlation_valid),.s_ready(correlation_ready),
        .s_r(correlation),.s_tag(8'd0),.m_valid(coefficient_valid),.m_ready(coefficient_ready),
        .m_a(coefficient),.m_reflection(reflection),.m_index(index),.m_last(coefficient_last),
        .m_energy(energy),.m_error(analysis_error),.m_tag(analysis_tag)
    );
    iir_lattice_synthesis synthesis (
        .clk(clk),.rst(rst),.c_valid(coefficient_valid && analysis_error==0),
        .c_ready(configuration_ready),.c_k(reflection),.c_done(configuration_done),
        .c_error(configuration_error),.configured(configured),
        .s_valid(excitation_valid),.s_ready(excitation_ready),.s_data(excitation),
        .s_last(excitation_last),.s_tag(excitation_tag),.m_valid(sample_valid),.m_ready(sample_ready),
        .m_data(sample),.m_last(sample_last),.m_clipped(sample_clipped),.m_tag(sample_tag)
    );
    always @(posedge clk) begin
        if(rst) begin model_rejected<=0;model_error<=0;end
        else begin
            model_rejected<=0;
            if(coefficient_valid && coefficient_ready && coefficient_last && analysis_error!=0) begin
                model_rejected<=1;model_error<=analysis_error;
            end
        end
    end
endmodule
