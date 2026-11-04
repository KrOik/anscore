// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// A scheduler samples worker_tag on submit_valid && submit_ready, passes it
// to its worker, then returns it unchanged with that worker's result.
module ordered_worker_results(
    input wire clk, rst,
    input wire submit_valid,
    output wire submit_ready,
    input wire [15:0] request_id,
    output wire [2:0] worker_tag,
    input wire worker_valid,
    output wire worker_ready,
    input wire [2:0] result_tag,
    input wire [31:0] worker_data,
    input wire worker_error,
    output wire rejected_result,
    output wire result_valid,
    input wire result_ready,
    output wire [15:0] result_request_id,
    output wire [31:0] result_data,
    output wire result_error,
    output wire [3:0] outstanding
);
    ordered_completion_buffer #(.DEPTH(8),.DATA_W(32),.META_W(16)) buffer (
        .clk(clk),.rst(rst),.a_valid(submit_valid),.a_ready(submit_ready),
        .a_meta(request_id),.a_tag(worker_tag),.c_valid(worker_valid),.c_ready(worker_ready),
        .c_tag(result_tag),.c_data(worker_data),.c_error(worker_error),.c_rejected(rejected_result),
        .m_valid(result_valid),.m_ready(result_ready),.m_meta(result_request_id),
        .m_data(result_data),.m_error(result_error),.occupancy(outstanding)
    );
endmodule
