// SPDX-License-Identifier: Apache-2.0
// Complete default interface; the wrapper establishes instantiation only.
module cnf8 (
    input wire clk,rst,
    input wire c_valid, output wire c_ready,
    input wire [31:0] c_num_vars,c_num_clauses,
    input wire c_error, input wire [7:0] c_tag,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_positive,s_negative,
    input wire s_last,s_error,
    output wire m_valid, input wire m_ready,
    output wire m_sat, output wire [7:0] m_assignment,
    output wire [5:0] m_error, output wire [7:0] m_tag
);
    cnf_sat_solver #(.MAX_VARS(8),.MAX_CLAUSES(16),.TAG_W(8)) service(.*);
endmodule
