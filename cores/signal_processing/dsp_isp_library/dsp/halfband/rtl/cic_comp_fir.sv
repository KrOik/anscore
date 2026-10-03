// CIC-compensation symmetric FIR: y[n] = sum_k g[k] x[n-k], signed16 Q1.15.
//
// Odd symmetric taps S, center c=(S-1)/2. Only U=(S+1)/2 unique
// coefficients are configured (g[k]=g[S-1-k] is structural); the MAC folds
// U-1 symmetric pairs plus the center product = U shared-MAC terms. The
// generator (models/gen_coeffs.py --kind ciccomp) produces inverse-droop
// tables for a chosen CIC order/rate, e.g. the reference N=4 R=8 or the
// existing sigproc_20k cic_dec8 (N=3 R=8 M=1). Arbitrary user tables are
// accepted but carry no spectral guarantee.
//
// Rate contract (honest): 1:1 samples in:out, no rate change. One input is
// accepted only while the shared MAC is idle; per input the MAC spends
// ROUNDS=ceil(U/LANES) clocks plus ~2 overhead, so sustained throughput is
// below one sample/clock — document as serialized-MAC, not II1. Outputs
// are held stable under backpressure.
//
// Atomic config identical to the halfband cores: legal odd taps + packed
// unique coefficients apply in one edge and clear state; illegal taps
// pulse cfg_error. Flush feeds virtual zeros until N+S-1 outputs are
// emitted (none for an empty block), then DONE waits for config/reset.
// Single clk, synchronous active-low rst_n.
module cic_comp_fir #(
 parameter integer MAX_TAPS=31,
 parameter integer LANES=4,
 parameter integer MAX_INPUTS=65535,
 parameter [5:0] DEFAULT_TAPS=15,
 parameter [((MAX_TAPS+1)/2)*18-1:0] DEFAULT_COEFFS=288'h131e0298cfdf8ff382009ec0390ffdbbff5a
)(
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg signed [15:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [5:0] cfg_taps,
 input wire [((MAX_TAPS+1)/2)*18-1:0] cfg_coeffs,
 output reg cfg_done,cfg_error,
 input wire flush_valid,output wire flush_ready,output reg flush_done,
 output reg [15:0] input_count,output reg [20:0] output_count,
 output reg capacity_error
);
localparam integer U_MAX=(MAX_TAPS+1)/2;
localparam RUN=0,DONE=1;
reg state,draining;
reg [5:0] round,tbase;
reg [5:0] taps;
reg [5:0] uniq;
reg [5:0] used;
reg [20:0] started,end_total;
reg signed [15:0] history[0:MAX_TAPS-1];
reg signed [16:0] dreg[0:U_MAX-1];
reg signed [40:0] acc;
reg [U_MAX*18-1:0] coeffs;

wire advance=!m_tvalid || m_tready;
wire signed [15:0] feedv=draining ? 16'sd0 : s_tdata;
assign s_tready=rst_n && state==RUN && !draining && !cfg_valid &&
                !flush_valid && input_count<MAX_INPUTS && round==0;
wire real_take=s_tvalid && s_tready;
wire vfeed=draining && state==RUN && started<end_total && round==0;
wire feed=real_take || vfeed;
assign flush_ready=rst_n && state==RUN && !draining && round==0 &&
                    !m_tvalid && !cfg_valid;
assign cfg_ready=rst_n && (state==DONE ||
                  (state==RUN && !draining && round==0 && !m_tvalid));
wire cfg_legal=cfg_taps[0] && cfg_taps>=6'd3 && cfg_taps<=MAX_TAPS;
wire [5:0] rounds_need=(uniq+LANES-1)/LANES;
wire [5:0] center=taps>>1;
// tap k relative to the just-fed sample; zero beyond filled history
function signed [15:0] tq;input [5:0] k;
 begin
  if(k==0)tq=feedv;
  else if(k-1<used)tq=history[k-1];
  else tq=16'sd0;
 end
endfunction
// U shared-MAC terms: folded pairs 0..U-2 and the center sample U-1
wire signed [34:0] lane_p[0:3];
genvar gl;
generate for(gl=0;gl<4;gl=gl+1)begin:LANE
 assign lane_p[gl]=(gl<LANES && tbase+gl<uniq) ?
        dreg[tbase+gl]*$signed(coeffs[18*(tbase+gl) +: 18]) : 35'sd0;
end endgenerate
wire signed [40:0] lanesum=acc+{{6{lane_p[0][34]}},lane_p[0]}
                            +{{6{lane_p[1][34]}},lane_p[1]}
                            +{{6{lane_p[2][34]}},lane_p[2]}
                            +{{6{lane_p[3][34]}},lane_p[3]};
wire signed [40:0] q15=lanesum>>>15;
wire signed [40:0] rnd=q15+((lanesum[14:0]>15'd16384 ||
   (lanesum[14:0]==15'd16384 && q15[0])) ? 41'sd1 : 41'sd0);
wire clipped=rnd>32767 || rnd < -32768;
integer i;
always @(posedge clk)begin
 if(!rst_n)begin
  state<=RUN;draining<=0;round<=0;tbase<=0;taps<=DEFAULT_TAPS;
  uniq<=(DEFAULT_TAPS+1)>>1;used<=0;started<=0;end_total<=0;acc<=0;
  coeffs<=DEFAULT_COEFFS;input_count<=0;output_count<=0;capacity_error<=0;
  m_tvalid<=0;m_tdata<=0;m_tuser<=0;cfg_done<=0;cfg_error<=0;flush_done<=0;
  for(i=0;i<U_MAX;i=i+1)dreg[i]<=0;
 end else begin
  cfg_done<=0;cfg_error<=0;flush_done<=0;
  if(m_tvalid && m_tready)output_count<=output_count+1'b1;
  if(m_tready)m_tvalid<=0;
  if(state==RUN && !draining && !cfg_valid && !flush_valid &&
     s_tvalid && input_count==MAX_INPUTS)capacity_error<=1;
  if(cfg_valid && cfg_ready)begin
   cfg_done<=1;
   if(!cfg_legal)cfg_error<=1;
   else begin
    state<=RUN;draining<=0;round<=0;tbase<=0;
    taps<=cfg_taps;uniq<=(cfg_taps+1)>>1;
    used<=0;started<=0;end_total<=0;acc<=0;
    coeffs<=cfg_coeffs;input_count<=0;output_count<=0;capacity_error<=0;
   end
  end else if(flush_valid && flush_ready)begin
   if(input_count==0)begin state<=DONE;flush_done<=1;end
   else begin
    draining<=1;
    end_total<={5'd0,input_count}+{15'd0,taps}-21'd1;
   end
  end else begin
   if(round!=0)begin
    if(round==1)begin
     if(advance)begin
      m_tdata<=rnd>32767 ? 16'sh7fff : rnd < -32768 ? 16'sh8000 : rnd[15:0];
      m_tuser<=clipped;m_tvalid<=1;round<=0;acc<=0;
     end
    end else begin acc<=lanesum;tbase<=tbase+LANES;round<=round-1'b1;end
   end
   if(state==RUN)begin
    if(draining && started==end_total && round==0 && !m_tvalid)begin
     draining<=0;state<=DONE;flush_done<=1;
    end else if(feed)begin
     history[0]<=feedv;
     for(i=1;i<MAX_TAPS;i=i+1)history[i]<=history[i-1];
     if(used<MAX_TAPS)used<=used+1'b1;
     started<=started+1'b1;
     if(real_take)input_count<=input_count+1'b1;
     for(i=0;i<U_MAX;i=i+1)
      dreg[i]<=(i<uniq-1) ? tq(i)+tq(taps-1-i) :
              (i==uniq-1 ? tq(center) : 17'sd0);
     acc<=0;tbase<=0;round<=rounds_need;
    end
   end
  end
 end
end
`ifndef SYNTHESIS
 initial if(MAX_TAPS<3 || MAX_TAPS>63 || !MAX_TAPS[0] || LANES<1 ||
            LANES>4 || MAX_INPUTS<1 || MAX_INPUTS>65535 ||
            DEFAULT_TAPS<3 || DEFAULT_TAPS>MAX_TAPS || !DEFAULT_TAPS[0])
  $fatal(1,"unsupported static configuration");
`endif
endmodule
