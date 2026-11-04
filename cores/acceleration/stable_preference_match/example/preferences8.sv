// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module preferences8(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire [31:0] s_partner,input wire s_first,s_last,
 input wire [8-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output wire m_keep,m_first,m_last,
 output wire [3-1:0] m_proposer,m_receiver,m_proposer_rank,m_receiver_rank,
 output wire [4-1:0] m_count,output wire [7-1:0] m_proposals,
 output wire [8-1:0] m_tag,output wire [2:0] m_errors
);
 stable_preference_match core(.*);
endmodule
