// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module block_store16(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [1:0] c_op,input wire [31:0] c_handle,input wire [7:0] c_tag,
    input wire d_valid,output wire d_ready,input wire [31:0] d_data,
    output wire r_valid,input wire r_ready,
    output wire [1:0] r_op,output wire [2:0] r_status,
    output wire [31:0] r_handle,output wire [7:0] r_tag,r_refs,
    output wire [4:0] r_count,output wire r_shared,r_keep,r_first,r_last,
    output wire [1:0] r_index,output wire [31:0] r_data
);
    block_intern_store store(.*);
endmodule
