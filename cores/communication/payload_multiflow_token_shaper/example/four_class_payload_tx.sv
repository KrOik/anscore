// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Four same-clock traffic classes. Payload is not an Ethernet/UDP encoder.
module four_class_payload_tx(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_class,
 input wire c_enable,input wire [15:0] c_capacity,c_rate,c_initial,
 input wire [7:0] c_tag,output wire r_valid,input wire r_ready,
 output wire [1:0] r_status,output wire [31:0] r_flow,output wire [7:0] r_tag,
 input wire s_valid,output wire s_ready,input wire [1:0] s_class,
 input wire [31:0] s_data,input wire [3:0] s_keep,input wire s_last,
 input wire [7:0] s_tag,output wire a_valid,input wire a_ready,
 output wire [2:0] a_status,output wire [31:0] a_flow,a_bytes,a_beats,
 output wire [7:0] a_tag,output wire m_valid,input wire m_ready,
 output wire [31:0] m_flow,m_data,output wire [3:0] m_keep,
 output wire m_sop,m_last,output wire [15:0] m_length,
 output wire [7:0] m_tag,output wire faulted
);
 payload_multiflow_token_shaper u_payload(
  .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_flow({30'd0,c_class}),
  .c_enable(c_enable),.c_capacity(c_capacity),.c_rate(c_rate),.c_initial(c_initial),
  .c_tag(c_tag),.r_valid(r_valid),.r_ready(r_ready),.r_status(r_status),
  .r_flow(r_flow),.r_tag(r_tag),.s_valid(s_valid),.s_ready(s_ready),
  .s_flow({30'd0,s_class}),.s_data(s_data),.s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
  .a_valid(a_valid),.a_ready(a_ready),.a_status(a_status),.a_flow(a_flow),
  .a_bytes(a_bytes),.a_beats(a_beats),.a_tag(a_tag),.m_valid(m_valid),.m_ready(m_ready),
  .m_flow(m_flow),.m_data(m_data),.m_keep(m_keep),.m_sop(m_sop),.m_last(m_last),
  .m_length(m_length),.m_tag(m_tag),.faulted(faulted));
endmodule
`default_nettype wire
