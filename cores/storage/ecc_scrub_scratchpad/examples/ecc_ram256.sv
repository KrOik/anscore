// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ecc_ram256(
    input wire clk,rst,c_valid,
    output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_address,c_data,
    input wire [3:0] c_strobe,
    input wire [7:0] c_tag,
    output wire r_valid,
    input wire r_ready,
    output wire [31:0] r_data,
    output wire [1:0] r_status,
    output wire [8:0] r_corrected,r_uncorrectable,
    output wire [31:0] r_first_uncorrectable,
    output wire [7:0] r_tag
);
    ecc_scrub_scratchpad #(.DEPTH(256),.TAG_W(8)) ram(.*);
endmodule
