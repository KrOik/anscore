// Half-band 2x interpolator: y[t] = sum_k x[k] h[t-2k], signed16 Q1.15.
//
// Same structural halfband contract as the decimator: odd taps T, implicit
// center tap 0.5, (n-c)-even taps structurally zero, symmetric pairs.
// Per accepted input x[n] exactly two outputs are produced in order:
//   * the pure delay output x[n-d]       (d=P for T%4==1, P-1 for T%4==3)
//   * the filtered output  2*sum_i u_i (x[n-i]+x[n-(2P-1-i)])
// Output order: T%4==1 emits [delay, filter]; T%4==3 emits [filter, delay].
// The implicit x2 interpolation gain turns the 0.5 phase sums of the
// shared halfband table into unity gain on both phases. The filtered
// phase uses only the P nonzero pairs (no center term); the delay phase
// needs no multiplier at all.
//
// Rate contract (honest): output rate is exactly 2x input in sample terms.
// One input is accepted only while the emit state machine and the shared
// MAC are idle; per input the core spends about ROUNDS+3 clocks where
// ROUNDS=ceil(P/LANES), so sustained input throughput is bounded well
// below one sample/clock. Outputs are held stable under backpressure; a
// stalled consumer simply stretches each input period. There is one
// pending output slot plus one input in flight ¡ª deeper buffering is a
// system-level FIFO concern (infra/stream), not part of this core.
//
// Atomic config identical to halfband_decim: legal odd taps + packed
// unique coefficients apply in one edge and clear state; illegal taps
// pulse cfg_error and change nothing. Flush feeds (T-1)/2 virtual zero
// inputs; the last virtual input emits only its first output so the total
// flushed output count is exactly 2N+T-2 for N>=1 (the would-be trailing
// output is a structural zero and is not emitted), none for N=0. Single
// clk, synchronous active-low rst_n.
module halfband_interp #(
 parameter integer MAX_PAIRS=9,
 parameter integer LANES=4,
 parameter integer MAX_INPUTS=65535,
 parameter [5:0] DEFAULT_TAPS=31,
 parameter [MAX_PAIRS*18-1:0] DEFAULT_COEFFS=162'ha017f4770148bfdb5003a7ffb7000340000
)(
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg signed [15:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [5:0] cfg_taps,
 input wire [MAX_PAIRS*18-1:0] cfg_coeffs,
 output reg cfg_done,cfg_error,
 input wire flush_valid,output wire flush_ready,output reg flush_done,
 output reg [15:0] input_count,output reg [20:0] output_count,
 output reg capacity_error
);
localparam integer MAX_TAPS=4*MAX_PAIRS+1;
localparam integer HIST=2*MAX_PAIRS+1;
localparam RUN=0,DONE=1;
localparam OACCEPT=0,OEMIT1=1,OEMIT2=2;
reg state,draining;
reg [1:0] ostate;
reg [5:0] round,tbase;
reg [6:0] taps;
reg [4:0] pairs;
reg [6:0] used,vfeeds,vend;
reg last_feed;
reg signed [15:0] ihist[0:HIST-1];
reg signed [16:0] dreg[0:MAX_PAIRS-1];
reg signed [15:0] dval,fval;
reg fclip;
reg signed [40:0] acc;
reg signed [40:0] acc_f;    // registered final MAC sum (round/clip source)
reg signed [34:0] prod_q;   // pipelined multiply stage
reg        mph;             // 0 = product cycle, 1 = accumulate cycle
reg        tail;            // acc_f holds a finished sum this beat
reg [MAX_PAIRS*18-1:0] coeffs;

wire advance=!m_tvalid || m_tready;
wire signed [15:0] feedv=draining ? 16'sd0 : s_tdata;
wire idle=(ostate==OACCEPT && round==0 && !tail);
assign s_tready=rst_n && state==RUN && !draining && !cfg_valid &&
                !flush_valid && input_count<MAX_INPUTS && idle;
wire real_take=s_tvalid && s_tready;
wire vfeed=draining && state==RUN && vfeeds<vend && idle;
wire feed=real_take || vfeed;
assign flush_ready=rst_n && state==RUN && !draining && idle &&
                    !m_tvalid && !cfg_valid;
assign cfg_ready=rst_n && (state==DONE ||
                  (state==RUN && !draining && idle && !m_tvalid));
function [4:0] npairs;input [6:0] t;
 begin npairs=(t[1:0]==2'b01) ? {1'b0,t[6:2]} : {1'b0,(t+7'd1)>>2};end
endfunction
wire cfg_legal=cfg_taps[0] && cfg_taps>=6'd3 && cfg_taps<=MAX_TAPS &&
               npairs({1'b0,cfg_taps})<=MAX_PAIRS;
wire [5:0] rounds_need=(pairs+LANES-1)/LANES;
wire first_direct=(taps[1:0]==2'b01);
wire [6:0] dspan=2*pairs-1;                 // folded pair depth
wire [6:0] ddelay=first_direct ? {2'b0,pairs} : {2'b0,pairs}-7'd1;
// input-domain tap k relative to the just-fed sample
function signed [15:0] iht;input [6:0] k;
 begin
  if(k==0)iht=feedv;
  else if(k-1<used)iht=ihist[k-1];
  else iht=16'sd0;
 end
endfunction
wire signed [34:0] lane_p[0:3];
genvar gl;
generate for(gl=0;gl<4;gl=gl+1)begin:LANE
 assign lane_p[gl]=(gl<LANES && tbase+gl<pairs) ?
        dreg[tbase+gl]*$signed(coeffs[18*(tbase+gl) +: 18]) : 35'sd0;
end endgenerate
wire signed [40:0] lanesum=acc+{{6{lane_p[0][34]}},lane_p[0]}
                            +{{6{lane_p[1][34]}},lane_p[1]}
                            +{{6{lane_p[2][34]}},lane_p[2]}
                            +{{6{lane_p[3][34]}},lane_p[3]};
// x2 interpolation gain: filtered output is RNE(lanesum/2**14), saturating
// RNE with no bias adder, no 27-bit barrel shift and no magnitude comparator.
// The rounding decision compares the low 14 bits against 2**13 (or 2**13+1),
// and either comparison is a function of bits 12..14 alone: (s[13:0] >= 2**13)
// IS s[13], and (s[13:0] >= 2**13+1) IS s[13] & |s[12:0].  The bias is below
// 2**14 so it can never carry into bit 14, hence the rounded value's bits
// 14 and up are just this sum's bits 40:14 plus that one optional increment.
// The final MAC round's sum is registered into acc_f first; rounding and
// saturation then evaluate the REGISTERED value one cycle later -- this
// splits the former device-critical cone acc+products->round->clip->fval.
wire roundup=acc_f[13] && (acc_f[14] || |acc_f[12:0]);
wire [26:0] hi=acc_f[40:14]+{26'd0,roundup};
wire [15:0] rnd=hi[15:0];
// in range [-32768,32767] iff every bit above 15 duplicates the sign
wire clipped=hi[26:15]!={12{rnd[15]}};
wire negative=hi[26];
// direct phase emits the delayed input exactly (0.5 center tap x2 gain);
// captured procedurally ¡ª iht() reads the history array, so it must not
// live in a continuous assign (simulators can miss array sensitivity)
integer i;
always @(posedge clk)begin
 if(!rst_n)begin
  state<=RUN;draining<=0;ostate<=OACCEPT;round<=0;tbase<=0;
  taps<=DEFAULT_TAPS;pairs<=npairs({1'b0,DEFAULT_TAPS});
  used<=0;vfeeds<=0;vend<=0;last_feed<=0;dval<=0;fval<=0;fclip<=0;acc<=0;
  acc_f<=0;prod_q<=0;mph<=0;tail<=0;
  coeffs<=DEFAULT_COEFFS;input_count<=0;output_count<=0;capacity_error<=0;
  m_tvalid<=0;m_tdata<=0;m_tuser<=0;cfg_done<=0;cfg_error<=0;flush_done<=0;
  for(i=0;i<MAX_PAIRS;i=i+1)dreg[i]<=0;
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
    state<=RUN;draining<=0;ostate<=OACCEPT;round<=0;tbase<=0;
    taps<={1'b0,cfg_taps};pairs<=npairs({1'b0,cfg_taps});
    used<=0;vfeeds<=0;vend<=0;last_feed<=0;acc<=0;acc_f<=0;prod_q<=0;mph<=0;tail<=0;
    coeffs<=cfg_coeffs;input_count<=0;output_count<=0;capacity_error<=0;
   end
  end else if(flush_valid && flush_ready)begin
   if(input_count==0)begin state<=DONE;flush_done<=1;end
   else begin draining<=1;vfeeds<=0;vend<=(taps-1)>>1;end
  end else begin
   // filtered-result MAC; the result lands in fval, not the output slot
   if(round!=0)begin
    if(!mph)begin
     prod_q<=lane_p[0];mph<=1;
    end else begin
     if(round==1)begin
      acc_f<=acc+{{6{prod_q[34]}},prod_q};tail<=1;round<=0;acc<=0;mph<=0;
     end else begin
      acc<=acc+{{6{prod_q[34]}},prod_q};tbase<=tbase+LANES;
      round<=round-1'b1;mph<=0;
     end
    end
   end
   if(tail)begin
    fval<=clipped ? (negative ? 16'sh8000 : 16'sh7fff) : rnd;
    fclip<=clipped;tail<=0;
   end
   if(state==RUN)begin
    if(draining && vfeeds==vend && ostate==OACCEPT && round==0 &&
       !m_tvalid && !tail)begin
     draining<=0;state<=DONE;flush_done<=1;
    end else begin
     case(ostate)
      OEMIT1:if(advance && (first_direct || (round==0 && !tail)))begin
              m_tdata<=first_direct ? dval : fval;
              m_tuser<=first_direct ? 1'b0 : fclip;
              m_tvalid<=1;ostate<=last_feed ? OACCEPT : OEMIT2;
             end
      OEMIT2:if(advance && (first_direct ? (round==0 && !tail) : 1'b1))begin
              m_tdata<=first_direct ? fval : dval;
              m_tuser<=first_direct ? fclip : 1'b0;
              m_tvalid<=1;ostate<=OACCEPT;
             end
      default:;
     endcase
     if(feed)begin
      ihist[0]<=feedv;
      for(i=1;i<HIST;i=i+1)ihist[i]<=ihist[i-1];
      if(used<HIST)used<=used+1'b1;
      if(real_take)input_count<=input_count+1'b1;
      if(vfeed)vfeeds<=vfeeds+1'b1;
      last_feed<=vfeed && vfeeds+1'b1==vend;
      for(i=0;i<MAX_PAIRS;i=i+1)
       dreg[i]<=(i<pairs) ? iht(i)+iht(dspan-i) : 17'sd0;
      dval<=iht(ddelay);acc<=0;tbase<=0;round<=rounds_need;
      ostate<=OEMIT1;
     end
    end
   end
  end
 end
end
`ifndef SYNTHESIS
 initial if(MAX_PAIRS<1 || MAX_PAIRS>15 || LANES<1 || LANES>4 ||
            MAX_INPUTS<1 || MAX_INPUTS>65535 || DEFAULT_TAPS<3 ||
            DEFAULT_TAPS>4*MAX_PAIRS+1 || !DEFAULT_TAPS[0])
  $fatal(1,"unsupported static configuration");
`endif
endmodule
