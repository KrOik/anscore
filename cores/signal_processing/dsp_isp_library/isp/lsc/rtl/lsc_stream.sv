`timescale 1ns/1ps
// Lens shading correction (LSC) streaming core.
//
// Per-channel grid gains + bilinear interpolation, Bayer-phase-aware node
// selection, runtime frame/grid geometry, gain clamp, atomic frame-boundary
// commit of both scalar config and gain table. Streaming only, II=1, no
// frame storage. Full contract and fixed-point derivation in ../SPEC.md.
//
// Gain grid: GW x GH nodes per channel phase, nodes spaced 2^kx / 2^ky
// (phase-domain) pixels apart. Four parity banks x ping-pong buffer.
module lsc_stream #(
 parameter BITS=8,      // pixel width: 8 or 10
 parameter GW_MAX=17,   // maximum grid columns  (2..17)
 parameter GH_MAX=13    // maximum grid rows     (2..13)
)(
 input wire clk,rst_n,
 // pixel stream: tuser=SOF, tlast=EOL
 input wire [BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,
 output reg [BITS-1:0] m_tdata,
 output reg m_tvalid,m_tuser,m_tlast,
 input wire m_tready,
 // scalar config bundle; accepted bundle is pending and commits at next SOF
 input wire cfg_valid,output wire cfg_ready,
 input wire [12:0] cfg_width,input wire [12:0] cfg_height,
 input wire [4:0] cfg_gw,input wire [3:0] cfg_gh,
 input wire [3:0] cfg_kx,input wire [3:0] cfg_ky,
 input wire cfg_bayer,input wire [1:0] cfg_order,input wire cfg_gswap,
 input wire [15:0] cfg_gmax,
 output reg cfg_done,cfg_error,
 // gain table write port; always targets the inactive (shadow) buffer
 input wire g_valid,output wire g_ready,
 input wire [1:0] g_phase,input wire [3:0] g_row,input wire [4:0] g_col,
 input wire [15:0] g_data,
 output reg g_error,
 output reg o_error  // stream protocol violation pulse
);
localparam PCAPW=(GW_MAX+1)/2;           // max columns in one parity bank
localparam PCAPH=(GH_MAX+1)/2;           // max rows in one parity bank
localparam BANKCAP=PCAPW*PCAPH;          // entries per phase per bank
localparam DEPTH=8*BANKCAP;              // 2 buffers x 4 phases per bank

// active and pending (shadow) scalar configuration
reg [12:0] a_w,a_h; reg [4:0] a_gw; reg [3:0] a_gh,a_kx,a_ky;
reg a_bayer; reg [1:0] a_order; reg [15:0] a_gmax;
reg [12:0] p_w,p_h; reg [4:0] p_gw; reg [3:0] p_gh,p_kx,p_ky;
reg p_bayer; reg [1:0] p_order; reg [15:0] p_gmax;
reg p_gswap,pend_valid;
reg abuf;                // active gain buffer select
reg [1:0] written;       // per-buffer "table was written" flag
reg [12:0] x,y; reg in_frame;

// gain node RAM: bank {row_parity,col_parity}, ping-pong, sync read
reg [15:0] grid0[0:DEPTH-1];
reg [15:0] grid1[0:DEPTH-1];
reg [15:0] grid2[0:DEPTH-1];
reg [15:0] grid3[0:DEPTH-1];
reg [15:0] rd0,rd1,rd2,rd3;

// pipeline state
reg v1,v2,v3;
reg [BITS-1:0] s1_pix,s2_pix,s3_pix;
reg [8:0] s1_fx,s1_fy,s2_fy;
reg s1_ib,s1_jb;
reg [15:0] s1_gmax,s2_gmax,s3_gmax,s3_g;
reg s1_ng,s2_ng,s3_ng;
reg s1_u,s1_l,s2_u,s2_l,s3_u,s3_l;
reg [15:0] s2_a,s2_b;

// ---------------------------------------------------------------- handshake
wire configured=(a_gw!=0);
wire advance=!m_tvalid || m_tready;
assign s_tready=rst_n && advance && (configured || pend_valid);
wire fire=s_tvalid && s_tready;
wire commit_edge=fire && s_tuser && pend_valid;
assign cfg_ready=rst_n && (!pend_valid || commit_edge);
// writes always target the shadow buffer; the single commit edge is blocked
// so a write can never straddle the buffer swap.
assign g_ready=rst_n && !commit_edge;

// --------------------------------- effective config for the accept cycle
// A pending bundle takes effect exactly at the SOF pixel it commits on.
wire e_pick=s_tuser && pend_valid;
wire [12:0] e_w=e_pick?p_w:a_w;
wire [12:0] e_h=e_pick?p_h:a_h;
wire [4:0] e_gw=e_pick?p_gw:a_gw;
wire [3:0] e_gh=e_pick?p_gh:a_gh;
wire [3:0] e_kx=e_pick?p_kx:a_kx;
wire [3:0] e_ky=e_pick?p_ky:a_ky;
wire e_bayer=e_pick?p_bayer:a_bayer;
wire [1:0] e_order=e_pick?p_order:a_order;
wire [15:0] e_gmax=e_pick?p_gmax:a_gmax;
wire e_abuf=(e_pick && p_gswap)?~abuf:abuf;

// ------------------------------------------------- position / node indices
wire [12:0] cx=s_tuser?13'd0:x;
wire [12:0] cy=s_tuser?13'd0:y;
wire [12:0] pu=e_bayer?{1'b0,cx[12:1]}:cx;      // phase-domain u
wire [12:0] pv=e_bayer?{1'b0,cy[12:1]}:cy;      // phase-domain v
wire [12:0] iraw=pu>>e_kx;
wire [12:0] jraw=pv>>e_ky;
wire [4:0] gwm2=e_gw-5'd2;
wire [3:0] ghm2=e_gh-4'd2;
wire [4:0] gi=(iraw>{8'd0,gwm2})?gwm2:iraw[4:0];
wire [3:0] gj=(jraw>{9'd0,ghm2})?ghm2:jraw[3:0];
wire [19:0] ibase={15'd0,gi}<<e_kx;
wire [19:0] jbase={16'd0,gj}<<e_ky;
wire [19:0] remx={7'd0,pu}-ibase;               // 0 .. 2^kx
wire [19:0] remy={7'd0,pv}-jbase;               // 0 .. 2^ky
wire [19:0] fxw=(remx<<8)>>e_kx;                // Q8 weight, 0..256
wire [19:0] fyw=(remy<<8)>>e_ky;
wire [8:0] fx=fxw[8:0];
wire [8:0] fy=fyw[8:0];

// Bayer phase of the current pixel
function [1:0] phase_of;
 input [1:0] order; input yp,xp;
 begin
  case(order)
   2'd0: phase_of={yp,xp};        // RGGB
   2'd1: phase_of={~yp,~xp};      // BGGR
   2'd2: phase_of={yp,~xp};       // GRBG
   default: phase_of={~yp,xp};    // GBRG
  endcase
 end
endfunction
wire [1:0] ph=e_bayer?phase_of(e_order,cy[0],cx[0]):2'd0;

// -------------------------------------------- banked grid read addresses
// Bank (rpar,cpar) holds nodes (i,j) with j&1==rpar, i&1==cpar at fixed
// stride PCAPW: offset = (j>>1)*PCAPW + (i>>1).  All address scaling uses
// shift-add constant multiples so no DSP is spent outside the datapath.
// A few tail words per bank are unused when gw/gh are below the maximum.
function [13:0] cmul; // constant shift-add multiply (never a DSP)
 input [9:0] a; input [13:0] c;
 integer k; reg [13:0] acc;
 begin
  acc=14'd0;
  for(k=0;k<14;k=k+1) if(c[k]) acc=acc+({4'd0,a}<<k);
  cmul=acc;
 end
endfunction
wire gip=gi[0],gjp=gj[0];
wire [3:0] gjh=gj[3:1];
wire [3:0] gih=gi[4:1];
wire [3:0] rj0=gjh+((gjp==1'b0)?4'd0:{3'd0,gjp});
wire [3:0] rj1=gjh+((gjp==1'b1)?4'd0:{3'd0,gjp});
wire [3:0] ci0=gih+((gip==1'b0)?4'd0:{3'd0,gip});
wire [3:0] ci1=gih+((gip==1'b1)?4'd0:{3'd0,gip});
wire [6:0] off0=cmul({6'd0,rj0},PCAPW)+ci0;   // bank0: row par 0, col par 0
wire [6:0] off1=cmul({6'd0,rj0},PCAPW)+ci1;   // bank1: row par 0, col par 1
wire [6:0] off2=cmul({6'd0,rj1},PCAPW)+ci0;   // bank2: row par 1, col par 0
wire [6:0] off3=cmul({6'd0,rj1},PCAPW)+ci1;   // bank3: row par 1, col par 1
wire [2:0] rslot={e_abuf,ph};
wire [9:0] rbase=cmul({7'd0,rslot},BANKCAP);
wire [9:0] ra0=rbase+{3'd0,off0};
wire [9:0] ra1=rbase+{3'd0,off1};
wire [9:0] ra2=rbase+{3'd0,off2};
wire [9:0] ra3=rbase+{3'd0,off3};

// -------------------------------------------------- gain table write port
// Bounds check uses pending dims while a config is pending, else active
// dims; with neither (fresh reset, a_gw==0) every write is rejected with
// g_error.  The bank layout itself is dim-independent (fixed PCAPW stride).
wire [4:0] wgw=pend_valid?p_gw:a_gw;
wire [3:0] wgh=pend_valid?p_gh:a_gh;
wire [6:0] woff=cmul({6'd0,g_row[3:1]},PCAPW)+{3'd0,g_col[4:1]};
wire [9:0] waddr=cmul({7'd0,~abuf,g_phase},BANKCAP)+{3'd0,woff};

// -------------------------------------------------------------- pipeline
// stage1->2: mux bank data to the four interpolation nodes.
// NOTE: written as explicit ternaries (not a function call) so the continuous
// assignment sensitivities include rd0..rd3 under all simulators.
wire [1:0] b00={s1_jb,s1_ib};
wire [1:0] b10={s1_jb,~s1_ib};
wire [1:0] b01={~s1_jb,s1_ib};
wire [1:0] b11={~s1_jb,~s1_ib};
wire [15:0] n00=(b00==2'd0)?rd0:(b00==2'd1)?rd1:(b00==2'd2)?rd2:rd3;
wire [15:0] n10=(b10==2'd0)?rd0:(b10==2'd1)?rd1:(b10==2'd2)?rd2:rd3;
wire [15:0] n01=(b01==2'd0)?rd0:(b01==2'd1)?rd1:(b01==2'd2)?rd2:rd3;
wire [15:0] n11=(b11==2'd0)?rd0:(b11==2'd1)?rd1:(b11==2'd2)?rd2:rd3;
// horizontal interpolation, floor after >>8 (exact, documented in SPEC)
wire signed [17:0] df0=$signed({1'b0,n10})-$signed({1'b0,n00});
wire signed [17:0] df1=$signed({1'b0,n11})-$signed({1'b0,n01});
wire signed [26:0] pr0=df0*$signed({1'b0,s1_fx});
wire signed [26:0] pr1=df1*$signed({1'b0,s1_fx});
wire signed [18:0] aw_s=$signed({2'b0,n00})+(pr0>>>8);
wire signed [18:0] bw_s=$signed({2'b0,n01})+(pr1>>>8);
wire [15:0] aw=aw_s[15:0];
wire [15:0] bw=bw_s[15:0];
// stage2->3: vertical interpolation
wire signed [17:0] dfb=$signed({1'b0,s2_b})-$signed({1'b0,s2_a});
wire signed [26:0] prb=dfb*$signed({1'b0,s2_fy});
wire signed [18:0] gpre=$signed({2'b0,s2_a})+(prb>>>8);
wire [15:0] gw_interp=gpre[15:0];
// stage3->4: clamp, apply gain Q4.12, round-half-up, saturate.
// The pixel product is an explicit shift-add (LUT) so the core uses only the
// three interpolation multipliers as DSPs.
function [26:0] pix_mul;
 input [BITS-1:0] pix; input [15:0] g;
 integer k; reg [26:0] acc;
 begin
  acc=27'd0;
  for(k=0;k<16;k=k+1) if(g[k]) acc=acc+({{27-BITS{1'b0}},pix}<<k);
  pix_mul=acc;
 end
endfunction
wire [15:0] geff=s3_ng?16'h1000:((s3_g>s3_gmax)?s3_gmax:s3_g);
wire [26:0] oprod=pix_mul(s3_pix,geff);
wire [27:0] osum={1'b0,oprod}+28'd2048;
wire [BITS-1:0] outq=(|osum[27:12+BITS])?{BITS{1'b1}}:osum[11+BITS:12];

// ---------------------------------------------------------- config checks
wire [12:0] w_eff=cfg_bayer?((cfg_width+13'd1)>>1):cfg_width;
wire [12:0] h_eff=cfg_bayer?((cfg_height+13'd1)>>1):cfg_height;
wire [19:0] xcov=({15'd0,cfg_gw}-20'd1)<<cfg_kx;
wire [19:0] ycov=({16'd0,cfg_gh}-20'd1)<<cfg_ky;
wire cfg_bad=(cfg_width<13'd2)||(cfg_height<13'd2)
 ||(cfg_gw<5'd2)||(cfg_gw>GW_MAX)||(cfg_gh<4'd2)||(cfg_gh>GH_MAX)
 ||(xcov<({7'd0,w_eff}-20'd1))||(ycov<({7'd0,h_eff}-20'd1));

always @(posedge clk) begin
 if(!rst_n) begin
  a_w<=0;a_h<=0;a_gw<=0;a_gh<=0;a_kx<=0;a_ky<=0;
  a_bayer<=0;a_order<=0;a_gmax<=16'hffff;
  p_w<=0;p_h<=0;p_gw<=0;p_gh<=0;p_kx<=0;p_ky<=0;
  p_bayer<=0;p_order<=0;p_gmax<=0;p_gswap<=0;pend_valid<=0;
  abuf<=0;written<=0;x<=0;y<=0;in_frame<=0;
  rd0<=0;rd1<=0;rd2<=0;rd3<=0;
  v1<=0;v2<=0;v3<=0;m_tvalid<=0;m_tdata<=0;m_tuser<=0;m_tlast<=0;
  s1_pix<=0;s1_fx<=0;s1_fy<=0;s1_ib<=0;s1_jb<=0;s1_gmax<=0;
  s1_ng<=0;s1_u<=0;s1_l<=0;
  s2_a<=0;s2_b<=0;s2_pix<=0;s2_fy<=0;s2_gmax<=0;s2_ng<=0;s2_u<=0;s2_l<=0;
  s3_g<=0;s3_pix<=0;s3_gmax<=0;s3_ng<=0;s3_u<=0;s3_l<=0;
  cfg_done<=0;cfg_error<=0;g_error<=0;o_error<=0;
 end else begin
  cfg_done<=0;cfg_error<=0;g_error<=0;o_error<=0;
  // commit pending bundle at the SOF accept edge (first, so a config
  // accepted in the same cycle installs as the new pending)
  if(commit_edge) begin
   a_w<=p_w;a_h<=p_h;a_gw<=p_gw;a_gh<=p_gh;a_kx<=p_kx;a_ky<=p_ky;
   a_bayer<=p_bayer;a_order<=p_order;a_gmax<=p_gmax;
   pend_valid<=0;
   if(p_gswap) abuf<=~abuf;
  end
  if(cfg_valid && cfg_ready) begin
   if(cfg_bad) cfg_error<=1;
   else begin
    p_w<=cfg_width;p_h<=cfg_height;p_gw<=cfg_gw;p_gh<=cfg_gh;
    p_kx<=cfg_kx;p_ky<=cfg_ky;p_bayer<=cfg_bayer;p_order<=cfg_order;
    p_gmax<=cfg_gmax;p_gswap<=cfg_gswap;pend_valid<=1;cfg_done<=1;
   end
  end
  if(g_valid && g_ready) begin
   if(g_row>=wgh || g_col>=wgw) g_error<=1;
   else begin
    written[~abuf]<=1'b1;
    case({g_row[0],g_col[0]})
     2'd0: grid0[waddr]<=g_data;
     2'd1: grid1[waddr]<=g_data;
     2'd2: grid2[waddr]<=g_data;
     default: grid3[waddr]<=g_data;
    endcase
   end
  end
  if(fire) begin
   if(s_tuser && in_frame) o_error<=1;        // SOF mid-frame
   if(!s_tuser && !in_frame) o_error<=1;      // pixel outside frame
   if(s_tlast && cx!=e_w-13'd1) o_error<=1;   // early EOL
   if(!s_tlast && cx==e_w-13'd1) o_error<=1;  // missing EOL
   rd0<=grid0[ra0];rd1<=grid1[ra1];rd2<=grid2[ra2];rd3<=grid3[ra3];
   if(s_tlast || cx==e_w-13'd1) begin
    x<=13'd0;
    if(cy==e_h-13'd1) begin y<=13'd0;in_frame<=1'b0;end
    else begin y<=cy+13'd1;in_frame<=1'b1;end
   end else begin
    x<=cx+13'd1;y<=cy;in_frame<=1'b1;
   end
  end
  if(advance) begin
   v1<=fire;v2<=v1;v3<=v2;m_tvalid<=v3;
   if(fire) begin
    s1_pix<=s_tdata;s1_fx<=fx;s1_fy<=fy;s1_ib<=gip;s1_jb<=gjp;
    s1_gmax<=e_gmax;s1_ng<=~written[e_abuf];s1_u<=s_tuser;s1_l<=s_tlast;
   end
   if(v1) begin
    s2_a<=aw;s2_b<=bw;s2_pix<=s1_pix;s2_fy<=s1_fy;s2_gmax<=s1_gmax;
    s2_ng<=s1_ng;s2_u<=s1_u;s2_l<=s1_l;
   end
   if(v2) begin
    s3_g<=gw_interp;s3_pix<=s2_pix;s3_gmax<=s2_gmax;s3_ng<=s2_ng;
    s3_u<=s2_u;s3_l<=s2_l;
   end
   if(v3) begin
    m_tdata<=outq;m_tuser<=s3_u;m_tlast<=s3_l;
   end
  end
 end
end
initial begin
 if(BITS!=8 && BITS!=10) $fatal(1,"unsupported BITS (8 or 10)");
 if(GW_MAX<2 || GW_MAX>17) $fatal(1,"unsupported GW_MAX (2..17)");
 if(GH_MAX<2 || GH_MAX>13) $fatal(1,"unsupported GH_MAX (2..13)");
end
endmodule
