// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module transaction_bank4(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [2:0] c_op,input wire [7:0] c_context,input wire [31:0] c_address,
    input wire [31:0] c_data,input wire [7:0] c_tag,
    output wire r_valid,input wire r_ready,
    output wire [2:0] r_op,r_status,output wire [7:0] r_context,
    output wire [31:0] r_address,output wire [7:0] r_tag,
    output wire [31:0] r_data,output wire [4:0] r_written,
    output wire r_active,r_conflict
);
    transactional_scratchpad bank(.*);
endmodule
