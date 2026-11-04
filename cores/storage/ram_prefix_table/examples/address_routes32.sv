// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module address_routes32(
    input wire clk,rst,c_valid,output wire c_ready,input wire [1:0] c_op,
    input wire [31:0] c_key,c_length,c_value,input wire [7:0] c_tag,
    output wire r_valid,input wire r_ready,output wire [1:0] r_status,
    output wire r_found,r_inserted,output wire [31:0] r_prefix,
    output wire [5:0] r_length,output wire [31:0] r_value,
    output wire [5:0] r_count,output wire [7:0] r_tag
);
    ram_prefix_table #(.SLOTS(32),.KEY_W(32),.VALUE_W(32),.TAG_W(8)) routes(.*);
endmodule
