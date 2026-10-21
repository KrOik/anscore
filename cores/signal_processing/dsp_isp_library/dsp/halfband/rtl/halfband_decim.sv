// Half-band 2x decimator: y[m] = sum_n x[2m-n] h[n], signed16 Q1.15.
//
// Structural halfband contract: odd taps T, center tap c=(T-1)/2 is the
// implicit constant 0.5 (Q3.15: 16384), all taps with (n-c) even and n!=c
// are exactly zero, and h[n]=h[T-1-n]. Only the P nonzero symmetric pairs
// are configured: P=(T-1)/4 for T%4==1, P=(T+1)/4 for T%4==3. The MAC
// exploits the ~50% zero structure: P folded pair products plus the
// center shift-add, never the full T products.
//
// Rate contract (honest, no II1 claim): the even-indexed input x[2m]
// completes the window for y[m]. Odd-indexed inputs may be accepted while
// the shared MAC is busy; a triggering (even-indexed) accept requires the
// MAC free. Per output the MAC spends ROUNDS=ceil(P/LANES) clocks, so the
// sustained input period is >= (ROUNDS+1)/2 samples/clock best case and
// one output per 2 accepted inputs. m_tvalid is held stable under
// backpressure; output rate is exactly input rate / 2 in sample terms.
//
// Atomic config (cfg_valid/cfg_ready, cfg_done/cfg_error) applies a new
// odd tap count and packed unique coefficients in one edge and clears all
// state. Illegal even/out-of-range taps pulse cfg_error and change
// nothing. Explicit flush feeds virtual zeros until the full convolution
// support is emitted: total outputs = floor((N+T-2)/2)+1 for N>=1, none
// for an empty block. After flush the core stays in DONE until config or
// reset. Single clk, synchronous active-low rst_n.
module halfband_decim #(
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
localparam RUN=0,DONE=1;
reg state,draining;
reg [5:0] round,tbase;
reg [6:0] taps;
reg [4:0] pairs;
reg [6:0] used;
reg [16:0] started,end_total;
reg [16:0] feed_idx;
reg signed [15:0] history[0:MAX_TAPS-1];
reg signed [16:0] dreg[0:MAX_PAIRS-1];
reg signed [40:0] acc;
reg signed [40:0] acc_f;    // registered final sum (feeds round/clip/output)
reg signed [34:0] prod_q;   // pipelined multiply: muxes+mult then accumulate
reg        mph;             // 0 = product cycle, 1 = accumulate cycle
reg        tail;            // acc_f holds a finished sum awaiting a slot
reg signed [40:0] cseed;   // blocking temp: the center tap widened to 41 bits
reg [MAX_PAIRS*18-1:0] coeffs;

wire advance=!m_tvalid || m_tready;
wire signed [15:0] feedv=draining ? 16'sd0 : s_tdata;
// feed slot: odd indices never collide with the MAC, even indices trigger
wire canfeed=rst_n && state==RUN && !draining && !cfg_valid && !flush_valid &&
             input_count<MAX_INPUTS && (feed_idx[0] || (round==0 && !tail));
assign s_tready=canfeed;
wire real_take=s_tvalid && s_tready;
wire vfeed=draining && state==RUN && started<end_total &&
           (feed_idx[0] || (round==0 && !tail));
wire feed=real_take || vfeed;
wire trigger=feed && !feed_idx[0];
assign flush_ready=rst_n && state==RUN && !draining && round==0 &&
                    !m_tvalid && !tail && !cfg_valid;
assign cfg_ready=rst_n && (state==DONE ||
                  (state==RUN && !draining && round==0 && !m_tvalid && !tail));
// unique-pair count of a legal odd tap count
function [4:0] npairs;input [6:0] t;
 begin npairs=(t[1:0]==2'b01) ? {1'b0,t[6:2]} : {1'b0,(t+7'd1)>>2};end
endfunction
wire cfg_legal=cfg_taps[0] && cfg_taps>=6'd3 && cfg_taps<=MAX_TAPS &&
               npairs({1'b0,cfg_taps})<=MAX_PAIRS;
wire [5:0] rounds_need=(pairs+LANES-1)/LANES;
// tap k relative to the just-fed sample; zero beyond filled history
function signed [15:0] tq;input [6:0] k;
 begin
  if(k==0)tq=feedv;
  else if(k-1<used)tq=history[k-1];
  else tq=16'sd0;
 end
endfunction
wire [6:0] center=taps>>1;
wire toff=(taps[1:0]==2'b01);        // T%4==1 -> nonzero taps at odd n
// shared-lane products over term index tbase+l, terms 0..pairs-1
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
// The last MAC round's sum is captured into acc_f; rounding/saturation is
// then computed from the REGISTERED value one cycle later.  Without the
// stage, lanesum->round->clip->m_tdata formed the device-critical cone
// (~18 ns, fmax 55 MHz at the 50 MHz clock) and produced data-dependent
// saturated outputs on silicon while simulation stayed exact.
wire roundup=acc_f[14] && (acc_f[15] || |acc_f[13:0]);
wire [25:0] hi=acc_f[40:15]+{25'd0,roundup};
wire [15:0] rnd=hi[15:0];
// in range [-32768,32767] iff every bit above 15 duplicates the sign
wire clipped=hi[25:15]!={11{rnd[15]}};
wire negative=hi[25];
integer i;
always @(posedge clk)begin
 if(!rst_n)begin
  state<=RUN;draining<=0;round<=0;tbase<=0;taps<=DEFAULT_TAPS;
  pairs<=npairs({1'b0,DEFAULT_TAPS});used<=0;started<=0;end_total<=0;
  feed_idx<=0;acc<=0;acc_f<=0;prod_q<=0;mph<=0;tail<=0;coeffs<=DEFAULT_COEFFS;
  input_count<=0;output_count<=0;capacity_error<=0;
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
    state<=RUN;draining<=0;round<=0;tbase<=0;
    taps<={1'b0,cfg_taps};pairs<=npairs({1'b0,cfg_taps});
    used<=0;started<=0;end_total<=0;feed_idx<=0;acc<=0;acc_f<=0;prod_q<=0;mph<=0;tail<=0;
    coeffs<=cfg_coeffs;input_count<=0;output_count<=0;capacity_error<=0;
   end
  end else if(flush_valid && flush_ready)begin
   if(input_count==0)begin state<=DONE;flush_done<=1;end
   else begin
    draining<=1;
    end_total<=(({1'b0,input_count}+{10'd0,taps}-17'd2)>>1)+17'd1;
   end
  end else begin
   // shared-MAC progress; the final round waits for a free output slot
   if(round!=0)begin
    if(!mph)begin
     // lane_p muxes and the multiplier resolve during this cycle; the
     // registered product is added to acc next cycle, splitting the
     // mux->multiply->add->acc cone that was corrupting on silicon.
     prod_q<=lane_p[0];mph<=1;
    end else begin
     if(round==1)begin
      acc_f<=acc+{{6{prod_q[34]}},prod_q};round<=0;tail<=1;mph<=0;
     end else begin
      acc<=acc+{{6{prod_q[34]}},prod_q};tbase<=tbase+LANES;
      round<=round-1'b1;mph<=0;
     end
    end
   end
   if(tail && advance)begin
    m_tdata<=clipped ? (negative ? 16'sh8000 : 16'sh7fff) : rnd;
    m_tuser<=clipped;m_tvalid<=1;tail<=0;acc<=0;
   end
   if(state==RUN)begin
    if(draining && started==end_total && round==0 && !m_tvalid && !tail)begin
     draining<=0;state<=DONE;flush_done<=1;
    end else if(feed)begin
     history[0]<=feedv;
     for(i=1;i<MAX_TAPS;i=i+1)history[i]<=history[i-1];
     if(used<MAX_TAPS)used<=used+1'b1;
     feed_idx<=feed_idx+1'b1;
     if(real_take)input_count<=input_count+1'b1;
     if(trigger)begin
      for(i=0;i<MAX_PAIRS;i=i+1)
       dreg[i]<=(i<pairs) ?
        tq(2*i+(toff?7'd1:7'd0))+tq(taps-1-(2*i+(toff?7'd1:7'd0))) : 17'sd0;
      cseed = tq(center);            // 16 -> 41 bit sign-extend (blocking temp)
      // The implicit 0.5 center tap is a shift by 14. Seeding acc with it here
      // rather than adding it in the last round is the same integer sum and
      // takes a 41-bit adder off the output cone.
      acc <= cseed <<< 14;
      tbase<=0;round<=rounds_need;
      started<=started+1'b1;
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
