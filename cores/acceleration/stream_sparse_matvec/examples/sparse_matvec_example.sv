// SPDX-License-Identifier: Apache-2.0
// 64-column sparse rows, signed16 coefficients/vector, exact signed38 result.
module sparse_matvec_example(
    input wire clk,rst,
    input wire vector_valid,
    output wire vector_ready,
    input wire signed [15:0] vector_data,
    input wire reload_valid,
    output wire reload_ready,
    input wire row_valid,
    output wire row_ready,
    input wire [5:0] column,
    input wire signed [15:0] coefficient,
    input wire keep,row_last,
    input wire [7:0] row_tag,
    output wire result_valid,
    input wire result_ready,
    output wire signed [37:0] result,
    output wire [6:0] selected_terms,
    output wire index_error,overflow,
    output wire [7:0] result_tag
);
    stream_sparse_matvec compute(
        .clk(clk),.rst(rst),.v_valid(vector_valid),.v_ready(vector_ready),.v_data(vector_data),
        .reload_valid(reload_valid),.reload_ready(reload_ready),
        .s_valid(row_valid),.s_ready(row_ready),.s_index(column),.s_value(coefficient),
        .s_keep(keep),.s_last(row_last),.s_tag(row_tag),
        .m_valid(result_valid),.m_ready(result_ready),.m_sum(result),.m_terms(selected_terms),
        .m_index_error(index_error),.m_overflow(overflow),.m_tag(result_tag)
    );
endmodule
