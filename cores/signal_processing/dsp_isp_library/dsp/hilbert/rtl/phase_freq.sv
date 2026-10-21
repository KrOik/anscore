// Envelope, instantaneous phase and instantaneous frequency for a paired
// I/Q analytic stream.
//
// Phase: first-octant reduce (a=min|.|, b=max|.|); 17 pipelined restoring
// division steps give r=(floor(a*2^17/b)+1)>>1 in 0..65536; a 257-entry
// atan table with linear interpolation gives theta_oct in brads
// (1 brad = 2pi/65536). Octant/quadrant remap yields phase 0..65535.
// Maximum measured phase error ~1.05 brads for magnitude >= 32.
//
// Envelope: x-path of a vectoring CORDIC (sigma=+1 for y>=0 else -1,
// inputs <<4, 16 iterations) runs in parallel with the divider; the raw
// x_f ~ K*mag*16 is scaled by ENV_C/2^19 and rounded nearest-even.
// Relative error <0.04% for magnitude > 2000, <1 LSB absolute for small
// magnitudes; result saturates to 65535.
//
// Frequency: f[n] = wrap16(phase[n]-phase[n-1]) (smallest signed step,
// i.e. unsigned 16-bit difference reinterpreted signed). First output
// after clear and every zero-amplitude sample emit freq = 0.
// Zero amplitude (I=Q=0): phase=0, freq=0, env=0, zero flag m_tuser[1].
//
// 21 registered stages, globally stalled by `advance`. The output word
// {freq,phase,env,q,i} holds stable while m_tvalid && !m_tready.
module phase_freq (
 input wire clk,rst_n,
 input wire advance,
 input wire in_valid,
 input wire signed [15:0] i_in,
 input wire signed [15:0] q_in,
 input wire clip_in,
 input wire clear_state,
 output reg [79:0] m_tdata,
 output reg [1:0] m_tuser,
 output reg m_tvalid,
 output wire busy
);
// atan base/interp tables; regenerate with gen_coeffs.py --emit-rtl
localparam [3597:0] PTAB = { 14'd8192, 14'd8172, 14'd8151, 14'd8131, 14'd8110, 14'd8089, 14'd8068, 14'd8047, 14'd8026, 14'd8005, 14'd7984, 14'd7963, 14'd7942, 14'd7920, 14'd7899, 14'd7877, 14'd7856, 14'd7834, 14'd7812, 14'd7790, 14'd7768, 14'd7746, 14'd7724, 14'd7702, 14'd7679, 14'd7657, 14'd7635, 14'd7612, 14'd7589, 14'd7566, 14'd7544, 14'd7521, 14'd7498, 14'd7475, 14'd7451, 14'd7428, 14'd7405, 14'd7381, 14'd7358, 14'd7334, 14'd7310, 14'd7286, 14'd7262, 14'd7238, 14'd7214, 14'd7190, 14'd7166, 14'd7141, 14'd7117, 14'd7092, 14'd7068, 14'd7043, 14'd7018, 14'd6993, 14'd6968, 14'd6943, 14'd6917, 14'd6892, 14'd6867, 14'd6841, 14'd6815, 14'd6790, 14'd6764, 14'd6738, 14'd6712, 14'd6686, 14'd6660, 14'd6633, 14'd6607, 14'd6580, 14'd6554, 14'd6527, 14'd6500, 14'd6473, 14'd6446, 14'd6419, 14'd6392, 14'd6365, 14'd6337, 14'd6310, 14'd6282, 14'd6254, 14'd6227, 14'd6199, 14'd6171, 14'd6142, 14'd6114, 14'd6086, 14'd6058, 14'd6029, 14'd6000, 14'd5972, 14'd5943, 14'd5914, 14'd5885, 14'd5856, 14'd5826, 14'd5797, 14'd5768, 14'd5738, 14'd5708, 14'd5679, 14'd5649, 14'd5619, 14'd5589, 14'd5559, 14'd5528, 14'd5498, 14'd5467, 14'd5437, 14'd5406, 14'd5375, 14'd5344, 14'd5313, 14'd5282, 14'd5251, 14'd5220, 14'd5188, 14'd5157, 14'd5125, 14'd5094, 14'd5062, 14'd5030, 14'd4998, 14'd4966, 14'd4933, 14'd4901, 14'd4869, 14'd4836, 14'd4803, 14'd4771, 14'd4738, 14'd4705, 14'd4672, 14'd4639, 14'd4605, 14'd4572, 14'd4539, 14'd4505, 14'd4471, 14'd4438, 14'd4404, 14'd4370, 14'd4336, 14'd4302, 14'd4267, 14'd4233, 14'd4199, 14'd4164, 14'd4129, 14'd4095, 14'd4060, 14'd4025, 14'd3990, 14'd3955, 14'd3920, 14'd3884, 14'd3849, 14'd3813, 14'd3778, 14'd3742, 14'd3706, 14'd3670, 14'd3635, 14'd3599, 14'd3562, 14'd3526, 14'd3490, 14'd3453, 14'd3417, 14'd3380, 14'd3344, 14'd3307, 14'd3270, 14'd3233, 14'd3196, 14'd3159, 14'd3122, 14'd3085, 14'd3047, 14'd3010, 14'd2973, 14'd2935, 14'd2897, 14'd2860, 14'd2822, 14'd2784, 14'd2746, 14'd2708, 14'd2670, 14'd2632, 14'd2594, 14'd2555, 14'd2517, 14'd2478, 14'd2440, 14'd2401, 14'd2363, 14'd2324, 14'd2285, 14'd2246, 14'd2207, 14'd2168, 14'd2129, 14'd2090, 14'd2051, 14'd2012, 14'd1973, 14'd1933, 14'd1894, 14'd1854, 14'd1815, 14'd1775, 14'd1736, 14'd1696, 14'd1656, 14'd1617, 14'd1577, 14'd1537, 14'd1497, 14'd1457, 14'd1417, 14'd1377, 14'd1337, 14'd1297, 14'd1257, 14'd1217, 14'd1177, 14'd1136, 14'd1096, 14'd1056, 14'd1015, 14'd975, 14'd935, 14'd894, 14'd854, 14'd813, 14'd773, 14'd732, 14'd692, 14'd651, 14'd610, 14'd570, 14'd529, 14'd489, 14'd448, 14'd407, 14'd367, 14'd326, 14'd285, 14'd244, 14'd204, 14'd163, 14'd122, 14'd81, 14'd41, 14'd0 };
localparam [1535:0] DTAB = { 6'd20, 6'd21, 6'd20, 6'd21, 6'd21, 6'd21, 6'd21, 6'd21, 6'd21, 6'd21, 6'd21, 6'd21, 6'd22, 6'd21, 6'd22, 6'd21, 6'd22, 6'd22, 6'd22, 6'd22, 6'd22, 6'd22, 6'd22, 6'd23, 6'd22, 6'd22, 6'd23, 6'd23, 6'd23, 6'd22, 6'd23, 6'd23, 6'd23, 6'd24, 6'd23, 6'd23, 6'd24, 6'd23, 6'd24, 6'd24, 6'd24, 6'd24, 6'd24, 6'd24, 6'd24, 6'd24, 6'd25, 6'd24, 6'd25, 6'd24, 6'd25, 6'd25, 6'd25, 6'd25, 6'd25, 6'd26, 6'd25, 6'd25, 6'd26, 6'd26, 6'd25, 6'd26, 6'd26, 6'd26, 6'd26, 6'd26, 6'd27, 6'd26, 6'd27, 6'd26, 6'd27, 6'd27, 6'd27, 6'd27, 6'd27, 6'd27, 6'd27, 6'd28, 6'd27, 6'd28, 6'd28, 6'd27, 6'd28, 6'd28, 6'd29, 6'd28, 6'd28, 6'd28, 6'd29, 6'd29, 6'd28, 6'd29, 6'd29, 6'd29, 6'd29, 6'd30, 6'd29, 6'd29, 6'd30, 6'd30, 6'd29, 6'd30, 6'd30, 6'd30, 6'd30, 6'd31, 6'd30, 6'd31, 6'd30, 6'd31, 6'd31, 6'd31, 6'd31, 6'd31, 6'd31, 6'd31, 6'd32, 6'd31, 6'd32, 6'd31, 6'd32, 6'd32, 6'd32, 6'd32, 6'd33, 6'd32, 6'd32, 6'd33, 6'd33, 6'd32, 6'd33, 6'd33, 6'd33, 6'd33, 6'd34, 6'd33, 6'd33, 6'd34, 6'd34, 6'd33, 6'd34, 6'd34, 6'd34, 6'd34, 6'd35, 6'd34, 6'd34, 6'd35, 6'd35, 6'd34, 6'd35, 6'd35, 6'd35, 6'd35, 6'd35, 6'd36, 6'd35, 6'd36, 6'd35, 6'd36, 6'd36, 6'd36, 6'd35, 6'd36, 6'd37, 6'd36, 6'd36, 6'd37, 6'd36, 6'd37, 6'd36, 6'd37, 6'd37, 6'd37, 6'd37, 6'd37, 6'd37, 6'd37, 6'd38, 6'd37, 6'd37, 6'd38, 6'd38, 6'd37, 6'd38, 6'd38, 6'd38, 6'd38, 6'd38, 6'd38, 6'd38, 6'd39, 6'd38, 6'd39, 6'd38, 6'd39, 6'd38, 6'd39, 6'd39, 6'd39, 6'd39, 6'd39, 6'd39, 6'd39, 6'd39, 6'd39, 6'd39, 6'd40, 6'd39, 6'd40, 6'd39, 6'd40, 6'd39, 6'd40, 6'd40, 6'd39, 6'd40, 6'd40, 6'd40, 6'd40, 6'd40, 6'd40, 6'd40, 6'd40, 6'd40, 6'd40, 6'd40, 6'd41, 6'd40, 6'd40, 6'd41, 6'd40, 6'd40, 6'd41, 6'd40, 6'd41, 6'd40, 6'd41, 6'd40, 6'd41, 6'd41, 6'd40, 6'd41, 6'd40, 6'd41, 6'd41, 6'd40, 6'd41, 6'd41, 6'd41, 6'd40, 6'd41, 6'd41, 6'd41, 6'd40, 6'd41 };
localparam signed [15:0] ENV_C=16'sd19898; // round((1/(16*K_cordic))*2^19)
reg [20:0] v;
assign busy=|v;
// Stage-0 combinational reduce, registered on in_valid.
wire [15:0] ai=i_in[15] ? -i_in : i_in;
wire [15:0] aq=q_in[15] ? -q_in : q_in;
wire [15:0] bmax_c=(ai>=aq) ? ai : aq;
wire [15:0] amin_c=(ai>=aq) ? aq : ai;
wire oct_c=aq>ai;
wire si_c=i_in<0,sq_c=q_in<0;
wire zero_c=(i_in==0 && q_in==0);
// Divider/CORDIC stage registers. carry packs {i,q,clip,zero,si,sq,oct}.
reg [17:0] rem_s[0:17],quot_s[0:17],b_s[0:17];
reg signed [22:0] xc_s[0:17],yc_s[0:17];
reg [36:0] carry[0:17];
reg [36:0] carry18;
reg [13:0] th_oct;
reg [15:0] env_s18;
reg [15:0] phase_s19,env_s19,i_s19,q_s19;
reg clip_s19,zero_s19;
reg [15:0] prev_phase;
reg have_prev;
// Stage 18 combinational: atan LUT + interpolation; CORDIC scaling.
wire [17:0] r17=(quot_s[17]+18'd1)>>>1;
wire [8:0] lidx=r17[16] ? 9'd256 : {1'b0,r17[15:8]};
wire [7:0] lfrac=r17[16] ? 8'd0 : r17[7:0];
wire [11:0] ptab_idx=({4'd0,lidx}<<<3)+({4'd0,lidx}<<<2)+({4'd0,lidx}<<<1);
wire [10:0] dtab_idx=({3'd0,lidx[7:0]}<<<2)+({3'd0,lidx[7:0]}<<<1);
wire [13:0] pbase=PTAB[ptab_idx +: 14];
wire [5:0] pdt=DTAB[dtab_idx +: 6];
wire [13:0] pprod=(pdt[0] ? {6'd0,lfrac} : 14'd0)+(pdt[1] ? {5'd0,lfrac,1'b0} : 14'd0)
 +(pdt[2] ? {4'd0,lfrac,2'b00} : 14'd0)+(pdt[3] ? {3'd0,lfrac,3'b000} : 14'd0)
 +(pdt[4] ? {2'd0,lfrac,4'b0000} : 14'd0)+(pdt[5] ? {1'd0,lfrac,5'b00000} : 14'd0);
wire [6:0] pdq={1'b0,pprod[13:8]};
wire [6:0] pdr=pdq+((pprod[7:0]>8'd128 || (pprod[7:0]==8'd128 && pdq[0])) ? 7'd1 : 7'd0);
// ENV_C=19898 = 2^14+2^11+2^10+2^8+2^7+2^5+2^4+2^3+2^1 (shift/add: no `*`
// operator here, so the whole core uses at most LANES multipliers).
wire signed [38:0] eprod=(xc_s[17]<<<14)+(xc_s[17]<<<11)+(xc_s[17]<<<10)
 +(xc_s[17]<<<8)+(xc_s[17]<<<7)+(xc_s[17]<<<5)+(xc_s[17]<<<4)+(xc_s[17]<<<3)
 +(xc_s[17]<<<1);
wire signed [38:0] eq=eprod>>>19;
wire signed [38:0] er=eq+((eprod[18:0]>19'd262144 || (eprod[18:0]==19'd262144 && eq[0])) ? 39'sd1 : 39'sd0);
// Stage 19 combinational: octant/quadrant remap.
wire [14:0] th1=carry18[0] ? 15'd16384-{1'b0,th_oct} : {1'b0,th_oct};
wire [16:0] ph17=carry18[2] ? (carry18[1] ? 17'd32768+{2'b00,th1} : 17'd32768-{2'b00,th1})
                            : (carry18[1] ? 17'd65536-{2'b00,th1} : {2'b00,th1});
// Stage 20 combinational: wrapped first difference of phase.
wire [15:0] fdiff=phase_s19-prev_phase;
wire signed [15:0] freq_s20=zero_s19 ? 16'sd0 : (have_prev ? fdiff : 16'sd0);
genvar gs;
generate for(gs=1;gs<=17;gs=gs+1)begin:DIV
 always @(posedge clk)begin
  if(advance && v[gs-1])begin
   if({rem_s[gs-1],1'b0}>={3'b000,b_s[gs-1][15:0]})begin
    rem_s[gs]<={rem_s[gs-1],1'b0}-{3'b000,b_s[gs-1][15:0]};
    quot_s[gs]<={quot_s[gs-1][16:0],1'b1};
   end else begin
    rem_s[gs]<={rem_s[gs-1],1'b0};
    quot_s[gs]<={quot_s[gs-1][16:0],1'b0};
   end
   b_s[gs]<=b_s[gs-1];carry[gs]<=carry[gs-1];
   if(gs<=16)begin
    if(yc_s[gs-1]>=0)begin
     xc_s[gs]<=xc_s[gs-1]+(yc_s[gs-1]>>>(gs-1));
     yc_s[gs]<=yc_s[gs-1]-(xc_s[gs-1]>>>(gs-1));
    end else begin
     xc_s[gs]<=xc_s[gs-1]-(yc_s[gs-1]>>>(gs-1));
     yc_s[gs]<=yc_s[gs-1]+(xc_s[gs-1]>>>(gs-1));
    end
   end else begin xc_s[gs]<=xc_s[gs-1];yc_s[gs]<=yc_s[gs-1];end
  end
 end
end endgenerate
always @(posedge clk)begin
 if(!rst_n)begin
  v<=0;m_tvalid<=0;m_tdata<=0;m_tuser<=0;prev_phase<=0;have_prev<=0;
 end else if(clear_state)begin
  v<=0;m_tvalid<=0;prev_phase<=0;have_prev<=0;
 end else if(advance)begin
  v<={v[19:0],in_valid};
  m_tvalid<=v[19];
  if(in_valid)begin
   rem_s[0]<={2'b00,amin_c};quot_s[0]<=0;b_s[0]<={2'b00,bmax_c};
   xc_s[0]<={3'b000,bmax_c,4'd0};yc_s[0]<={3'b000,amin_c,4'd0};
   carry[0]<={i_in,q_in,clip_in,zero_c,si_c,sq_c,oct_c};
  end
  if(v[17])begin
   th_oct<=(lidx==9'd256) ? pbase : pbase+pdr;
   env_s18<=(er>65535) ? 16'd65535 : er[15:0];
   carry18<=carry[17];
  end
  if(v[18])begin
   phase_s19<=carry18[3] ? 16'd0 : ph17[15:0];env_s19<=env_s18;
   i_s19<=carry18[36:21];q_s19<=carry18[20:5];
   clip_s19<=carry18[4];zero_s19<=carry18[3];
  end
  if(v[19])begin
   m_tdata<={freq_s20,phase_s19,env_s19,q_s19,i_s19};
   m_tuser<={zero_s19,clip_s19};
   prev_phase<=phase_s19;have_prev<=1;
  end
 end
end
endmodule
