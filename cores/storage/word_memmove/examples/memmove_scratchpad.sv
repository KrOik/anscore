// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Existing native arbiter + BRAM provide a host load/readback port alongside
// the memmove engine. Callers own copied ranges while a move is active.
module memmove_scratchpad #(
    parameter integer RAM_DEPTH=256
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire [31:0] s_source,s_destination,
    input wire [15:0] s_words,
    input wire [7:0] s_tag,
    output wire done_valid,
    input wire done_ready,
    output wire [1:0] done_status,
    output wire [15:0] done_words,
    output wire done_backward,
    output wire [7:0] done_tag,
    input wire host_valid,host_write,
    output wire host_ready,
    input wire [31:0] host_address,host_data,
    input wire [3:0] host_strobe,
    output wire host_resp_valid,host_resp_error,
    input wire host_resp_ready,
    output wire [31:0] host_resp_data
);
    wire q_valid,q_ready,q_write,r_valid,r_ready,r_error;
    wire [31:0] q_address,q_data,r_data;
    wire [3:0] q_strobe;
    word_memmove mover(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_source(s_source),.s_destination(s_destination),.s_words(s_words),.s_tag(s_tag),
        .done_valid(done_valid),.done_ready(done_ready),.done_status(done_status),
        .done_words(done_words),.done_backward(done_backward),.done_tag(done_tag),
        .mem_req_valid(q_valid),.mem_req_ready(q_ready),.mem_req_write(q_write),
        .mem_req_address(q_address),.mem_req_data(q_data),.mem_req_strobe(q_strobe),
        .mem_resp_valid(r_valid),.mem_resp_ready(r_ready),.mem_resp_data(r_data),.mem_resp_error(r_error)
    );
    wire [3:0] request_ready,response_valid,response_error;
    wire [127:0] response_data;
    wire backend_valid,backend_write,backend_ready,backend_resp_valid,backend_resp_ready,backend_error;
    wire [31:0] backend_address,backend_data,backend_resp_data;
    wire [3:0] backend_strobe;
    wire [127:0] unused_requests,unused_completions,unused_stalls;
    assign q_ready=request_ready[0];
    assign host_ready=request_ready[1];
    assign r_valid=response_valid[0];
    assign r_data=response_data[31:0];
    assign r_error=response_error[0];
    assign host_resp_valid=response_valid[1];
    assign host_resp_data=response_data[63:32];
    assign host_resp_error=response_error[1];
    mem_port_arbiter4 arbiter(
        .clk(clk),.rst_n(!rst),.s_valid({2'b00,host_valid,q_valid}),
        .s_write({2'b00,host_write,q_write}),.s_addr({64'd0,host_address,q_address}),
        .s_data({64'd0,host_data,q_data}),.s_strobe({8'd0,host_strobe,q_strobe}),.s_ready(request_ready),
        .r_valid(response_valid),.r_data(response_data),.r_error(response_error),
        .r_ready({2'b11,host_resp_ready,r_ready}),.m_valid(backend_valid),.m_write(backend_write),
        .m_addr(backend_address),.m_data(backend_data),.m_strobe(backend_strobe),.m_ready(backend_ready),
        .p_valid(backend_resp_valid),.p_data(backend_resp_data),.p_error(backend_error),.p_ready(backend_resp_ready),
        .requests(unused_requests),.completions(unused_completions),.stalls(unused_stalls)
    );
    wire [31:0] unused_reads,unused_writes,unused_errors;
    mem_port_bram #(.DEPTH(RAM_DEPTH)) memory(
        .clk(clk),.rst_n(!rst),.req_valid(backend_valid),.req_write(backend_write),
        .req_addr(backend_address),.req_data(backend_data),.req_strobe(backend_strobe),.req_ready(backend_ready),
        .resp_valid(backend_resp_valid),.resp_data(backend_resp_data),.resp_error(backend_error),
        .resp_ready(backend_resp_ready),.reads(unused_reads),.writes(unused_writes),.errors(unused_errors)
    );
endmodule
