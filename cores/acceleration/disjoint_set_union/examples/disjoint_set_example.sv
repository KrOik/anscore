// SPDX-License-Identifier: Apache-2.0
module disjoint_set_example(
    input wire clk,rst,
    input wire command_valid,
    output wire command_ready,
    input wire [1:0] operation,
    input wire [5:0] node_a,node_b,
    input wire [7:0] command_tag,
    output wire result_valid,
    input wire result_ready,
    output wire [1:0] result_operation,
    output wire [5:0] representative,
    output wire same_component,merged,error,
    output wire [6:0] component_count,
    output wire [7:0] result_tag
);
    disjoint_set_union sets(
        .clk(clk),.rst(rst),.s_valid(command_valid),.s_ready(command_ready),
        .s_op(operation),.s_a(node_a),.s_b(node_b),.s_tag(command_tag),
        .m_valid(result_valid),.m_ready(result_ready),.m_op(result_operation),
        .m_root(representative),.m_same(same_component),.m_merged(merged),
        .m_error(error),.m_groups(component_count),.m_tag(result_tag)
    );
endmodule
