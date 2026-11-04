// SPDX-License-Identifier: Apache-2.0
// Exposes the full command/response boundary for a single-clock scheduler.
module binary_heap_queue_example (
    input wire clk, rst,
    input wire command_valid,
    output wire command_ready,
    input wire [1:0] command_op,
    input wire [15:0] priority_key,
    input wire [31:0] work_id,
    output wire response_valid,
    input wire response_ready,
    output wire [1:0] response_op, response_status,
    output wire [15:0] response_key,
    output wire [31:0] response_work_id,
    output wire [5:0] response_count
);
    binary_heap_queue #(.CAPACITY(32), .SIGNED_KEY(1)) queue (
        .clk(clk), .rst(rst), .s_valid(command_valid), .s_ready(command_ready),
        .s_op(command_op), .s_key(priority_key), .s_data(work_id),
        .m_valid(response_valid), .m_ready(response_ready),
        .m_op(response_op), .m_status(response_status),
        .m_key(response_key), .m_data(response_work_id), .m_count(response_count)
    );
endmodule
