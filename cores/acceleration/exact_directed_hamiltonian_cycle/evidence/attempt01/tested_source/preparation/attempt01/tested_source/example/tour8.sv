// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tour8(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,
    input wire signed [15:0] s_weight,
    input wire s_present,s_keep,s_last,
    input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire m_keep,m_last,m_feasible,
    output wire [1:0] m_error,
    output wire [7:0] m_tag,
    output wire [3:0] m_position,
    output wire [2:0] m_vertex,
    output wire signed [18:0] m_cost
);
    exact_directed_hamiltonian_cycle #(.NUM_NODES(8),.WEIGHT_W(16),.TAG_W(8)) dut(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_from(s_from),.s_to(s_to),.s_weight(s_weight),
        .s_present(s_present),.s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_keep(m_keep),.m_last(m_last),
        .m_feasible(m_feasible),.m_error(m_error),.m_tag(m_tag),
        .m_position(m_position),.m_vertex(m_vertex),.m_cost(m_cost)
    );
endmodule
