// Balanced unsigned extrema tree and one elastic output beat.
module morph_reduce #(parameter BITS=8,K=3)(
 input wire clk,rst_n,
 input wire [K*K*BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 input wire [K*K-1:0] mask,input wire dilate,
 output reg [BITS-1:0] m_tdata,
 output reg m_tvalid,m_tuser,m_tlast,input wire m_tready
);
 localparam N=1<<$clog2(K*K);
 wire [BITS-1:0] node[1:2*N-1];
 genvar i;
 generate for(i=0;i<N;i=i+1)begin: leaves
   if(i<K*K)assign node[N+i]=mask[i]?s_tdata[i*BITS+:BITS]:(dilate?{BITS{1'b0}}:{BITS{1'b1}});
   else assign node[N+i]=dilate?{BITS{1'b0}}:{BITS{1'b1}};
 end
 for(i=1;i<N;i=i+1)begin: tree
   assign node[i]=dilate ? ((node[2*i]>node[2*i+1])?node[2*i]:node[2*i+1]) :
                          ((node[2*i]<node[2*i+1])?node[2*i]:node[2*i+1]);
 end endgenerate
 assign s_tready=!m_tvalid || m_tready;
 always @(posedge clk)begin
   if(!rst_n)begin m_tvalid<=0;m_tuser<=0;m_tlast<=0;end
   else if(s_tready)begin
     m_tvalid<=s_tvalid;
     if(s_tvalid)begin m_tdata<=node[1];m_tuser<=s_tuser;m_tlast<=s_tlast;end
   end
 end
endmodule
