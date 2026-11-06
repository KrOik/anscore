// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Bootstrap two real routes after each reset, then expose the header service.
module ipv4_two_route_forwarder #(parameter integer TAG_W=8)(
 input wire clk,rst,
 input wire p_valid,output wire p_ready,input wire [159:0] p_header,
 input wire [15:0] p_bytes,input wire [TAG_W-1:0] p_tag,
 output wire m_valid,input wire m_ready,output wire [2:0] m_error,
 output wire [159:0] m_header,output wire [31:0] m_next_hop,m_prefix,
 output wire [7:0] m_port,output wire [5:0] m_prefix_length,
 output wire [2:0] m_count,output wire [TAG_W-1:0] m_tag,
 output wire initialized,output reg boot_error
);
 localparam [2:0] SEND_DEFAULT=0,WAIT_DEFAULT=1,SEND_LAN=2,WAIT_LAN=3,RUN=4,BROKEN=5;
 reg [2:0] state;
 wire cfg_ready,cfg_valid,cfg_response,packet_ready;
 wire [1:0] cfg_status;
 assign cfg_valid=state==SEND_DEFAULT||state==SEND_LAN;
 assign initialized=!rst&&state==RUN;
 assign p_ready=initialized&&packet_ready;
 ipv4_lpm_forward #(.ROUTES(4),.TAG_W(TAG_W)) core(
  .clk(clk),.rst(rst),.c_valid(cfg_valid),.c_ready(cfg_ready),.c_op(2'd1),
  .c_prefix(state==SEND_LAN?32'hc0a80000:32'd0),.c_length(state==SEND_LAN?32'd16:32'd0),
  .c_next_hop(state==SEND_LAN?32'hc0a80001:32'd0),.c_port(state==SEND_LAN?8'd2:8'd1),
  .c_tag({TAG_W{1'b0}}),.c_rsp_valid(cfg_response),.c_rsp_ready(state==WAIT_DEFAULT||state==WAIT_LAN),
  .c_status(cfg_status),.c_found(),.c_inserted(),.c_old_prefix(),.c_old_length(),
  .c_old_next_hop(),.c_old_port(),.c_count(),.c_rsp_tag(),
  .p_valid(p_valid&&initialized),.p_ready(packet_ready),.p_header(p_header),.p_bytes(p_bytes),.p_tag(p_tag),
  .m_valid(m_valid),.m_ready(m_ready),.m_error(m_error),.m_header(m_header),
  .m_next_hop(m_next_hop),.m_prefix(m_prefix),.m_port(m_port),.m_prefix_length(m_prefix_length),
  .m_count(m_count),.m_tag(m_tag));
 always @(posedge clk)begin
  if(rst)begin state<=SEND_DEFAULT;boot_error<=0;end
  else case(state)
   SEND_DEFAULT:if(cfg_ready)state<=WAIT_DEFAULT;
   WAIT_DEFAULT:if(cfg_response)begin
    if(cfg_status!=0)begin boot_error<=1;state<=BROKEN;end
    else state<=SEND_LAN;
   end
   SEND_LAN:if(cfg_ready)state<=WAIT_LAN;
   WAIT_LAN:if(cfg_response)begin
    if(cfg_status!=0)begin boot_error<=1;state<=BROKEN;end
    else state<=RUN;
   end
   default:state<=state;
  endcase
 end
endmodule
