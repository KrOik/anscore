// SPDX-License-Identifier: Apache-2.0
// Complete ordinary ready/valid instantiation, 16 indexed 32-bit rules.
module ternary_rules16 (
    input wire clk, input wire rst,
    input wire c_valid, output wire c_ready,
    input wire [2:0] c_op, input wire [31:0] c_slot,
    input wire [31:0] c_value, input wire [31:0] c_care,
    input wire [15:0] c_action, input wire [7:0] c_tag,
    output wire m_valid, input wire m_ready,
    output wire [2:0] m_op, output wire [2:0] m_status,
    output wire [7:0] m_tag, output wire [4:0] m_live_count,
    output wire m_found, output wire [15:0] m_match_mask,
    output wire [4:0] m_match_count, output wire [31:0] m_slot,
    output wire [31:0] m_pattern, output wire [31:0] m_care,
    output wire [15:0] m_action
);
    ram_ternary_rule_table #(.SLOTS(16),.KEY_W(32),.ACTION_W(16),.TAG_W(8)) rules(.*);
endmodule
