`timescale 1ns/1ps
// ============================================================================
// ISP-16 Canny edge chain (streaming, bounded resolution).
//
// Pipeline (per frame):
//   PASS 1 (streamed):
//     3x3 padded window -> optional Gaussian smooth ([1 2 1;2 4 2;1 2 1]/16,
//     round-half-up) or bypass -> 3x3 padded window -> Sobel Gx/Gy ->
//     L1 magnitude |Gx|+|Gy| + 8-sector gradient direction -> 3x3 padded
//     window of packed {sector,valid,mag} -> non-maximum suppression along
//     the quantized gradient direction -> double threshold ->
//     2-bit class {NONE,WEAK,EDGE} written into an internal frame buffer.
//   PASS 2..(PASSES+1) (frame-buffer sweeps):
//     Serpentine hysteresis linking: alternating forward/backward raster
//     passes promote WEAK pixels that are 8-adjacent to a pixel already
//     marked EDGE. A forward sweep propagates through the causal neighbours
//     NW,N,NE,W; a backward sweep through SE,S,SW,E. Anti-causal neighbours
//     only count when already EDGE at pass start (i.e. promoted in an
//     earlier pass), which is exactly the sequential flood semantics the
//     reference model implements.
//   READOUT (streamed): edge mask (0 or all-ones per pixel), raster order,
//     II=1.
//
// HYSTERESIS IS A DOCUMENTED BOUNDED APPROXIMATION (approach (b) of the
// ISP-16 brief): exact Canny hysteresis is a full-frame connected-component
// flood. Here PASSES fixed serpentine sweeps bound the work. A weak edge
// segment whose path back to its anchoring strong pixel requires more than
// PASSES-1 scan-direction reversals is truncated. See SPEC.md section 6 for
// the exact semantics and error model; models/model.py quantifies the
// difference against an exact BFS flood on every test frame.
//
// Frames are fully serialized: while hysteresis sweeps or readout run, the
// input stream is held off (s_tready=0). Configuration is accepted only
// while idle (atomic between frames).
// ============================================================================
module canny_stream #(
 parameter BITS=8,          // pixel width: 8 or 10
 parameter WIDTH=32,        // frame width  1..128
 parameter HEIGHT=24,       // frame height 1..128, WIDTH*HEIGHT <= 16384
 parameter PAD_MODE=0,      // 0=zero pad, 1=replicate pad (all three windows)
 parameter PASSES=4         // hysteresis serpentine sweeps, 1..16
)(
 input wire clk,rst_n,
 // pixel stream in: tuser=SOF, tlast=EOL
 input wire [BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,
 // edge mask stream out: tdata = all-ones on edge, else 0
 output reg [BITS-1:0] m_tdata,
 output reg m_tvalid,m_tuser,m_tlast,
 input wire m_tready,
 // scalar config, accepted only while idle
 input wire cfg_valid,output wire cfg_ready,
 input wire [BITS+2:0] cfg_t_lo,     // weak threshold  on L1 magnitude
 input wire [BITS+2:0] cfg_t_hi,     // strong threshold on L1 magnitude
 input wire cfg_smooth,              // 1=3x3 Gaussian, 0=bypass smoother
 input wire [1:0] cfg_reserved,      // must be 0
 output reg cfg_done,cfg_error,
 output reg marker_error,            // sticky stream-protocol violation
 output reg busy
);
localparam MB=BITS+3;              // magnitude width (|gx|+|gy| <= 8*maxpix)
localparam RW=MB+3;                // packed record {sector[1:0],avalid,mag}
localparam NP=WIDTH*HEIGHT;
localparam AW=(NP<2)?1:$clog2(NP);
localparam XW=(WIDTH<2)?1:$clog2(WIDTH);
localparam YW=(HEIGHT<2)?1:$clog2(HEIGHT);
localparam CW=$clog2(NP+2);   // NP>=1; +2 keeps CW>=1 even for NP=0 elab
localparam [XW-1:0] XMAX=WIDTH-1;
localparam [XW:0] WP=WIDTH;
localparam [XW:0] WP1=WIDTH+1;
localparam [YW-1:0] YMAX=HEIGHT-1;
localparam [CW-1:0] NPC=NP;
localparam [CW-1:0] NPM1=NP-1;
localparam [AW-1:0] TOPROW=(HEIGHT-1)*WIDTH;
localparam [1:0] CLS_NONE=2'd0,CLS_WEAK=2'd1,CLS_EDGE=2'd2;
localparam IDLE=0,CAPT=1,HINIT=2,HLDC=3,HLDN=4,HROW=5,HCOPY=6,OUT=7;

reg [2:0] state;
reg [MB-1:0] r_tlo,r_thi;
reg r_smooth;
reg [CW-1:0] ins;                 // pixels accepted this frame
reg [CW-1:0] wptr;               // classes written this frame
// hysteresis state
reg dir;                          // 0 = top-left..bottom-right raster
reg [3:0] pnum;
reg [YW-1:0] rj;                  // scan row index within a pass
reg [YW-1:0] cur_y;               // frame row currently processed
reg [XW-1:0] i;                   // inner scan index
reg [XW:0] ld;                    // row load counter
reg [AW-1:0] ld_base;
reg nrow_ok;
reg prev_prom;
reg [1:0] crow[0:WIDTH-1];        // stored class, current scan row
reg [1:0] nrow[0:WIDTH-1];        // stored class, next scan row
reg prow[0:WIDTH-1];              // edge flags, previously scanned row
reg curprom[0:WIDTH-1];           // edge flags, current row being scanned
// readout state
reg [CW-1:0] oi;                  // read issue index
reg [CW-1:0] pa,pb,pc;            // pipeline position tags
reg [1:0] d1;                     // read-data pipe, aligned with pc
reg v1,v2,v3;

// ------------------------------------------------------------- frame buffer
// 2-bit class per pixel. One write port + one sync read port -> SDP BSRAM.
(* ram_style="block" *) reg [1:0] fb[0:NP-1];
reg [AW-1:0] rd_addr;
reg [1:0] fb_q;
reg fb_wr; reg [AW-1:0] wr_addr; reg [1:0] wr_data;
// rd_gate: during OUT the read pipeline is stall-gated with `advance`;
// in the load states it free-runs (no backpressure exists there).
wire advance=!m_tvalid||m_tready;
wire rd_gate=(state==OUT)?advance:1'b1;
always @(posedge clk) begin
  if(fb_wr) fb[wr_addr]<=wr_data;
  if(rd_gate) fb_q<=fb[rd_addr];
end

// ----------------------------------------- stage 1: padded 3x3 pixel window
wire w1r,w1v,w1u,w1l,e1; wire [9*BITS-1:0] w1d;
wire w2r,w2v,w2u,w2l,e2; wire [9*BITS-1:0] w2d;
wire w3r,w3v,e3; wire [9*RW-1:0] w3d;
wire w3u,w3l;
wire allow=(state==IDLE||state==CAPT)&&(ins<NP)&&!(cfg_valid&&cfg_ready);
assign s_tready=allow&&w1r;
wire infire=s_tvalid&&s_tready;
stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),
  .K(3),.PAD_MODE(PAD_MODE)) w1(
  .clk(clk),.rst_n(rst_n),.s_tdata(s_tdata),.s_tvalid(s_tvalid&&allow),
  .s_tuser(s_tuser),.s_tlast(s_tlast),.s_tready(w1r),
  .m_tdata(w1d),.m_tvalid(w1v),.m_tuser(w1u),.m_tlast(w1l),
  .m_tready(w2r),.marker_error(e1));

// ------------------------------------------------- stage 2: Gaussian smooth
genvar gi;
wire [BITS-1:0] q[0:8];
generate for(gi=0;gi<9;gi=gi+1)begin:uq
  assign q[gi]=w1d[gi*BITS+:BITS];
end endgenerate
// [1 2 1;2 4 2;1 2 1]/16 with round-half-up; max = maxpix, no overflow.
wire [BITS+3:0] gsum={4'b0,q[0]}+{3'b0,q[1],1'b0}+{4'b0,q[2]}
                    +{3'b0,q[3],1'b0}+{2'b0,q[4],2'b00}+{3'b0,q[5],1'b0}
                    +{4'b0,q[6]}+{3'b0,q[7],1'b0}+{4'b0,q[8]};
wire [BITS-1:0] spix=r_smooth?((gsum+4'd8)>>4):q[4];

// -------------------------------------- stage 3: padded 3x3 smoothed window
stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),
  .K(3),.PAD_MODE(PAD_MODE)) w2(
  .clk(clk),.rst_n(rst_n),.s_tdata(spix),.s_tvalid(w1v),
  .s_tuser(w1u),.s_tlast(w1l),.s_tready(w2r),
  .m_tdata(w2d),.m_tvalid(w2v),.m_tuser(w2u),.m_tlast(w2l),
  .m_tready(w3r),.marker_error(e2));

// ------------------------- stage 4: Sobel gradients, L1 magnitude, 8-sector
wire [BITS-1:0] p[0:8];
generate for(gi=0;gi<9;gi=gi+1)begin:up
  assign p[gi]=w2d[gi*BITS+:BITS];
end endgenerate
wire signed [MB:0] dx0=$signed({1'b0,p[2]})-$signed({1'b0,p[0]});
wire signed [MB:0] dx1=$signed({1'b0,p[5]})-$signed({1'b0,p[3]});
wire signed [MB:0] dx2=$signed({1'b0,p[8]})-$signed({1'b0,p[6]});
wire signed [MB:0] dy0=$signed({1'b0,p[6]})-$signed({1'b0,p[0]});
wire signed [MB:0] dy1=$signed({1'b0,p[7]})-$signed({1'b0,p[1]});
wire signed [MB:0] dy2=$signed({1'b0,p[8]})-$signed({1'b0,p[2]});
wire signed [MB:0] gx=dx0+(dx1<<<1)+dx2;
wire signed [MB:0] gy=dy0+(dy1<<<1)+dy2;
wire [MB-1:0] ax=(gx<0)?(-gx[MB-1:0]):gx[MB-1:0];
wire [MB-1:0] ay=(gy<0)?(-gy[MB-1:0]):gy[MB-1:0];
wire [MB-1:0] mag=ax+ay;                          // L1, <= 8*maxpix
// folded-sector test: 22.5 degree bound via 128*f vs 53*g (tan bound
// 53/128 = 0.41406 ~ tan(22.5deg)=0.41421), identical to isp/gradient.
wire [MB+7:0] axw={8'b0,ax},ayw={8'b0,ay};
wire [MB+7:0] ax53=(axw<<5)+(axw<<4)+(axw<<2)+axw;
wire [MB+7:0] ay53=(ayw<<5)+(ayw<<4)+(ayw<<2)+ayw;
wire q_h=(ayw<<7)<ax53;          // near-horizontal gradient
wire q_v=(axw<<7)<ay53;          // near-vertical gradient
// sector: 0 = W/E neighbours, 1 = N/S, 2 = NE/SW (signs equal),
//         3 = NW/SE (signs differ)
wire [1:0] sec=q_h?2'd0:(q_v?2'd1:(((gx<0)==(gy<0))?2'd2:2'd3));
wire avalid=(ax!=0)||(ay!=0);
wire [RW-1:0] rec={sec,avalid,mag};

// --------------------------------- stage 5: padded 3x3 window of {sec,av,m}
stream_window_padded #(.DATA_WIDTH(RW),.WIDTH(WIDTH),.HEIGHT(HEIGHT),
  .K(3),.PAD_MODE(PAD_MODE)) w3(
  .clk(clk),.rst_n(rst_n),.s_tdata(rec),.s_tvalid(w2v),
  .s_tuser(w2u),.s_tlast(w2l),.s_tready(w3r),
  .m_tdata(w3d),.m_tvalid(w3v),.m_tuser(w3u),.m_tlast(w3l),
  .m_tready(state==CAPT),.marker_error(e3));

// ------------------------------ stage 6: NMS + double threshold -> class
wire [MB-1:0] wm[0:8]; wire wav8[0:8];
generate for(gi=0;gi<9;gi=gi+1)begin:ur
  assign wm[gi]=w3d[gi*RW+:MB];
  assign wav8[gi]=w3d[gi*RW+MB];
end endgenerate
wire [1:0] csec=w3d[4*RW+MB+1+:2];
wire cav=wav8[4];
wire [MB-1:0] cmag=wm[4];
reg [MB-1:0] na,nb;
always @* begin
  case(csec)
    2'd0: begin na=wm[3];nb=wm[5]; end   // W,E
    2'd1: begin na=wm[1];nb=wm[7]; end   // N,S
    2'd2: begin na=wm[2];nb=wm[6]; end   // NE,SW
    default: begin na=wm[0];nb=wm[8];end // NW,SE
  endcase
end
wire keep=(cmag>=na)&&(cmag>=nb);
wire [1:0] cls=(!cav||!keep)?CLS_NONE
              :(cmag>=r_thi)?CLS_EDGE
              :(cmag>=r_tlo)?CLS_WEAK:CLS_NONE;

// ----------------------------------------------------- hysteresis datapath
wire [XW-1:0] hx=dir?(XMAX-i):i;         // frame column of the scan index
wire [YW-1:0] last_y=dir?{YW{1'b0}}:YMAX;
wire has_next=(cur_y!=last_y);
wire [YW-1:0] next_y=dir?(cur_y-1'b1):(cur_y+1'b1);
wire [YW-1:0] nn_y=dir?(next_y-1'b1):(next_y+1'b1);
wire [AW-1:0] haddr=cur_y*WIDTH+hx;
// 8-neighbour edge evidence for the promote rule (see header comment):
//   causal row   = prow[hx-1..hx+1]   (edge flags of the previous scan row)
//   causal side  = prev_prom          (same row, already visited this pass)
//   anti-causal  = crow / nrow stored class == EDGE only
wire e_pc =prow[hx];
wire e_pl =(hx!={XW{1'b0}})&&prow[hx-1'b1];
wire e_pr =(hx!=XMAX)&&prow[hx+1'b1];
wire e_cca=prev_prom;
wire e_can=dir?((hx!={XW{1'b0}})&&(crow[hx-1'b1]==CLS_EDGE))
              :((hx!=XMAX)&&(crow[hx+1'b1]==CLS_EDGE));
wire e_nl =nrow_ok&&(hx!={XW{1'b0}})&&(nrow[hx-1'b1]==CLS_EDGE);
wire e_nc =nrow_ok&&(nrow[hx]==CLS_EDGE);
wire e_nr =nrow_ok&&(hx!=XMAX)&&(nrow[hx+1'b1]==CLS_EDGE);
wire any_edge=e_pc|e_pl|e_pr|e_cca|e_can|e_nl|e_nc|e_nr;
wire [1:0] newc=(crow[hx]==CLS_WEAK&&any_edge)?CLS_EDGE:crow[hx];

// frame-buffer write mux (CAPT fills, HROW rewrites in place)
always @* begin
  fb_wr=1'b0;wr_addr=wptr[AW-1:0];wr_data=cls;
  if(state==HROW)begin fb_wr=1'b1;wr_addr=haddr;wr_data=newc;end
  else if(state==CAPT&&w3v)begin fb_wr=1'b1;wr_addr=wptr[AW-1:0];wr_data=cls;end
end

integer j;

always @(posedge clk) begin
 if(!rst_n)begin
   state<=IDLE;busy<=0;ins<=0;wptr<=0;
   r_tlo<={{(MB-1){1'b0}},1'b1};r_thi<={{(MB-2){1'b0}},2'b10};r_smooth<=1'b1;
   dir<=0;pnum<=0;rj<=0;cur_y<=0;i<=0;ld<=0;ld_base<=0;nrow_ok<=0;prev_prom<=0;
   oi<=0;pa<=0;pb<=0;v1<=0;v2<=0;rd_addr<=0;
   m_tdata<=0;m_tvalid<=0;m_tuser<=0;m_tlast<=0;
   cfg_done<=0;cfg_error<=0;marker_error<=0;
 end else begin
   cfg_done<=0;cfg_error<=0;
   if(m_tready)m_tvalid<=0;       // OUT overrides when it emits
   if(e1||e2||e3)marker_error<=1;
   if(cfg_valid&&cfg_ready)begin
     if(cfg_reserved!=2'b00||cfg_t_lo>cfg_t_hi)cfg_error<=1;
     else begin
       r_tlo<=cfg_t_lo;r_thi<=cfg_t_hi;r_smooth<=cfg_smooth;cfg_done<=1;
     end
   end
   if(infire)begin ins<=ins+1'b1;busy<=1;state<=CAPT;end
   if(state==CAPT&&w3v)begin
     if(wptr==NPM1)begin
       state<=HINIT;pnum<=0;dir<=0;
     end
     wptr<=wptr+1'b1;
   end
   case(state)
   HINIT:begin
     for(j=0;j<WIDTH;j=j+1)prow[j]<=1'b0;
     prev_prom<=0;i<=0;rj<=0;
     cur_y<=dir?YMAX:{YW{1'b0}};
     ld_base<=dir?TOPROW:{AW{1'b0}};
     ld<=0;state<=HLDC;
   end
   HLDC:begin                                  // load crow <- fb[cur_y][*]
     // rd_addr is registered: fb_q at edge E is fb[addr issued at E-1].
     // Issue rd_addr=base+ld for ld<W, capture crow[k] when ld==k+2.
     if(ld<WP) rd_addr<=ld_base+ld;
     if(ld>=2) crow[ld-2]<=fb_q;
     if(ld==WP1)begin
       ld<=0;
       if(has_next)begin
         ld_base<=next_y*WIDTH;nrow_ok<=1;state<=HLDN;
       end else begin
         nrow_ok<=0;i<=0;prev_prom<=0;state<=HROW;
       end
     end else ld<=ld+1'b1;
   end
   HLDN:begin                                  // load nrow <- fb[next_y][*]
     if(ld<WP) rd_addr<=ld_base+ld;
     if(ld>=2) nrow[ld-2]<=fb_q;
     if(ld==WP1)begin
       ld<=0;i<=0;prev_prom<=0;state<=HROW;
     end else ld<=ld+1'b1;
   end
   HROW:begin                                  // one pixel per cycle
     curprom[hx]<=(newc==CLS_EDGE);
     prev_prom<=(newc==CLS_EDGE);
     if(i==XMAX)begin
       i<={XW{1'b0}};
       if(rj==YMAX)begin                       // pass finished
         if(pnum==PASSES[3:0]-4'd1)begin
           state<=OUT;oi<=0;v1<=0;v2<=0;v3<=0;pa<=0;pb<=0;pc<=0;
         end else begin
           pnum<=pnum+1'b1;dir<=~dir;state<=HINIT;
         end
       end else begin
         rj<=rj+1'b1;state<=HCOPY;
       end
     end else i<=i+1'b1;
   end
   HCOPY:begin                                 // crow<-nrow, prow<-curprom
     for(j=0;j<WIDTH;j=j+1)begin
       prow[j]<=curprom[j];
       crow[j]<=nrow[j];
     end
     prev_prom<=0;cur_y<=next_y;
     // row after next_y exists iff next_y != last_y
     if(next_y!=last_y)begin
       ld_base<=nn_y*WIDTH;
       nrow_ok<=1;ld<=0;state<=HLDN;
     end else begin
       nrow_ok<=0;i<=0;state<=HROW;
     end
   end
   OUT:begin                                   // raster readout, II=1
     // issue(t) -> rd_addr(t) -> fb_q(t+1) -> d1(t+2) -> emit(t+3).
     // All pipe regs advance only when `advance` is true; fb_q itself
     // re-latches every cycle but rd_addr is frozen during stalls, so the
     // d1 snapshot is what makes the emitted data stall-safe.
     if(advance)begin
       if(oi<NPC)begin
         rd_addr<=oi[AW-1:0];pa<=oi;oi<=oi+1'b1;v1<=1'b1;
       end else v1<=1'b0;
       d1<=fb_q;
       pb<=pa;v2<=v1;
       pc<=pb;v3<=v2;
       m_tvalid<=v3;
       if(v3)begin
         m_tdata<=(d1==CLS_EDGE)?{BITS{1'b1}}:{BITS{1'b0}};
         m_tuser<=(pc=={CW{1'b0}});
         m_tlast<=(pc%WIDTH==WIDTH-1);
         if(pc==NPM1)begin
           state<=IDLE;busy<=0;ins<=0;wptr<=0;
         end
       end
     end
   end
   default:;
   endcase
 end
end
assign cfg_ready=rst_n&&!busy;
initial begin
  if(BITS!=8&&BITS!=10) $fatal(1,"unsupported BITS (8 or 10)");
  if(WIDTH<1||WIDTH>128) $fatal(1,"unsupported WIDTH (1..128)");
  if(HEIGHT<1||HEIGHT>128) $fatal(1,"unsupported HEIGHT (1..128)");
  if(NP>16384) $fatal(1,"WIDTH*HEIGHT exceeds 16384 frame buffer");
  if(PAD_MODE!=0&&PAD_MODE!=1) $fatal(1,"unsupported PAD_MODE (0 or 1)");
  if(PASSES<1||PASSES>16) $fatal(1,"unsupported PASSES (1..16)");
end
endmodule
