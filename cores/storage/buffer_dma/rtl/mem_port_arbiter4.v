// Four independent masters, one reserved response slot per master, round robin.
// One backend request in flight; completion and next issue may share an edge.
module mem_port_arbiter4(
 input wire clk,rst_n,input wire [3:0] s_valid,s_write,
 input wire [127:0] s_addr,s_data,input wire [15:0] s_strobe,output reg [3:0] s_ready,
 output reg [3:0] r_valid,output reg [127:0] r_data,output reg [3:0] r_error,
 input wire [3:0] r_ready,
 output wire m_valid,m_write,output wire [31:0] m_addr,m_data,
 output wire [3:0] m_strobe,input wire m_ready,
 input wire p_valid,input wire [31:0] p_data,input wire p_error,output wire p_ready,
 output reg [127:0] requests,completions,stalls
);
 reg [3:0] reserved;
 reg [1:0] next_master,owner,locked_master;
 reg inflight,locked;
 reg [1:0] chosen;
 reg found;
 integer n,index;
 wire can_issue=!inflight||(p_valid&&p_ready);
 always @*begin
  chosen=locked_master;found=locked;index=0;
  if(!locked)for(n=0;n<4;n=n+1)begin
   index=(next_master+n)&3;
   if(!found&&s_valid[index]&&!reserved[index])begin chosen=index;found=1;end
  end
  s_ready=0;
  if(rst_n&&can_issue&&found)s_ready[chosen]=m_ready;
 end
 assign m_valid=rst_n&&can_issue&&found;
 assign m_write=s_write[chosen];
 assign m_addr=s_addr[chosen*32+:32];assign m_data=s_data[chosen*32+:32];
 assign m_strobe=s_strobe[chosen*4+:4];
 // A slot is reserved before issuing, so a backend response always has space.
 assign p_ready=rst_n&&inflight;
 integer k;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   reserved<=0;next_master<=0;owner<=0;inflight<=0;locked<=0;locked_master<=0;
   r_valid<=0;r_data<=0;r_error<=0;requests<=0;completions<=0;stalls<=0;
  end else begin
   for(k=0;k<4;k=k+1)begin
    if(r_valid[k]&&r_ready[k])begin r_valid[k]<=0;reserved[k]<=0;end
    if(s_valid[k]&&!s_ready[k])stalls[k*32+:32]<=stalls[k*32+:32]+1'b1;
   end
   if(p_valid&&p_ready)begin
    r_valid[owner]<=1;r_data[owner*32+:32]<=p_data;r_error[owner]<=p_error;
    completions[owner*32+:32]<=completions[owner*32+:32]+1'b1;inflight<=0;
   end
   if(m_valid&&!m_ready)begin locked<=1;locked_master<=chosen;end
   if(m_valid&&m_ready)begin
    locked<=0;owner<=chosen;inflight<=1;reserved[chosen]<=1;
    next_master<=chosen+1'b1;requests[chosen*32+:32]<=requests[chosen*32+:32]+1'b1;
   end
  end
 end
endmodule
