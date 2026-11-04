// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module cache_scratchpad #(
    parameter integer RAM_DEPTH=256,
    parameter integer LINES=16,
    parameter integer LINE_WORDS=4
)(
    input wire clk, rst,
    input wire c_valid,
    output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_address, c_data,
    input wire [3:0] c_strobe,
    input wire [7:0] c_tag,
    output wire r_valid,
    input wire r_ready,
    output wire [31:0] r_data,
    output wire [1:0] r_status,
    output wire r_hit,
    output wire [7:0] r_tag,
    output wire [31:0] backend_reads, backend_writes, backend_errors
);
    wire q_valid,q_ready,q_write,p_valid,p_ready,p_error;
    wire [31:0] q_address,q_data,p_data;
    wire [3:0] q_strobe;
    word_writeback_cache #(.LINES(LINES),.LINE_WORDS(LINE_WORDS),.TAG_W(8)) cache(
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
        .c_op(c_op),.c_address(c_address),.c_data(c_data),.c_strobe(c_strobe),.c_tag(c_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_status(r_status),.r_hit(r_hit),.r_tag(r_tag),
        .mem_req_valid(q_valid),.mem_req_ready(q_ready),.mem_req_write(q_write),
        .mem_req_address(q_address),.mem_req_data(q_data),.mem_req_strobe(q_strobe),
        .mem_resp_valid(p_valid),.mem_resp_ready(p_ready),.mem_resp_data(p_data),.mem_resp_error(p_error)
    );
    // Cache reset is synchronous high. This legacy memory uses asynchronous
    // low reset for its control; both are coordinated here, and RAM survives.
    mem_port_bram #(.DEPTH(RAM_DEPTH)) memory(
        .clk(clk),.rst_n(!rst),.req_valid(q_valid),.req_write(q_write),
        .req_addr(q_address),.req_data(q_data),.req_strobe(q_strobe),.req_ready(q_ready),
        .resp_valid(p_valid),.resp_data(p_data),.resp_error(p_error),.resp_ready(p_ready),
        .reads(backend_reads),.writes(backend_writes),.errors(backend_errors)
    );
endmodule
