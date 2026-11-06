// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Original clock-quantized descriptor shaper. Per-flow queues hold one item.
module multiflow_token_shaper #(
 parameter integer FLOWS=4,TOKEN_W=16,DATA_W=32,TAG_W=8,QUANTUM=16
)(
 input wire clk,rst,
 input wire c_valid,output reg c_ready,
 input wire [31:0] c_flow,input wire c_enable,
 input wire [TOKEN_W-1:0] c_capacity,c_rate,c_initial,
 input wire [TAG_W-1:0] c_tag,
 output wire r_valid,input wire r_ready,
 output reg [1:0] r_status,output reg [31:0] r_flow,output reg [TAG_W-1:0] r_tag,
 input wire [FLOWS-1:0] s_valid,output wire [FLOWS-1:0] s_ready,
 input wire [FLOWS*TOKEN_W-1:0] s_cost,
 input wire [FLOWS*DATA_W-1:0] s_data,
 input wire [FLOWS*TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output wire [31:0] m_flow,output reg m_status,
 output reg [TOKEN_W-1:0] m_cost,output reg [DATA_W-1:0] m_data,
 output reg [TAG_W-1:0] m_tag
);
 localparam integer IW=(FLOWS>1)?$clog2(FLOWS):1;
 localparam integer QW=(QUANTUM>1)?$clog2(QUANTUM):1;
 generate if(FLOWS<1 || FLOWS>16 || TOKEN_W<1 || TOKEN_W>32 ||
  DATA_W<1 || DATA_W>64 || TAG_W<1 || TAG_W>32 || QUANTUM<1 || QUANTUM>1024)
  begin: invalid_parameter
   multiflow_token_shaper_invalid_parameter__see_README rejected();
  end
 endgenerate
 reg [FLOWS-1:0] enabled,pending,queued_bad;
 reg [TOKEN_W-1:0] capacity[0:FLOWS-1],rate[0:FLOWS-1],tokens[0:FLOWS-1];
 reg [TOKEN_W-1:0] queued_cost[0:FLOWS-1];
 wire [TOKEN_W-1:0] next_tokens[0:FLOWS-1];
 wire [FLOWS-1:0] eligible;
 reg [DATA_W-1:0] queued_data[0:FLOWS-1];
 reg [TAG_W-1:0] queued_tag[0:FLOWS-1];
 reg [IW-1:0] rr,held_flow;
 reg [QW-1:0] phase;
 reg response_valid,output_valid;
 reg saved_enable;
 reg [TOKEN_W-1:0] saved_capacity,saved_rate,saved_initial;
 wire tick=phase==QUANTUM-1;
 wire config_accept=c_valid && c_ready;
 wire config_commit=!rst && response_valid && r_ready && r_status==0;
 wire retire=!rst && output_valid && m_ready;
 assign r_valid=!rst && response_valid;
 assign m_valid=!rst && output_valid;
 assign m_flow={{(32-IW){1'b0}},held_flow};
 always @* begin
  c_ready=0;
  if(!rst && !response_valid)begin
   if(c_flow>=FLOWS)c_ready=1;
   else c_ready=!pending[c_flow];
  end
 end
 genvar k;
 generate for(k=0;k<FLOWS;k=k+1)begin: ingress
  assign s_ready[k]=!rst && enabled[k] && !pending[k] &&
   !(response_valid && r_flow==k) && !(config_accept && c_flow==k);
  wire [TOKEN_W:0] credit={1'b0,tokens[k]}+
   ((tick && enabled[k])?{1'b0,rate[k]}:{(TOKEN_W+1){1'b0}});
  wire [TOKEN_W-1:0] clamped=(credit>{1'b0,capacity[k]})?capacity[k]:credit[TOKEN_W-1:0];
  // Selection reserved this owner's unspent credit; while held no config or
  // second descriptor of this flow can consume it. Refills can only help.
  assign next_tokens[k]=(retire && held_flow==k && !m_status)?clamped-m_cost:clamped;
  assign eligible[k]=pending[k] && (queued_bad[k] || tokens[k]>=queued_cost[k]);
 end endgenerate

 integer i,step,index;
 reg found;
 reg [IW-1:0] selected;
 always @* begin
  found=0;selected=0;index=0;
  for(step=0;step<FLOWS;step=step+1)begin
   index=rr+step;
   if(index>=FLOWS)index=index-FLOWS;
   if(!found && eligible[index])begin
    found=1;selected=index;
   end
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   enabled<=0;pending<=0;queued_bad<=0;rr<=0;held_flow<=0;phase<=0;
   response_valid<=0;output_valid<=0;saved_enable<=0;saved_capacity<=0;saved_rate<=0;saved_initial<=0;
   r_status<=0;r_flow<=0;r_tag<=0;m_status<=0;m_cost<=0;m_data<=0;m_tag<=0;
   for(i=0;i<FLOWS;i=i+1)begin capacity[i]<=0;rate[i]<=0;tokens[i]<=0;end
  end else begin
   if(tick)phase<=0;else phase<=phase+1'b1;
   for(i=0;i<FLOWS;i=i+1)begin
    if(config_commit && r_flow==i)begin
     enabled[i]<=saved_enable;capacity[i]<=saved_capacity;rate[i]<=saved_rate;tokens[i]<=saved_initial;
    end else tokens[i]<=next_tokens[i];
    if(s_valid[i] && s_ready[i])begin
     pending[i]<=1;queued_cost[i]<=s_cost[i*TOKEN_W+:TOKEN_W];
     queued_data[i]<=s_data[i*DATA_W+:DATA_W];queued_tag[i]<=s_tag[i*TAG_W+:TAG_W];
     queued_bad[i]<=(s_cost[i*TOKEN_W+:TOKEN_W]==0 || s_cost[i*TOKEN_W+:TOKEN_W]>capacity[i]);
    end
   end
   if(config_accept)begin
    response_valid<=1;r_flow<=c_flow;r_tag<=c_tag;
    saved_enable<=c_enable;saved_capacity<=c_capacity;saved_rate<=c_rate;saved_initial<=c_initial;
    if(c_flow>=FLOWS)r_status<=1;
    else if(c_initial>c_capacity || c_rate>c_capacity || (c_enable && c_capacity==0))r_status<=2;
    else r_status<=0;
   end else if(response_valid && r_ready)response_valid<=0;
   if(!output_valid && found)begin
    output_valid<=1;held_flow<=selected;m_status<=queued_bad[selected];
    m_cost<=queued_cost[selected];m_data<=queued_data[selected];m_tag<=queued_tag[selected];
   end else if(retire)begin
    output_valid<=0;pending[held_flow]<=0;
    rr<=(held_flow==FLOWS-1)?0:held_flow+1'b1;
   end
  end
 end
endmodule
`default_nettype wire
