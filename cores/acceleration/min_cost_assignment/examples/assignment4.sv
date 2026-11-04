// Fixed N=4 signed16 assignment example; Apache-2.0.
`timescale 1ns/1ps
module assignment4(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire [31:0] s_row, s_column,
    input wire signed [16-1:0] s_cost,
    input wire s_allowed, s_keep, s_last,
    input wire [8-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire m_keep, m_last,
    output wire [1:0] m_status,
    output wire [8-1:0] m_tag,
    output wire [2-1:0] m_row, m_column,
    output wire signed [16-1:0] m_cost,
    output wire signed [18-1:0] m_total,
    output wire signed [23-1:0] m_row_dual, m_column_dual,
    output wire [3:0] m_hall_rows, m_hall_columns
);
    min_cost_assignment #(.N(4),.COST_W(16),.TAG_W(8)) core(.*);
endmodule
