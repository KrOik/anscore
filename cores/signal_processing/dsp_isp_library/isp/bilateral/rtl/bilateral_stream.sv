`timescale 1ns/1ps
// ISP-18 edge-preserving denoise: 3x3 bilateral filter, reference config.
//
// out = sum_k( ws[k] * wr(|tap_k - center|) * tap_k )
//       ------------------------------------------------   over a 3x3 window
//             sum_k( ws[k] * wr(|tap_k - center|) )
//
// Window source: infra/window/stream_window_padded (K=3, PAD_MODE=1
// replicate default), tap k at m_tdata[k*BITS +: BITS] row-major, tap 4 =
// centre pixel.  The padded window engine captures one row then replays its
// extended raster rows, so the *input* side runs in bursts (~0.5 px/cycle
// sustained); every stage after the window is II=1.
//
// Fixed-point pipeline (all multiplies are explicit shift-adds, no DSP):
//   S1: diff=|tap-center|, wr = rlut[diff>>(BITS-WR_AW)]   (register LUTs)
//   S2: wq = (slut[k]*wr) >> WS_W                          (truncated weight)
//   S3: num = sum(tap*wq), den = sum(wq)                   (wide accumulate)
//   DIV: fp_div_pipe (infra/fixedpoint/rtl/recip_div.sv), FB=0 -> RNE divide,
//        II=1, latency DN+1 cycles.  den==0 -> passthrough centre pixel.
//   OUT: combinational select (bypass / den0 -> centre, clip -> saturate).
//
// Runtime config follows the lsc_stream convention: a cfg_valid bundle
// {cfg_rsvd[5:0], cfg_lswap, cfg_bypass} is pending and commits atomically
// at the next accepted SOF pixel; non-zero cfg_rsvd is rejected with
// cfg_error (no state change).  The lt_* port writes sigma-derived weight
// tables into the SHADOW copy; cfg_lswap at commit copies shadow -> active
// in one cycle, so a table reload can never split a frame.  lt_ready drops
// only on the commit edge itself.  lt_error pulses on accepted out-of-range
// addresses or spatial entries wider than WS_W.
//
// Single clk, synchronous active-low rst_n; reset restores the default
// sigma_d=1.0 / sigma_r=25 tables (SLUT_INIT/RLUT_INIT parameters) into both
// copies and drops all in-flight state.  Full derivation in ../SPEC.md.
module bilateral_stream #(
 parameter BITS=8,             // pixel width: 8 or 10
 parameter WIDTH=32,           // frame width  (compile-time)
 parameter HEIGHT=24,          // frame height (compile-time)
 parameter PAD_MODE=1,         // 1 = replicate border, 0 = zero pad
 parameter WS_W=4,             // spatial weight width (<=WR_W)
 parameter WR_W=8,             // range weight width
 parameter WR_AW=6,            // range LUT index bits (entries = 2**WR_AW)
 parameter [9*WS_W-1:0] SLUT_INIT=36'h6969f9696,   // sigma_d=1.0
 parameter [(1<<WR_AW)*WR_W-1:0] RLUT_INIT=512'h00000000000000000000000000000000000000000000000000000000000000000000000000000000000101020304060a0e151d2836475a7088a1b9d0e3f2fcff // sigma_r=25
)(
 input wire clk,rst_n,
 // pixel stream in: tuser=SOF, tlast=EOL
 input wire [BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 // pixel stream out (same W x H raster, same sidebands)
 output wire [BITS-1:0] m_tdata,
 output wire m_tvalid,m_tuser,m_tlast,input wire m_tready,
 // scalar config bundle, commits at next SOF
 input wire cfg_valid,output wire cfg_ready,
 input wire cfg_bypass,input wire cfg_lswap,input wire [5:0] cfg_rsvd,
 output reg cfg_done,cfg_error,
 // LUT write port (shadow copy): addr 0..RLN-1 = range, RLN..RLN+8 = spatial
 input wire lt_valid,output wire lt_ready,
 input wire [WR_AW:0] lt_addr,input wire [WR_W-1:0] lt_data,
 output reg lt_error,
 output wire o_error   // sticky stream-protocol violation flag (window core)
);
localparam K=3, TAPS=9;
localparam RLN=(1<<WR_AW);
localparam DEN_W=WR_W+4;              // sum of 9 weights <= 9*239 = 2151
localparam NUM_W=BITS+DEN_W;          // numerator <= maxpix * max_den
localparam AW=NUM_W+1,BW=DEN_W+1,FB=0,OW=BITS+1;
localparam DN=AW+FB;                  // fp_div_pipe stage count, latency DN+1

// ---------------------------------------------------------------- window
wire [TAPS*BITS-1:0] wd;
wire wv,wu,wl,werr;
wire advance=!m_tvalid || m_tready;
stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),
 .K(K),.PAD_MODE(PAD_MODE)) win(
 .clk(clk),.rst_n(rst_n),
 .s_tdata(s_tdata),.s_tvalid(s_tvalid),.s_tuser(s_tuser),.s_tlast(s_tlast),
 .s_tready(s_tready),
 .m_tdata(wd),.m_tvalid(wv),.m_tuser(wu),.m_tlast(wl),.m_tready(advance),
 .marker_error(werr));
assign o_error=werr;

// --------------------------------------------------------------- LUTs
// Active tables feed the S1 combinational reads; lt_* writes go to the
// shadow copy; a committed cfg_lswap copies shadow -> active atomically at
// SOF.  Synchronous-read register tables; reset loads the reference tables.
reg [WR_W-1:0] rlut[0:RLN-1],rlut_s[0:RLN-1];
reg [WS_W-1:0] slut[0:TAPS-1],slut_s[0:TAPS-1];

// ------------------------------------------------------ stage1: range LUT
wire [BITS-1:0] tap[0:TAPS-1];
wire [WR_AW-1:0] widx[0:TAPS-1];
genvar gk;
generate for(gk=0;gk<TAPS;gk=gk+1) begin: tapdiff
 assign tap[gk]=wd[gk*BITS +: BITS];
 wire [BITS-1:0] c=wd[4*BITS +: BITS];
 assign widx[gk]=((tap[gk]>c)?(tap[gk]-c):(c-tap[gk])) >> (BITS-WR_AW);
end endgenerate

reg v1,v2,v3;
reg [BITS-1:0] p1[0:TAPS-1],p2[0:TAPS-1];
reg [WR_W-1:0] wr1[0:TAPS-1],wq2[0:TAPS-1];
reg [BITS-1:0] c1,c2,c3;
reg u1,l1,u2,l2,u3,l3,b1,b2,b3;
integer i;

// ------------------------------------------------- stage2: combine weights
// wq = (slut[k]*wr) >> WS_W  (WS_W x WR_W shift-add product, truncated)
function [WS_W+WR_W-1:0] mul_sw;
 input [WS_W-1:0] a; input [WR_W-1:0] b; integer k;
 reg [WS_W+WR_W-1:0] acc;
 begin acc={WS_W+WR_W{1'b0}};
  for(k=0;k<WS_W;k=k+1) if(a[k]) acc=acc+({{WS_W{1'b0}},b}<<k);
  mul_sw=acc; end
endfunction
wire [WR_W-1:0] wqc[0:TAPS-1];
generate for(gk=0;gk<TAPS;gk=gk+1) begin: wcombine
 assign wqc[gk]=(mul_sw(slut[gk],wr1[gk]) >> WS_W);
end endgenerate

// --------------------------------------- stage3: numerator / denominator
// tap*wq: BITS x WR_W shift-add product (never a DSP)
function [BITS+WR_W-1:0] mul_pw;
 input [BITS-1:0] a; input [WR_W-1:0] b; integer k;
 reg [BITS+WR_W-1:0] acc;
 begin acc={BITS+WR_W{1'b0}};
  for(k=0;k<WR_W;k=k+1) if(b[k]) acc=acc+({{WR_W{1'b0}},a}<<k);
  mul_pw=acc; end
endfunction
// combinational accumulate chains (generate, no array reads in always @*)
wire [NUM_W-1:0] nums[0:TAPS];
wire [DEN_W-1:0] dens[0:TAPS];
assign nums[0]={NUM_W{1'b0}};
assign dens[0]={DEN_W{1'b0}};
generate for(gk=0;gk<TAPS;gk=gk+1) begin: accumulate
 wire [BITS+WR_W-1:0] pw=mul_pw(p2[gk],wq2[gk]);
 assign nums[gk+1]=nums[gk]+{{(NUM_W-BITS-WR_W){1'b0}},pw};
 assign dens[gk+1]=dens[gk]+{{(DEN_W-WR_W){1'b0}},wq2[gk]};
end endgenerate
reg [NUM_W-1:0] num3;
reg [DEN_W-1:0] den3;

// ------------------------------------------------------------ divider
// RNE(num/den); m_tuser = {div0, clip}; II=1, latency DN+1 cycles.
wire [OW-1:0] dq;
wire [1:0] du;
wire dval,dsready;
fp_div_pipe #(.AW(AW),.BW(BW),.FB(FB),.OUT_W(OW)) div(
 .clk(clk),.rst_n(rst_n),
 .s_tdata({{1'b0,den3},{1'b0,num3}}),
 .s_tvalid(v3),.s_tready(dsready),
 .m_tdata(dq),.m_tuser(du),.m_tvalid(dval),.m_tready(advance));

// centre pixel + sideband delay line aligned to the divider output.
// vd mirrors fp_div_pipe's vld chain exactly (data moves only on a valid
// upstream stage), so cdf/uf/lf are valid in the same cycle as dq/dval.
reg vd[0:DN-1];
reg [BITS-1:0] cd[0:DN-1];
reg ud[0:DN-1],ld[0:DN-1],bd[0:DN-1];
reg [BITS-1:0] cdf;
reg uf,lf,bdf;

// ------------------------------------------------------------ outputs
// bypass is a per-window attribute: it is sampled when the window is emitted
// (stage1) and travels with the pixel, so a commit at the next frame's SOF
// can never bleed into this frame's in-flight tail outputs.
wire div0=du[1],clip=du[0];
reg bypass;
reg pend,pend_bypass,pend_lswap;
assign m_tvalid=dval;
assign m_tdata=(bdf||div0)?cdf:(clip?{BITS{1'b1}}:dq[BITS-1:0]);
assign m_tuser=uf;
assign m_tlast=lf;

// -------------------------------------------------------- config / LUT
wire take=s_tvalid && s_tready;
wire commit=take && s_tuser && pend;
assign cfg_ready=rst_n && (!pend || commit);
assign lt_ready=rst_n && !commit;

always @(posedge clk) begin
 if(!rst_n) begin
  v1<=0;v2<=0;v3<=0;
  c1<=0;c2<=0;c3<=0;u1<=0;l1<=0;u2<=0;l2<=0;u3<=0;l3<=0;
  num3<=0;den3<=0;
  for(i=0;i<RLN;i=i+1) begin
   rlut[i]<=RLUT_INIT[i*WR_W +: WR_W];
   rlut_s[i]<=RLUT_INIT[i*WR_W +: WR_W];
  end
  for(i=0;i<TAPS;i=i+1) begin
   slut[i]<=SLUT_INIT[i*WS_W +: WS_W];
   slut_s[i]<=SLUT_INIT[i*WS_W +: WS_W];
  end
  for(i=0;i<DN;i=i+1) vd[i]<=0;
  cdf<=0;uf<=0;lf<=0;
  bypass<=0;pend<=0;pend_bypass<=0;pend_lswap<=0;
  cfg_done<=0;cfg_error<=0;lt_error<=0;
 end else begin
  cfg_done<=0;cfg_error<=0;lt_error<=0;
  if(commit) begin
   bypass<=pend_bypass;pend<=0;
   if(pend_lswap) begin
    for(i=0;i<RLN;i=i+1) rlut[i]<=rlut_s[i];
    for(i=0;i<TAPS;i=i+1) slut[i]<=slut_s[i];
   end
  end
  if(cfg_valid && cfg_ready) begin
   if(cfg_rsvd!=6'd0) cfg_error<=1;
   else begin
    pend_bypass<=cfg_bypass;pend_lswap<=cfg_lswap;pend<=1;cfg_done<=1;
   end
  end
  if(lt_valid && lt_ready) begin
   if(lt_addr>=RLN+TAPS) lt_error<=1;
   else if(lt_addr>=RLN) begin
    if(|lt_data[WR_W-1:WS_W]) lt_error<=1;
    else slut_s[lt_addr-RLN]<=lt_data[WS_W-1:0];
   end else rlut_s[lt_addr]<=lt_data;
  end
  if(advance) begin
   v1<=wv;v2<=v1;v3<=v2;
   if(wv) begin
    for(i=0;i<TAPS;i=i+1) begin p1[i]<=tap[i];wr1[i]<=rlut[widx[i]];end
    c1<=tap[4];u1<=wu;l1<=wl;b1<=bypass;
   end
   if(v1) begin
    for(i=0;i<TAPS;i=i+1) begin p2[i]<=p1[i];wq2[i]<=wqc[i];end
    c2<=c1;u2<=u1;l2<=l1;b2<=b1;
   end
   if(v2) begin
    num3<=nums[TAPS];den3<=dens[TAPS];c3<=c2;u3<=u2;l3<=l2;b3<=b2;
   end
   // divider-aligned delay line (vd mirrors fp_div_pipe vld)
   vd[0]<=v3;
   if(v3) begin cd[0]<=c3;ud[0]<=u3;ld[0]<=l3;bd[0]<=b3;end
   for(i=1;i<DN;i=i+1) begin
    vd[i]<=vd[i-1];
    if(vd[i-1]) begin
     cd[i]<=cd[i-1];ud[i]<=ud[i-1];ld[i]<=ld[i-1];bd[i]<=bd[i-1];
    end
   end
   if(vd[DN-1]) begin
    cdf<=cd[DN-1];uf<=ud[DN-1];lf<=ld[DN-1];bdf<=bd[DN-1];
   end
  end
 end
end

initial begin
 if(BITS!=8 && BITS!=10) $fatal(1,"unsupported BITS (8 or 10)");
 if(WIDTH<1 || HEIGHT<1) $fatal(1,"unsupported WIDTH/HEIGHT");
 if(PAD_MODE!=0 && PAD_MODE!=1) $fatal(1,"unsupported PAD_MODE");
 if(WS_W<1 || WS_W>WR_W) $fatal(1,"unsupported WS_W");
 if(WR_W<2 || WR_W>16) $fatal(1,"unsupported WR_W");
 if(WR_AW<1 || WR_AW>BITS) $fatal(1,"unsupported WR_AW");
end
endmodule
