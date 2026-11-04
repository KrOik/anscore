// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module stable_preference_match #(
 parameter integer N=8,TAG_W=8,
 localparam integer IW=(N<=1)?1:$clog2(N),CW=$clog2(N+1),PW=$clog2(N*N+1)
)(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire [31:0] s_partner,input wire s_first,s_last,
 input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output wire m_keep,m_first,m_last,
 output reg [IW-1:0] m_proposer,m_receiver,m_proposer_rank,m_receiver_rank,
 output wire [CW-1:0] m_count,output wire [PW-1:0] m_proposals,
 output wire [TAG_W-1:0] m_tag,output wire [2:0] m_errors
);
 localparam integer AW=(N*N<=1)?1:$clog2(N*N);
 localparam [3:0] COLLECT=0,INIT=1,FIND=2,A_READ=3,A_EVAL=4,
  NEW_READ=5,NEW_EVAL=6,OLD_READ=7,DECIDE=8,REPLAY_READ=9,REPLAY_LOAD=10,OUTPUT=11;
 reg [3:0] state;
 reg [IW-1:0] pref_a[0:N*N-1],rank_b[0:N*N-1];
 reg [IW-1:0] a_q,b_q;
 // Small indexed register tables, initialized serially before computation.
 reg [CW-1:0] next_rank[0:N-1];
 reg [IW-1:0] mate[0:N-1],owner[0:N-1];
 reg side;
 reg [IW-1:0] agent,input_rank,init_index,scan,active,receiver,incumbent,new_rank;
 reg [CW-1:0] active_rank,matched_count;
 reg [AW-1:0] input_address;
 reg [N-1:0] seen,free_a,free_b;
 reg [TAG_W-1:0] tag;
 reg [2:0] errors;
 reg [PW-1:0] proposals;
 wire first_position=!side && agent==0 && input_rank==0;
 wire final_position=side && agent==N-1 && input_rank==N-1;
 wire bad_id=s_partner>=N;
 wire duplicate=!bad_id && seen[s_partner[IW-1:0]];
 wire marker=(s_first!=first_position)||(s_last!=final_position);
 wire [2:0] next_errors=errors|{marker,duplicate,bad_id};
 wire accept=free_b[receiver] || new_rank<b_q;
 assign s_ready=!rst && state==COLLECT;
 assign m_valid=!rst && state==OUTPUT;
 assign m_keep=errors==0;
 assign m_first=errors!=0 || m_proposer==0;
 assign m_last=errors!=0 || m_proposer==N-1;
 assign m_count=errors!=0?{CW{1'b0}}:N;
 assign m_proposals=proposals;
 assign m_tag=tag;assign m_errors=errors;
 always @(posedge clk)if(!rst)begin
  if(state==COLLECT && s_valid && !bad_id)begin
   if(!side)pref_a[input_address]<=s_partner[IW-1:0];
   else rank_b[agent*N+s_partner[IW-1:0]]<=input_rank;
  end
  if(state==A_READ)a_q<=pref_a[active*N+active_rank];
  if(state==NEW_READ)b_q<=rank_b[receiver*N+active];
  if(state==OLD_READ)b_q<=rank_b[receiver*N+incumbent];
  if(state==REPLAY_READ)b_q<=rank_b[mate[m_proposer]*N+m_proposer];
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=COLLECT;side<=0;agent<=0;input_rank<=0;input_address<=0;seen<=0;
   init_index<=0;scan<=0;active<=0;receiver<=0;incumbent<=0;new_rank<=0;
   active_rank<=0;matched_count<=0;free_a<=0;free_b<=0;tag<=0;errors<=0;proposals<=0;
   m_proposer<=0;m_receiver<=0;m_proposer_rank<=0;m_receiver_rank<=0;
  end else case(state)
   COLLECT:if(s_valid)begin
    if(first_position)tag<=s_tag;
    errors<=next_errors;
    if(input_rank==N-1)begin
     input_rank<=0;seen<=0;
     if(agent==N-1)begin agent<=0;side<=1;input_address<=0;end
     else begin agent<=agent+1'b1;input_address<=input_address+1'b1;end
    end else begin
     input_rank<=input_rank+1'b1;input_address<=input_address+1'b1;
     if(!bad_id)seen[s_partner[IW-1:0]]<=1;
    end
    if(final_position)begin
     m_proposer<=0;m_receiver<=0;m_proposer_rank<=0;m_receiver_rank<=0;
     if(next_errors!=0)state<=OUTPUT;
     else begin
      init_index<=0;free_a<={N{1'b1}};free_b<={N{1'b1}};state<=INIT;
     end
    end
   end
   INIT:begin
    next_rank[init_index]<=0;mate[init_index]<=0;owner[init_index]<=0;
    if(init_index==N-1)begin scan<=0;state<=FIND;end
    else init_index<=init_index+1'b1;
   end
   FIND:if(free_a[scan])begin
    active<=scan;active_rank<=next_rank[scan];state<=A_READ;
   end else scan<=scan+1'b1;
   A_READ:state<=A_EVAL;
   A_EVAL:begin receiver<=a_q;state<=NEW_READ;end
   NEW_READ:begin incumbent<=owner[receiver];state<=NEW_EVAL;end
   NEW_EVAL:begin new_rank<=b_q;state<=free_b[receiver]?DECIDE:OLD_READ;end
   OLD_READ:state<=DECIDE;
   DECIDE:begin
    proposals<=proposals+1'b1;next_rank[active]<=active_rank+1'b1;
    if(accept)begin
     mate[active]<=receiver;owner[receiver]<=active;free_a[active]<=0;free_b[receiver]<=0;
     if(free_b[receiver])matched_count<=matched_count+1'b1;
     else free_a[incumbent]<=1;
    end
    if(free_b[receiver] && matched_count==N-1)begin m_proposer<=0;state<=REPLAY_READ;end
    else begin scan<=0;state<=FIND;end
   end
   REPLAY_READ:begin
    m_receiver<=mate[m_proposer];m_proposer_rank<=next_rank[m_proposer]-1'b1;state<=REPLAY_LOAD;
   end
   REPLAY_LOAD:begin m_receiver_rank<=b_q;state<=OUTPUT;end
   OUTPUT:if(m_ready)begin
    if(m_last)begin
     state<=COLLECT;side<=0;agent<=0;input_rank<=0;input_address<=0;seen<=0;
     errors<=0;matched_count<=0;proposals<=0;
    end else begin m_proposer<=m_proposer+1'b1;state<=REPLAY_READ;end
   end
   default:state<=COLLECT;
  endcase
 end
 generate if(N<1 || N>32 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
  stable_preference_match_invalid_parameters__see_README invalid_configuration();
 end endgenerate
endmodule
`default_nettype wire
