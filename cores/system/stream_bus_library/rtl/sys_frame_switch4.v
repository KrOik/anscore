// Four sources/four destinations; frame-locked round-robin arbitration.
// Sources hold data/keep/last/user/dest whenever valid&&!ready.
module sys_frame_switch4(
 input wire clk,rst_n,
 input wire [127:0] s_data,input wire [15:0] s_keep,
 input wire [3:0] s_last,s_valid,output reg [3:0] s_ready,
 input wire [31:0] s_user,input wire [7:0] s_dest,
 output reg [127:0] m_data,output reg [15:0] m_keep,
 output reg [3:0] m_last,m_valid,input wire [3:0] m_ready,
 output reg [31:0] m_user,output reg [31:0] frames
);
reg [3:0] active;
reg [1:0] owner[0:3],rr[0:3];
reg [3:0] claimed,chosen;
reg [1:0] next_owner[0:3];
integer o,k,idx,n;
always @* begin
 claimed=0; chosen=0; s_ready=0; m_data=0; m_keep=0;
 m_last=0; m_valid=0; m_user=0;
 for(o=0;o<4;o=o+1) if(active[o]) claimed[owner[o]]=1;
 for(o=0;o<4;o=o+1) begin
  next_owner[o]=0;
  if(active[o]) begin
   m_data[o*32+:32]=s_data[owner[o]*32+:32];
   m_keep[o*4+:4]=s_keep[owner[o]*4+:4];
   m_user[o*8+:8]=s_user[owner[o]*8+:8];
   m_last[o]=s_last[owner[o]]; m_valid[o]=s_valid[owner[o]];
   s_ready[owner[o]]=m_ready[o];
  end else begin
   for(k=3;k>=0;k=k-1) begin
    idx=(rr[o]+k)&3;
    if(s_valid[idx]&&!claimed[idx]&&s_dest[idx*2+:2]==o) begin
     chosen[o]=1; next_owner[o]=idx;
    end
   end
  end
 end
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin active<=0; frames<=0; for(n=0;n<4;n=n+1) begin owner[n]<=0; rr[n]<=0; end end
 else begin
  for(n=0;n<4;n=n+1) begin
   if(!active[n]&&chosen[n]) begin active[n]<=1; owner[n]<=next_owner[n]; end
   else if(active[n]&&m_valid[n]&&m_ready[n]&&m_last[n]) begin
    active[n]<=0; rr[n]<=owner[n]+1'b1;
   end
  end
  frames<=frames+{31'd0,(m_valid[0]&&m_ready[0]&&m_last[0])}
                 +{31'd0,(m_valid[1]&&m_ready[1]&&m_last[1])}
                 +{31'd0,(m_valid[2]&&m_ready[2]&&m_last[2])}
                 +{31'd0,(m_valid[3]&&m_ready[3]&&m_last[3])};
 end
end
endmodule
