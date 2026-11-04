// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module mass_index64(
    input wire clk,rst,c_valid,output wire c_ready,input wire [1:0] c_op,
    input wire [31:0] c_lo,c_hi,input wire [15:0] c_value,input wire [21:0] c_rank,
    input wire [7:0] c_tag,output wire r_valid,input wire r_ready,
    output wire [1:0] r_op,r_status,output wire [5:0] r_index,
    output wire [21:0] r_sum,r_total,output wire [7:0] r_tag
);
    ram_fenwick_index #(.BUCKETS(64),.COUNT_W(16),.TAG_W(8)) service(.*);
endmodule
