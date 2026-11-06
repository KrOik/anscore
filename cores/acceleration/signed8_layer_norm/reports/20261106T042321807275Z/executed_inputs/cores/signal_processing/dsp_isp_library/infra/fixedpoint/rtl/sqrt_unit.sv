// Shared unsigned fixed-point square root: r = RNE(sqrt(x) * 2**FB).
// Input x unsigned IN_W; internally computes floor/RNE integer sqrt of
// op = x << (2*FB) over N = ceil((IN_W+2*FB)/2) radix-4 iterations.
// Output unsigned N+1 bits. m_tuser = {exact, zero}: zero flags x==0
// (result 0), exact flags a perfect-square op (post-iteration remainder 0).
// fp_sqrt_iter: one radix-4 digit per clock, latency N+1 cycles from input
//   transfer to earliest output transfer; one operation in flight.
// fp_sqrt_pipe: fully unrolled, II=1, latency N+1 cycles.

module fp_sqrt_iter #(
 parameter integer IN_W=32,parameter integer FB=0
)(
 input wire clk,rst_n,
 input wire [IN_W-1:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [((IN_W+2*FB+1)/2):0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 localparam integer N=(IN_W+2*FB+1)/2; // iterations; output is N+1 bits
 localparam IDLE=0,RUN=1,OUT=2;
 reg [1:0] state;reg [7:0] cnt;
 reg [2*N-1:0] op;reg [N+1:0] rem;reg [N-1:0] root;reg xzero;
 wire m_free=!m_tvalid || m_tready;
 assign s_tready=rst_n && state==IDLE;
 wire [N+1:0] rem_sh={rem[N-1:0],op[2*N-1],op[2*N-2]};
 wire [N+1:0] trial={root,2'b01};
 wire take=rem_sh>=trial;
 wire [N+1:0] rem_n=take ? rem_sh-trial : rem_sh;
 wire [N-1:0] root_n={root[N-2:0],take};
 wire [N:0] root_f={1'b0,root_n}+{{N{1'b0}},(rem_n>{2'b00,root_n})};
 wire exact=(rem_n==0);
 always @(posedge clk) begin
  if(!rst_n)begin state<=IDLE;m_tvalid<=0;cnt<=0;end
  else begin
   if(m_tready)m_tvalid<=1'b0;
   case(state)
    IDLE:if(s_tvalid)begin
     op<={{(2*N-IN_W){1'b0}},s_tdata}<<(2*FB);
     rem<=0;root<=0;xzero<=(s_tdata==0);cnt<=0;state<=RUN;
    end
    RUN:begin
     if(cnt==N-1)begin
      if(m_free)begin
       m_tvalid<=1'b1;m_tdata<=root_f;m_tuser<={exact,xzero};state<=IDLE;
      end else state<=OUT;
     end else begin
      rem<=rem_n;root<=root_n;op<={op[2*N-3:0],2'b00};cnt<=cnt+1'b1;
     end
    end
    OUT:if(m_free)begin
     m_tvalid<=1'b1;m_tdata<=root_f;m_tuser<={exact,xzero};state<=IDLE;
    end
   endcase
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(IN_W<2 || FB<0 || FB>24 || N>127)$fatal(1,"fp_sqrt_iter: unsupported static configuration");
 end
`endif
endmodule

module fp_sqrt_pipe #(
 parameter integer IN_W=32,parameter integer FB=0
)(
 input wire clk,rst_n,
 input wire [IN_W-1:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [((IN_W+2*FB+1)/2):0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 localparam integer N=(IN_W+2*FB+1)/2;
 wire m_free=!m_tvalid || m_tready;
 wire advance=m_free;
 assign s_tready=rst_n && advance;
 wire [2*N-1:0] op_in={{(2*N-IN_W){1'b0}},s_tdata}<<(2*FB);
 // stage s consumes operand pair s from the top of the shifted operand
 reg vld[0:N-1];reg [N+1:0] rem_s[0:N-1];reg [N-1:0] root_s[0:N-1];
 reg [2*N-1:0] op_s[0:N-1];reg xz_s[0:N-1];
 // stage 0 computes from the freshly accepted operand
 wire [N+1:0] rsh0={{N{1'b0}},op_in[2*N-1],op_in[2*N-2]};
 wire take0=rsh0>={{(N+1){1'b0}},1'b1};
 always @(posedge clk) begin
  if(!rst_n)vld[0]<=1'b0;
  else if(advance)begin
   vld[0]<=s_tvalid;
   if(s_tvalid)begin
    rem_s[0]<=take0 ? rsh0-{{(N+1){1'b0}},1'b1} : rsh0;
    root_s[0]<={{(N-1){1'b0}},take0};
    op_s[0]<={op_in[2*N-3:0],2'b00};xz_s[0]<=(s_tdata==0);
   end
  end
 end
 genvar gs;
 generate for(gs=1;gs<N;gs=gs+1) begin:stage
  wire [N+1:0] rsh={rem_s[gs-1][N-1:0],op_s[gs-1][2*N-1],op_s[gs-1][2*N-2]};
  wire [N+1:0] trial={root_s[gs-1],2'b01};
  wire take=rsh>=trial;
  always @(posedge clk) begin
   if(!rst_n)vld[gs]<=1'b0;
   else if(advance)begin
    vld[gs]<=vld[gs-1];
    if(vld[gs-1])begin
     rem_s[gs]<=take ? rsh-trial : rsh;
     root_s[gs]<={root_s[gs-1][N-2:0],take};
     op_s[gs]<={op_s[gs-1][2*N-3:0],2'b00};
     xz_s[gs]<=xz_s[gs-1];
    end
   end
  end
 end endgenerate
 wire [N:0] root_f={1'b0,root_s[N-1]}+{{N{1'b0}},(rem_s[N-1]>{2'b00,root_s[N-1]})};
 always @(posedge clk) begin
  if(!rst_n)m_tvalid<=1'b0;
  else if(advance)begin
   m_tvalid<=vld[N-1];
   if(vld[N-1])begin
    m_tdata<=root_f;m_tuser<={(rem_s[N-1]==0),xz_s[N-1]};
   end
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(IN_W<2 || FB<0 || FB>24 || N>127)$fatal(1,"fp_sqrt_pipe: unsupported static configuration");
 end
`endif
endmodule
