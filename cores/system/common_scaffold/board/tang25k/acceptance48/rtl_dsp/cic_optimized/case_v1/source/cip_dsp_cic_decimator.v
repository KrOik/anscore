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
reg signed [ACC_W-1:0] next_integ[0:STAGES-1];
reg signed [ACC_W-1:0] delay[0:STAGES-1];
reg signed [ACC_W-1:0] data_pipe[0:STAGES-1];
reg [STAGES-1:0] valid_pipe,last_pipe;
localparam COUNT_W=(RATE>1)?$clog2(RATE):1;
reg [COUNT_W-1:0] count;
integer j,k;
wire advance=!m_valid || m_ready;
assign s_ready=advance;
always @* begin
 next_integ[0]=integ[0]+{{(ACC_W-DATA_W){s_data[DATA_W-1]}},s_data};
 for(j=1;j<STAGES;j=j+1)next_integ[j]=integ[j]+next_integ[j-1];
end
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
