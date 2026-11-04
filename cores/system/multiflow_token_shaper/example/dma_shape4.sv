// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module dma_shape4(
 input wire clk,rst,c_valid,output wire c_ready,input wire [31:0] c_flow,
 input wire c_enable,input wire [15:0] c_capacity,c_rate,c_initial,input wire [7:0] c_tag,
 output wire r_valid,input wire r_ready,output wire [1:0] r_status,output wire [31:0] r_flow,output wire [7:0] r_tag,
 input wire [3:0] s_valid,output wire [3:0] s_ready,input wire [63:0] s_cost,
 input wire [127:0] s_data,input wire [31:0] s_tag,
 output wire m_valid,input wire m_ready,output wire [31:0] m_flow,output wire m_status,
 output wire [15:0] m_cost,output wire [31:0] m_data,output wire [7:0] m_tag
);
 multiflow_token_shaper shaper(.*);
endmodule
