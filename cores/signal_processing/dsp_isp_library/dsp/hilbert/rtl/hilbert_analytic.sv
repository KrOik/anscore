// Antisymmetric odd-length Hilbert FIR plus aligned real path.
//
//   Q[n] = sum_{j=0}^{p-1} c_j * (x[n-C+d_j] - x[n-C-d_j]),  d_j = 2j+1
//   I[n] = x[n-C],   C = 2*PAIRS-1,  TAPS = 4*PAIRS-1
//
// c_j is the low-index (negative) tap of antisymmetric pair j; the high
// tap is implicitly -c_j, so antisymmetry and the zero-valued even taps
// are structural.  Coefficients are signed18 Q15; inactive pairs j >=
// active_pairs contribute exactly zero and the group delay stays C.
//
// LANES shared signed multipliers compute LANES products per clock for
// ROUNDS = ceil(PAIRS/LANES) rounds, so PAIRS*LANES... the core uses at
// most LANES multiplier operators (LANES<=4 keeps a Gowin build within
// the <=4 DSP-class budget; with -nodsp they become LUT multipliers).
// Accept-to-accept initiation interval is ROUNDS+1 clocks; the output
// result waits in `postv` under backpressure.  History moves only on
// `accept` (s_tvalid && s_tready).
module hilbert_analytic #(
 parameter integer PAIRS=16,
 parameter integer LANES=4
)(
 input wire clk,rst_n,
 input wire advance,
 input wire accept,
 input wire signed [15:0] s_tdata,
 input wire [5:0] active_pairs,
 input wire [PAIRS*18-1:0] coeffs_packed,
 input wire clear_state,
 output reg signed [15:0] i_out,
 output reg signed [15:0] q_out,
 output reg clip_out,
 output wire out_valid,
 output wire busy,
 output wire accept_idle
);
localparam integer TAPS=4*PAIRS-1;
localparam integer CENTER=2*PAIRS-1;
localparam integer ROUNDS=(PAIRS+LANES-1)/LANES;
reg signed [15:0] history[0:TAPS-1];
reg [6:0] used;
reg [5:0] round;          // >0: rounds remaining; 1 means last round
reg postv;                // output result pending downstream take
reg signed [16:0] dreg[0:PAIRS-1];
reg signed [15:0] i0;
reg signed [43:0] acc;
assign out_valid=postv;
assign busy=(round!=0) || postv;
assign accept_idle=(round==0);
// Post-shift tap value: index 0 is the sample being accepted.
function signed [15:0] tap;
 input integer k;
 begin
  if(k==0)tap=s_tdata;
  else if(k-1<used)tap=history[k-1];
  else tap=16'sd0;
 end
endfunction
wire signed [17:0] selc[0:PAIRS-1];
genvar gj;
generate for(gj=0;gj<PAIRS;gj=gj+1)begin:COEF
 assign selc[gj]=gj<active_pairs ? $signed(coeffs_packed[18*gj +: 18]) : 18'sd0;
end endgenerate
// Current-round lane products; lane k handles pair base+k. Up to four
// lanes; unused lanes contribute zero.
wire [9:0] base=(ROUNDS-round)*LANES;
wire signed [34:0] lane_p[0:3];
genvar gl;
generate for(gl=0;gl<4;gl=gl+1)begin:LANE
 assign lane_p[gl]=(gl<LANES && base+gl<PAIRS) ? dreg[base+gl]*selc[base+gl] : 35'sd0;
end endgenerate
wire signed [43:0] lanesum=acc+lane_p[0]+lane_p[1]+lane_p[2]+lane_p[3];
wire signed [43:0] accq=lanesum>>>15;
wire signed [43:0] accr=accq+((lanesum[14:0]>15'd16384 || (lanesum[14:0]==15'd16384 && accq[0])) ? 44'sd1 : 44'sd0);
wire clipped=accr>32767 || accr < -32768;
integer j;
always @(posedge clk)begin
 if(!rst_n)begin
  used<=0;round<=0;postv<=0;i_out<=0;q_out<=0;clip_out<=0;acc<=0;
 end else if(clear_state)begin
  used<=0;round<=0;postv<=0;
 end else begin
  if(advance && postv)postv<=0; // consumed by the measurement pipeline
  if(accept)begin
   for(j=0;j<PAIRS;j=j+1)dreg[j]<=tap(CENTER-(2*j+1))-tap(CENTER+(2*j+1));
   i0<=tap(CENTER);
   history[0]<=s_tdata;
   for(j=1;j<TAPS;j=j+1)history[j]<=history[j-1];
   if(used<TAPS)used<=used+1'b1;
   acc<=0;round<=ROUNDS;
  end else if(round!=0)begin
   if(round==1)begin
    if(!postv)begin
     q_out<=accr>32767 ? 16'sh7fff : accr < -32768 ? 16'sh8000 : accr[15:0];
     clip_out<=clipped;i_out<=i0;
     postv<=1;acc<=0;round<=0;
    end
   end else begin acc<=lanesum;round<=round-1'b1;end
  end
 end
end
`ifndef SYNTHESIS
 initial if(PAIRS<1 || PAIRS>32 || LANES<1 || LANES>4 || LANES>PAIRS)$fatal(1,"unsupported PAIRS/LANES");
`endif
endmodule
