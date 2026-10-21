// N-stage CIC, differential delay M=1. All transfers require clk_en.
// Exact signed ACC_W-bit modular arithmetic, no gain normalization.
// Each RATE accepted samples produces one result. A partial packet produces
// one terminal result at last; history clears after that result is computed.
module cip_dsp_cic_decimator #(
    parameter integer DATA_W=16, RATE=8, STAGES=3,
    parameter integer ACC_W=DATA_W+STAGES*$clog2(RATE)
)(
    input wire clk, rst_n, clk_en,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_valid, s_last,
    output wire s_ready,
    output reg signed [ACC_W-1:0] m_data,
    output reg m_valid, m_last,
    input wire m_ready
);
// Candidate: II=1 integrators with globally stalled registered comb stages.
// Output latency increases by STAGES enabled clocks. Every pipeline stage
// clears its own history when the corresponding terminal checkpoint arrives.
reg signed [ACC_W-1:0] integ[0:STAGES-1];
wire signed [ACC_W-1:0] next_integ[0:STAGES-1];
reg signed [ACC_W-1:0] delay[0:STAGES-1];
reg signed [ACC_W-1:0] data_pipe[0:STAGES-1];
reg [STAGES-1:0] valid_pipe,last_pipe;
localparam COUNT_W=(RATE>1)?$clog2(RATE):1;
reg [COUNT_W-1:0] count;
integer j,k;
wire advance=!m_valid || m_ready;
assign s_ready=advance;
// Exact modular prefix sums, balanced rather than a serial carry chain.
// Keep internal pair sums so synthesis preserves the intended carry boundaries.
localparam TREE_LEAVES=1<<$clog2(STAGES+1);
genvar g,n;
generate for(g=0;g<STAGES;g=g+1)begin:prefix
 (* keep=1 *) wire signed [ACC_W-1:0] tree[0:2*TREE_LEAVES-2];
 for(n=0;n<TREE_LEAVES;n=n+1)begin:leaves
  if(n==0)assign tree[TREE_LEAVES-1+n]={{(ACC_W-DATA_W){s_data[DATA_W-1]}},s_data};
  else if(n<=g+1)assign tree[TREE_LEAVES-1+n]=integ[n-1];
  else assign tree[TREE_LEAVES-1+n]=0;
 end
 for(n=0;n<TREE_LEAVES-1;n=n+1)begin:reduce
  assign tree[n]=tree[2*n+1]+tree[2*n+2];
 end
 assign next_integ[g]=tree[0];
end endgenerate
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  count<=0;m_data<=0;m_valid<=0;m_last<=0;valid_pipe<=0;last_pipe<=0;
  for(k=0;k<STAGES;k=k+1)begin integ[k]<=0;delay[k]<=0;data_pipe[k]<=0;end
 end else if(clk_en && advance)begin
  valid_pipe[0]<=s_valid && s_ready && (count==RATE-1 || s_last);
  if(s_valid && s_ready)begin
   for(k=0;k<STAGES;k=k+1)integ[k]<=s_last?{ACC_W{1'b0}}:next_integ[k];
   count<=(count==RATE-1 || s_last)?0:count+1'b1;
   if(count==RATE-1 || s_last)begin data_pipe[0]<=next_integ[STAGES-1];last_pipe[0]<=s_last;end
  end
  for(k=1;k<STAGES;k=k+1)begin
   valid_pipe[k]<=valid_pipe[k-1];
   if(valid_pipe[k-1])begin
    data_pipe[k]<=data_pipe[k-1]-delay[k-1];last_pipe[k]<=last_pipe[k-1];
    delay[k-1]<=last_pipe[k-1]?{ACC_W{1'b0}}:data_pipe[k-1];
   end
  end
  m_valid<=valid_pipe[STAGES-1];
  if(valid_pipe[STAGES-1])begin
   m_data<=data_pipe[STAGES-1]-delay[STAGES-1];m_last<=last_pipe[STAGES-1];
   delay[STAGES-1]<=last_pipe[STAGES-1]?{ACC_W{1'b0}}:data_pipe[STAGES-1];
  end
 end
end
endmodule
