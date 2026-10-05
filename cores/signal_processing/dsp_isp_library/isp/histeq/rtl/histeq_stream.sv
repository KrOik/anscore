// ============================================================================
// ISP-11 histogram equalization / CLAHE streaming engine.
//
// Modes (runtime cfg_mode):
//   0 HE_PREV : frame N output uses the LUT built from frame N-1's global
//               histogram (frame 0 uses the identity ramp built in S_INIT).
//               Fully streamable II=1; s_tready drops for the ~1.1k-cycle
//               inter-frame CDF/LUT build.  No frame buffer use.
//   1 HE_CUR  : frame buffered, global histogram of THIS frame -> build ->
//               II=1 replay through the new LUT.
//   2 CLAHE   : frame buffered, per-tile 64-bin clipped/redistributed
//               histograms -> per-tile LUTs -> ~7 cyc/px bilinear replay.
//
// Statistics policy and all integer rules are documented in SPEC.md; this
// RTL implements the bit-exact contract in models/reference.py.
//
// Reuse note: the bin-RAM read/modify/write + 1-deep same-bin forwarding
// follows the proven schedule of sigproc hist256.v / wave2 img_histogram.v
// (take-edge read issue, next-edge writeback commit; only adjacent takes of
// the same bin can collide).  The restoring divider and shift-add multiply
// style follow wave2 hist_clahe.v -- no '/','%' or '*' operators anywhere.
// ============================================================================
module histeq_stream #(
    parameter BITS      = 8,
    parameter MAX_W     = 32,
    parameter MAX_H     = 24,
    parameter CLAHE_EN  = 1,
    // Derived widths; override only to mirror the formulas.
    parameter MPX  = (BITS<1) ? 1 : ((1<<BITS)-1),
    parameter FP   = (MAX_W<1 || MAX_H<1 || MAX_W*MAX_H>65536) ? 1 : MAX_W*MAX_H,
    parameter XW   = (MAX_W<2) ? 1 : $clog2(MAX_W),
    parameter YW   = (MAX_H<2) ? 1 : $clog2(MAX_H),
    parameter CWX  = (MAX_W<1) ? 1 : $clog2(MAX_W+1),
    parameter CWY  = (MAX_H<1) ? 1 : $clog2(MAX_H+1),
    parameter FW   = (FP<2) ? 1 : $clog2(FP+1),
    parameter AW   = (FP<2) ? 1 : $clog2(FP)
)(
    input  wire clk, rst_n,
    // Pixel stream: tuser = SOF (0,0), tlast = EOL.
    input  wire [BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    // Output stream: equalized image, same geometry/markers.
    output reg  [BITS-1:0] m_tdata,
    output reg  m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    // Atomic configuration (all fields committed or rejected together).
    input  wire cfg_valid, output wire cfg_ready,
    input  wire [CWX-1:0] cfg_img_w,
    input  wire [CWY-1:0] cfg_img_h,
    input  wire [1:0]  cfg_mode,        // 0 HE_PREV, 1 HE_CUR, 2 CLAHE
    input  wire [2:0]  cfg_txl, cfg_tyl,// log2 tile grid, CLAHE only
    input  wire [15:0] cfg_clip,        // per-bin clip limit, CLAHE only
    output reg  cfg_done, cfg_error, marker_error,
    output wire busy
);
    // ------------------------------------------------------------------
    // state encoding
    // ------------------------------------------------------------------
    localparam S_INIT  = 4'd0;   // clear hists + identity GLUT after reset
    localparam S_ING   = 4'd1;   // idle + frame ingest
    localparam S_DRAIN = 4'd2;   // let the last histogram writeback commit
    localparam S_HE1   = 4'd3;   // global cdf in-place pass
    localparam S_HE2   = 4'd4;   // cdf -> GLUT map + bin clear
    localparam S_CT1   = 4'd5;   // CLAHE per-tile clip pass
    localparam S_CT2   = 4'd6;   // redistribute + cdf' -> tile LUT + clear
    localparam S_WT    = 4'd7;   // fx6/fy6 weight tables (two passes)
    localparam S_RHE   = 4'd8;   // mode-1 pipelined replay
    localparam S_RCL   = 4'd9;   // mode-2 per-pixel replay

    // ------------------------------------------------------------------
    // configuration and per-frame latched working copies
    // ------------------------------------------------------------------
    reg  [CWX-1:0] img_w;
    reg  [CWY-1:0] img_h;
    reg  [1:0]  mode;
    reg  [2:0]  txl, tyl;
    reg  [15:0] clip;
    reg  [1:0]  w_mode;
    reg  [CWX-1:0] w_img_w;
    reg  [CWY-1:0] w_img_h;
    reg  [2:0]  w_txl, w_tyl;
    reg  [15:0] w_clip;
    reg  [FW-1:0]  w_npix;
    reg  [12:0] w_tw, w_th;       // tile width/height (CLAHE)
    reg  [17:0] w_T;              // tile area tw*th

    // ------------------------------------------------------------------
    // stream / pipeline control
    // ------------------------------------------------------------------
    reg  [3:0]  state;
    reg  [XW-1:0] x;
    reg  [YW-1:0] y;
    reg  [FW-1:0] fi;            // frame-buffer write index
    reg  [FW-1:0] npix;         // accepted pixel count this frame
    reg  fopen;                 // input frame in progress
    reg  pend;                  // stage-A capture waiting for commit

    // ingest tile counters (mode 2)
    reg  [3:0]  itx, ity;
    reg  [12:0] idx, idy;

    // stage-A captured pixel context
    reg  [9:0]     cap_addr;    // {tile,bin6} or {2'b0,gbin}
    reg            cap_mode2;   // CLAHE histogram path
    reg            cap_emit;    // mode-0 LUT output path
    reg            cap_u, cap_l;

    // histogram RMW 1-deep forwarding (adjacent same-bin takes only)
    reg         fwd_v;
    reg  [9:0]  fwd_addr;
    reg  [17:0] fwd_cnt;

    // build-phase registers
    reg  [9:0]  bi;             // bin index 0..255 / 0..63
    reg         bph;            // 0 = issue read, 1 = process
    reg  [3:0]  bt;             // tile index
    reg  [17:0] cdf, cdfmin, excess, den;
    reg         mins, constf;
    reg  [10:0] base;
    reg  [5:0]  rem;
    reg  [12:0] wi;
    reg         wph;            // weight-table pass: 0 = fx, 1 = fy

    // replay registers
    reg  [FW-1:0] ra;
    reg  [XW-1:0] rx;
    reg  [YW-1:0] ry;
    reg           v0, v1;                       // S_RHE pipe valids
    reg  [XW-1:0] px0x, px1x;
    reg  [YW-1:0] px0y, px1y;
    reg  [3:0]  rph;                            // S_RCL phase 0..6
    reg  [3:0]  r_tx, r_ty;                     // tile indices
    reg  [12:0] r_dx, r_dy;                     // offset inside tile
    reg  [3:0]  r_ta, r_tb, r_ua, r_ub;
    reg  [6:0]  r_fx, r_fy;
    reg  [5:0]  rcb;
    reg  [BITS-1:0] m00, m01, m10, m11;
    reg         r_done;

    // init counter
    reg  [9:0] ii;

    // ------------------------------------------------------------------
    // storage (synchronous read; BRAM-friendly)
    // ------------------------------------------------------------------
    (* ram_style="block" *) reg [17:0]     hmem [0:255];    // global hist/cdf
    (* ram_style="block" *) reg [17:0]     cmem [0:1023];   // tile hists {t,b}
    (* ram_style="block" *) reg [BITS-1:0] gmem [0:255];    // GLUT
    (* ram_style="block" *) reg [BITS-1:0] lmem [0:1023];   // tile LUTs {t,b}
    (* ram_style="block" *) reg [BITS-1:0] fmem [0:FP-1];   // frame buffer
    reg  [6:0]  fxt [0:MAX_W-1];            // fx6 table (built per frame)
    reg  [6:0]  fyt [0:MAX_H-1];            // fy6 table
    reg  [17:0]     hq, cq;
    reg  [BITS-1:0] gq, lq, fq;

    // ------------------------------------------------------------------
    // arithmetic helpers (no '/', '%', '*')
    // ------------------------------------------------------------------
    function [27:0] divu;               // 28b/18b restoring divider
        input [27:0] n;
        input [17:0] d;
        integer k;
        reg [18:0] rem;
        reg [27:0] qq;
        begin
            rem = 19'd0;
            qq  = 28'd0;
            for (k = 27; k >= 0; k = k - 1) begin
                rem = {rem[17:0], n[k]};
                if (d != 18'd0 && rem >= {1'b0, d}) begin
                    rem   = rem - {1'b0, d};
                    qq[k] = 1'b1;
                end
            end
            divu = qq;
        end
    endfunction

    function [23:0] um18x7;             // unsigned 18 x 7 shift-add
        input [17:0] a;
        input [6:0]  b;
        integer i;
        reg [23:0] s;
        begin
            s = 24'd0;
            for (i = 0; i < 7; i = i + 1)
                if (b[i]) s = s + ({6'd0, a} << i);
            um18x7 = s;
        end
    endfunction

    function [25:0] um13x13;            // unsigned 13 x 13 shift-add
        input [12:0] a;
        input [12:0] b;
        integer i;
        reg [25:0] s;
        begin
            s = 26'd0;
            for (i = 0; i < 13; i = i + 1)
                if (b[i]) s = s + ({13'd0, a} << i);
            um13x13 = s;
        end
    endfunction

    // ------------------------------------------------------------------
    // geometry / handshake
    // ------------------------------------------------------------------
    wire [CWX-1:0] w_last   = img_w - 1'b1;
    wire [CWY-1:0] h_last   = img_h - 1'b1;
    wire [XW-1:0]  w_last_r = w_img_w[XW-1:0] - {{(XW-1){1'b0}}, 1'b1};
    wire [YW-1:0]  h_last_r = w_img_h[YW-1:0] - {{(YW-1){1'b0}}, 1'b1};

    wire advance = !m_tvalid || m_tready;
    assign busy = rst_n && (fopen | pend | (state != S_ING) | m_tvalid);
    assign cfg_ready = rst_n && !fopen && !pend;
    assign s_tready  = rst_n && (state == S_ING) && advance &&
                      !(cfg_valid && cfg_ready);
    wire take = s_tvalid && s_tready;

    // ingest bin indices and tile position
    wire [7:0]  gb_ing   = s_tdata[BITS-1 -: 8];
    wire [5:0]  cb_ing   = s_tdata[BITS-1 -: 6];
    wire [12:0] tw_ing   = {1'b0, img_w} >> txl;
    wire [12:0] th_ing   = {1'b0, img_h} >> tyl;
    wire [3:0]  tile_ing = (ity << txl) | itx;
    wire [9:0]  caddr_ing = {tile_ing, cb_ing};

    // histogram commit (stage B): distance-1 same-address hazard only
    wire [17:0] sel_q    = cap_mode2 ? cq : hq;
    wire        fwd_hit  = fwd_v && (fwd_addr == cap_addr);
    wire [17:0] nval     = (fwd_hit ? fwd_cnt : sel_q) + 18'd1;
    wire        h_commit = advance && pend && !cap_mode2;
    wire        c_commit = advance && pend &&  cap_mode2;

    // build wires
    wire        he1_wr = (state == S_HE1) && bph;
    wire        he2_wr = (state == S_HE2) && bph;
    wire        ct1_wr = (state == S_CT1) && bph;
    wire        ct2_wr = (state == S_CT2) && bph;
    wire [17:0] ncdf     = cdf + hq;
    wire [17:0] cdfmin_n = (!mins && hq != 18'd0) ? ncdf : cdfmin;
    wire [17:0] npix_e   = {{(18-FW){1'b0}}, w_npix};
    wire [17:0] hc       = (cq > {2'b00, w_clip}) ? {2'b00, w_clip} : cq;
    wire [17:0] exn      = excess + (cq - hc);
    wire [17:0] hp       = cq + {7'd0, base} + ((bi[5:0] < rem) ? 18'd1 : 18'd0);
    wire [17:0] ncdf2    = cdf + hp;
    wire [4:0]  nt       = 5'd1 << (w_txl + w_tyl);      // total tiles
    wire [4:0]  ntx_m1   = (5'd1 << w_txl) - 5'd1;
    wire [4:0]  nty_m1   = (5'd1 << w_tyl) - 5'd1;

    // shared index / divide values
    wire [7:0]  id_idx  = (state == S_INIT) ? ii[7:0] : bi[7:0];
    wire [27:0] id_num  = ({20'd0, id_idx} << (BITS+1)) - ({20'd0, id_idx} << 1)
                          + 28'd255;
    wire [16:0] he_d    = (hq > cdfmin) ? (hq - cdfmin) : 17'd0;
    wire [27:0] he_num  = ({11'd0, he_d} << (BITS+1)) - ({11'd0, he_d} << 1)
                          + {11'd0, den[16:0]};
    wire [27:0] he_quo  = constf ? divu(id_num, 18'd510)
                                 : divu(he_num, {den[16:0], 1'b0});
    wire [BITS-1:0] map_he = |he_quo[27:BITS] ? {BITS{1'b1}} : he_quo[BITS-1:0];
    wire [27:0] id_quo  = divu(id_num, 18'd510);
    wire [BITS-1:0] id_map = |id_quo[27:BITS] ? {BITS{1'b1}} : id_quo[BITS-1:0];
    wire [27:0] cl_num  = ({10'd0, ncdf2} << (BITS+1)) - ({10'd0, ncdf2} << 1)
                          + {10'd0, w_T};
    wire [27:0] cl_quo  = divu(cl_num, {w_T[16:0], 1'b0});
    wire [BITS-1:0] map_cl = |cl_quo[27:BITS] ? {BITS{1'b1}} : cl_quo[BITS-1:0];
    // weight-table pass (wph 0 -> fxt over w_tw, 1 -> fyt over w_th)
    wire        wt_x    = (w_txl != 3'd0);
    wire        wt_y    = (w_tyl != 3'd0);
    wire        wt_idle = !wt_x && !wt_y;
    wire [12:0] wt_lim  = wph ? w_th : w_tw;
    wire [27:0] wt_num  = ({15'd0, wi} << 7) + {15'd0, wt_lim};
    wire [27:0] wt_quo  = divu(wt_num, {5'd0, wt_lim, 1'b0});

    // CLAHE interpolation select (evaluated during rph==1; counters are the
    // current pixel's tile position and hold for the whole pixel).  Declared
    // before the RAM port muxes because the rph==1 lmem read below uses the
    // combinational selects directly (the r_* registers latch them at the
    // same edge and would otherwise be stale by one pixel).
    wire [12:0] cxf = w_tw >> 1;
    wire [12:0] cyf = w_th >> 1;
    wire        x_left = (r_dx < cxf);
    wire        y_left = (r_dy < cyf);
    wire [3:0]  sel_ta = x_left ? ((r_tx == 4'd0) ? 4'd0 : r_tx - 4'd1) : r_tx;
    wire [3:0]  sel_tb = x_left ? r_tx :
                         (r_tx == ntx_m1[3:0] ? r_tx : r_tx + 4'd1);
    wire [3:0]  sel_ua = y_left ? ((r_ty == 4'd0) ? 4'd0 : r_ty - 4'd1) : r_ty;
    wire [3:0]  sel_ub = y_left ? r_ty :
                         (r_ty == nty_m1[3:0] ? r_ty : r_ty + 4'd1);
    wire [12:0] sel_nx = x_left ? (r_dx + w_tw - cxf) : (r_dx - cxf);
    wire [12:0] sel_ny = y_left ? (r_dy + w_th - cyf) : (r_dy - cyf);
    wire [6:0]  sel_fx = (sel_ta == sel_tb) ? 7'd0 : fxt[sel_nx[XW-1:0]];
    wire [6:0]  sel_fy = (sel_ua == sel_ub) ? 7'd0 : fyt[sel_ny[YW-1:0]];

    // RAM port muxes -------------------------------------------------------
    wire h_re = (take && mode != 2'd2) ||
                ((state == S_HE1 || state == S_HE2) && !bph);
    wire [7:0] h_ra = (state == S_ING) ? gb_ing : bi[7:0];
    wire h_we = (state == S_INIT && ii[9:8] == 2'b00) || h_commit || he1_wr || he2_wr;
    wire [7:0] h_wa = (state == S_INIT) ? ii[7:0] :
                      h_commit ? cap_addr[7:0] : bi[7:0];
    wire [17:0] h_wd = (state == S_INIT) ? 18'd0 :
                       h_commit ? nval :
                       (state == S_HE1) ? ncdf : 18'd0;

    wire c_re = (take && mode == 2'd2) ||
                ((state == S_CT1 || state == S_CT2) && !bph);
    wire [9:0] c_ra = (state == S_ING) ? caddr_ing : {bt, bi[5:0]};
    wire c_we = (state == S_INIT) || c_commit || ct1_wr || ct2_wr;
    wire [9:0] c_wa = (state == S_INIT) ? ii :
                      c_commit ? cap_addr : {bt, bi[5:0]};
    wire [17:0] c_wd = (state == S_INIT) ? 18'd0 :
                       c_commit ? nval :
                       (state == S_CT1) ? hc : 18'd0;

    wire g_re = (take && mode == 2'd0) || (state == S_RHE && v0 && advance);
    wire [7:0] g_ra = (state == S_ING) ? gb_ing : fq[BITS-1 -: 8];
    wire g_we = (state == S_INIT && ii[9:8] == 2'b00) || he2_wr;
    wire [7:0] g_wa = (state == S_INIT) ? ii[7:0] : bi[7:0];
    wire [BITS-1:0] g_wd = (state == S_INIT) ? id_map : map_he;

    // rph==1 issues the (ta,ua) tile-LUT read in the SAME cycle that
    // r_ta/r_ua/rcb are latched from the current pixel, so that first read
    // must use the combinational sel_* selects and fq's bin field; the
    // registered r_* values are still stale (previous pixel) during rph==1.
    wire l_re = (state == S_RCL) && !r_done && (rph >= 4'd1 && rph <= 4'd4);
    wire [3:0] l_row = (rph == 4'd1) ? sel_ua :
                       (rph == 4'd3 || rph == 4'd4) ? r_ub : r_ua;
    wire [3:0] l_col = (rph == 4'd1) ? sel_ta :
                       (rph == 4'd2 || rph == 4'd4) ? r_tb : r_ta;
    wire [5:0] l_bin = (rph == 4'd1) ? fq[BITS-1 -: 6] : rcb;
    wire [9:0] l_ra = {((l_row << w_txl) | l_col), l_bin};
    wire l_we = ct2_wr;
    wire [9:0] l_wa = {bt, bi[5:0]};
    wire [BITS-1:0] l_wd = map_cl;

    wire f_re = (state == S_RHE && advance && ra < w_npix) ||
                (state == S_RCL && !r_done && rph == 4'd0);
    wire [AW-1:0] f_ra = ra[AW-1:0];
    wire f_we = take && mode != 2'd0;
    wire [AW-1:0] f_wa = fi[AW-1:0];
    wire [BITS-1:0] f_wd = s_tdata;

    // RAM read/write processes ---------------------------------------------
    always @(posedge clk) begin
        if (h_re) hq <= hmem[h_ra];
        if (h_we) hmem[h_wa] <= h_wd;
    end
    always @(posedge clk) begin
        if (c_re) cq <= cmem[c_ra];
        if (c_we) cmem[c_wa] <= c_wd;
    end
    always @(posedge clk) begin
        if (g_re) gq <= gmem[g_ra];
        if (g_we) gmem[g_wa] <= g_wd;
    end
    always @(posedge clk) begin
        if (l_re) lq <= lmem[l_ra];
        if (l_we) lmem[l_wa] <= l_wd;
    end
    always @(posedge clk) begin
        if (f_re) fq <= fmem[f_ra];
        if (f_we) fmem[f_wa] <= f_wd;
    end

    // bilinear combine: identical to the SPEC 4-tap formula
    wire [6:0]  wx0 = 7'd64 - r_fx;
    wire [6:0]  wy0 = 7'd64 - r_fy;
    wire [23:0] top = um18x7({{(18-BITS){1'b0}}, m00}, wx0) +
                      um18x7({{(18-BITS){1'b0}}, m01}, r_fx);
    wire [23:0] bot = um18x7({{(18-BITS){1'b0}}, m10}, wx0) +
                      um18x7({{(18-BITS){1'b0}}, m11}, r_fx);
    wire [24:0] res = {1'b0, um18x7(top[17:0], wy0)} +
                      {1'b0, um18x7(bot[17:0], r_fy)} + 25'd2048;
    wire [BITS-1:0] cl_out = (res[24:12] > MPX) ? MPX[BITS-1:0]
                             : res[BITS-1+12 -: BITS];

    // eot / pixel-count bookkeeping
    wire eot = take && (x == w_last) && (y == h_last);
    wire [FW-1:0] npix_next = (x == {XW{1'b0}} && y == {YW{1'b0}}) ?
                              {{(FW-1){1'b0}}, 1'b1} : npix + {{(FW-1){1'b0}}, 1'b1};

    // configuration legality
    wire [4:0] cfg_tsum = {2'b00, cfg_txl} + {2'b00, cfg_tyl};
    wire [CWX-1:0] cfg_xmask = ({{(CWX-1){1'b0}}, 1'b1} << cfg_txl) - 1'b1;
    wire [CWY-1:0] cfg_ymask = ({{(CWY-1){1'b0}}, 1'b1} << cfg_tyl) - 1'b1;
    wire cfg_bad = (cfg_img_w < 1 || cfg_img_w > MAX_W[CWX-1:0] ||
                    cfg_img_h < 1 || cfg_img_h > MAX_H[CWY-1:0] ||
                    cfg_mode > 2'd2 ||
                    (cfg_mode == 2'd2 &&
                     (CLAHE_EN == 0 || cfg_clip < 16'd1 ||
                      cfg_txl > 3'd4 || cfg_tyl > 3'd4 || cfg_tsum > 5'd4 ||
                      (cfg_img_w & cfg_xmask) != {CWX{1'b0}} ||
                      (cfg_img_h & cfg_ymask) != {CWY{1'b0}})));

    // S_RHE virtual take
    wire vtake = (state == S_RHE) && advance && (ra < w_npix);

    // tile area product at end-of-frame latch
    wire [25:0] tprod = um13x13(tw_ing, th_ing);

    // ======================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_INIT; ii <= 10'd0;
            img_w <= MAX_W[CWX-1:0]; img_h <= MAX_H[CWY-1:0];
            mode <= 2'd0; txl <= 3'd0; tyl <= 3'd0; clip <= 16'd0;
            w_mode <= 2'd0; w_img_w <= MAX_W[CWX-1:0]; w_img_h <= MAX_H[CWY-1:0];
            w_txl <= 3'd0; w_tyl <= 3'd0; w_clip <= 16'd0;
            w_npix <= {FW{1'b0}}; w_tw <= 13'd0; w_th <= 13'd0; w_T <= 18'd0;
            x <= {XW{1'b0}}; y <= {YW{1'b0}}; fi <= {FW{1'b0}};
            npix <= {FW{1'b0}}; fopen <= 1'b0; pend <= 1'b0;
            itx <= 4'd0; ity <= 4'd0; idx <= 13'd0; idy <= 13'd0;
            cap_addr <= 10'd0; cap_mode2 <= 1'b0; cap_emit <= 1'b0;
            cap_u <= 1'b0; cap_l <= 1'b0;
            fwd_v <= 1'b0; fwd_addr <= 10'd0; fwd_cnt <= 18'd0;
            bi <= 10'd0; bph <= 1'b0; bt <= 4'd0;
            cdf <= 18'd0; cdfmin <= 18'd0; excess <= 18'd0; den <= 18'd0;
            mins <= 1'b0; constf <= 1'b0; base <= 11'd0; rem <= 6'd0;
            wi <= 13'd0; wph <= 1'b0;
            ra <= {FW{1'b0}}; rx <= {XW{1'b0}}; ry <= {YW{1'b0}};
            v0 <= 1'b0; v1 <= 1'b0;
            px0x <= {XW{1'b0}}; px1x <= {XW{1'b0}};
            px0y <= {YW{1'b0}}; px1y <= {YW{1'b0}};
            rph <= 4'd0; r_tx <= 4'd0; r_ty <= 4'd0;
            r_dx <= 13'd0; r_dy <= 13'd0;
            r_ta <= 4'd0; r_tb <= 4'd0; r_ua <= 4'd0; r_ub <= 4'd0;
            r_fx <= 7'd0; r_fy <= 7'd0; rcb <= 6'd0;
            m00 <= {BITS{1'b0}}; m01 <= {BITS{1'b0}};
            m10 <= {BITS{1'b0}}; m11 <= {BITS{1'b0}};
            r_done <= 1'b0;
            m_tdata <= {BITS{1'b0}}; m_tvalid <= 1'b0;
            m_tuser <= 1'b0; m_tlast <= 1'b0;
            cfg_done <= 1'b0; cfg_error <= 1'b0; marker_error <= 1'b0;
        end else begin
            cfg_done  <= 1'b0;
            cfg_error <= 1'b0;

            // ---- atomic config: between input frames, or during
            // ---- build/replay (working geometry already latched in w_*).
            if (cfg_valid && cfg_ready) begin
                if (cfg_bad) begin
                    cfg_error <= 1'b1;
                end else begin
                    img_w <= cfg_img_w; img_h <= cfg_img_h;
                    mode  <= cfg_mode;
                    txl   <= cfg_txl;     tyl  <= cfg_tyl;
                    clip  <= cfg_clip;
                    cfg_done <= 1'b1;
                end
            end

            // ---- marker check on every PRESENTED pixel --------------------
            // (s_tvalid): a marker violation is flagged even when the pixel is
            // not accepted this cycle (s_tready low / non-ingest states such as
            // S_INIT).  x,y still name the position the presented pixel would
            // occupy, so the check is identical at take time for a held beat.
            if (s_tvalid &&
                (s_tuser != ((x == {XW{1'b0}}) && (y == {YW{1'b0}})) ||
                 s_tlast != (x == w_last)))
                marker_error <= 1'b1;

            // ---- shared ingest take / stage-B commit ----------------------
            if (advance) begin
                pend <= take;
                if (take) begin
                    cap_addr  <= (mode == 2'd2) ? caddr_ing : {2'b00, gb_ing};
                    cap_mode2 <= (mode == 2'd2);
                    cap_emit  <= (mode == 2'd0);
                    cap_u <= s_tuser; cap_l <= s_tlast;
                    npix <= npix_next;
                    // frame-buffer write pointer (self-cleared each frame)
                    fi <= (x == {XW{1'b0}} && y == {YW{1'b0}}) ?
                          {{(FW-1){1'b0}}, 1'b1} : fi + {{(FW-1){1'b0}}, 1'b1};
                    if (eot) fi <= {FW{1'b0}};
                    // raster position
                    if (x == w_last) begin
                        x <= {XW{1'b0}};
                        y <= (y == h_last) ? {YW{1'b0}} : y + 1'b1;
                    end else begin
                        x <= x + 1'b1;
                    end
                    // ingest tile counters
                    if (x == w_last) begin
                        itx <= 4'd0; idx <= 13'd0;
                        if (y == h_last) begin
                            ity <= 4'd0; idy <= 13'd0;
                        end else if (idy == th_ing - 13'd1) begin
                            idy <= 13'd0; ity <= ity + 4'd1;
                        end else begin
                            idy <= idy + 13'd1;
                        end
                    end else begin
                        if (idx == tw_ing - 13'd1) begin
                            idx <= 13'd0; itx <= itx + 4'd1;
                        end else begin
                            idx <= idx + 13'd1;
                        end
                    end
                    if (x == {XW{1'b0}} && y == {YW{1'b0}}) fopen <= 1'b1;
                    if (eot) begin
                        fopen  <= 1'b0;
                        state  <= S_DRAIN;
                        // A committed mode is consumed by the frame it was
                        // committed for; absent a new commit the next frame
                        // falls back to the reset-default streamable HE_PREV
                        // (mode 0), matching the documented reset default.
                        mode   <= 2'd0;
                        w_mode <= mode; w_img_w <= img_w; w_img_h <= img_h;
                        w_txl  <= txl;  w_tyl  <= tyl;    w_clip  <= clip;
                        w_npix <= npix_next;
                        w_tw   <= tw_ing; w_th <= th_ing;
                        w_T    <= tprod[17:0];
                    end
                end
                if (pend) begin
                    fwd_v <= 1'b1; fwd_addr <= cap_addr; fwd_cnt <= nval;
                    if (cap_emit) begin
                        m_tdata <= gq;
                        m_tuser <= cap_u;
                        m_tlast <= cap_l;
                    end
                end
                m_tvalid <= pend && cap_emit;
            end

            // ---- per-state sequencing --------------------------------------
            // S_ING has an explicit empty branch: the shared take block owns
            // the eot -> S_DRAIN transition, and the default branch must not
            // override it.
            case (state)
                S_ING: ;
                S_INIT: begin
                    if (ii == (CLAHE_EN ? 10'd1023 : 10'd255)) begin
                        state <= S_ING;
                    end else begin
                        ii <= ii + 10'd1;
                    end
                end
                S_DRAIN: begin
                    if (!pend) begin
                        fwd_v <= 1'b0;
                        bi <= 10'd0; bph <= 1'b0;
                        cdf <= 18'd0; cdfmin <= 18'd0; mins <= 1'b0;
                        excess <= 18'd0; bt <= 4'd0;
                        state <= (w_mode == 2'd2) ? S_CT1 : S_HE1;
                    end
                end
                S_HE1: begin
                    if (!bph) begin
                        bph <= 1'b1;                    // hmem[bi] read issued
                    end else begin
                        bph <= 1'b0;
                        cdf <= ncdf;
                        cdfmin <= cdfmin_n;
                        if (!mins && hq != 18'd0) mins <= 1'b1;
                        if (bi == 10'd255) begin
                            den    <= npix_e - cdfmin_n;
                            constf <= (npix_e == cdfmin_n);
                            bi <= 10'd0;
                            state <= S_HE2;
                        end else begin
                            bi <= bi + 10'd1;
                        end
                    end
                end
                S_HE2: begin
                    if (!bph) begin
                        bph <= 1'b1;                    // hmem[bi]=cdf read
                    end else begin
                        bph <= 1'b0;
                        if (bi == 10'd255) begin
                            bi <= 10'd0;
                            if (w_mode == 2'd1) begin
                                ra <= {FW{1'b0}}; rx <= {XW{1'b0}};
                                ry <= {YW{1'b0}};
                                v0 <= 1'b0; v1 <= 1'b0;
                                state <= S_RHE;
                            end else begin
                                state <= S_ING;
                            end
                        end else begin
                            bi <= bi + 10'd1;
                        end
                    end
                end
                S_CT1: begin
                    if (!bph) begin
                        bph <= 1'b1;                    // cmem[{bt,bi}] read
                    end else begin
                        bph <= 1'b0;
                        excess <= exn;
                        if (bi == 10'd63) begin
                            base <= exn[16:6];
                            rem  <= exn[5:0];
                            cdf  <= 18'd0;
                            bi   <= 10'd0;
                            state <= S_CT2;
                        end else begin
                            bi <= bi + 10'd1;
                        end
                    end
                end
                S_CT2: begin
                    if (!bph) begin
                        bph <= 1'b1;                    // clipped bin read
                    end else begin
                        bph <= 1'b0;
                        cdf <= ncdf2;
                        if (bi == 10'd63) begin
                            bi <= 10'd0;
                            if (bt == nt - 5'd1) begin
                                wi  <= 13'd0;
                                wph <= wt_x ? 1'b0 : 1'b1;
                                state <= S_WT;
                            end else begin
                                bt <= bt + 4'd1;
                                excess <= 18'd0;
                                state <= S_CT1;
                            end
                        end else begin
                            bi <= bi + 10'd1;
                        end
                    end
                end
                S_WT: begin
                    if (wt_idle) begin
                        ra <= {FW{1'b0}}; rx <= {XW{1'b0}}; ry <= {YW{1'b0}};
                        r_tx <= 4'd0; r_ty <= 4'd0;
                        r_dx <= 13'd0; r_dy <= 13'd0;
                        rph <= 4'd0; r_done <= 1'b0;
                        state <= S_RCL;
                    end else begin
                        if (!wph && wi < w_tw)
                            fxt[wi[XW-1:0]] <= wt_quo[6:0];
                        if (wph && wi < w_th)
                            fyt[wi[YW-1:0]] <= wt_quo[6:0];
                        if (wi == wt_lim - 13'd1) begin
                            wi <= 13'd0;
                            if (!wph && wt_y) begin
                                wph <= 1'b1;
                            end else begin
                                ra <= {FW{1'b0}}; rx <= {XW{1'b0}};
                                ry <= {YW{1'b0}};
                                r_tx <= 4'd0; r_ty <= 4'd0;
                                r_dx <= 13'd0; r_dy <= 13'd0;
                                rph <= 4'd0; r_done <= 1'b0;
                                state <= S_RCL;
                            end
                        end else begin
                            wi <= wi + 13'd1;
                        end
                    end
                end
                S_RHE: begin
                    if (advance) begin
                        v0 <= vtake;
                        v1 <= v0;
                        m_tvalid <= v1;
                        if (vtake) begin
                            px0x <= rx; px0y <= ry;
                            ra <= ra + {{(FW-1){1'b0}}, 1'b1};
                            if (rx == w_last_r) begin
                                rx <= {XW{1'b0}};
                                ry <= (ry == h_last_r) ? {YW{1'b0}} : ry + 1'b1;
                            end else begin
                                rx <= rx + 1'b1;
                            end
                        end
                        if (v0) begin px1x <= px0x; px1y <= px0y; end
                        if (v1) begin
                            m_tdata <= gq;
                            m_tuser <= (px1x == {XW{1'b0}} && px1y == {YW{1'b0}});
                            m_tlast <= (px1x == w_last_r);
                        end
                    end
                    if (ra == w_npix && !v0 && !v1 && !m_tvalid)
                        state <= S_ING;
                end
                S_RCL: begin
                    if (r_done) begin
                        if (advance) m_tvalid <= 1'b0;
                        if (!m_tvalid) state <= S_ING;
                    end else begin
                        case (rph)
                            4'd0: rph <= 4'd1;          // fmem[ra] issued
                            4'd1: begin                 // fq valid; capture
                                rcb  <= fq[BITS-1 -: 6];// selects, issue A
                                r_ta <= sel_ta; r_tb <= sel_tb;
                                r_ua <= sel_ua; r_ub <= sel_ub;
                                r_fx <= sel_fx; r_fy <= sel_fy;
                                rph  <= 4'd2;
                            end
                            4'd2: begin m00 <= lq; rph <= 4'd3; end // issue B
                            4'd3: begin m01 <= lq; rph <= 4'd4; end // issue C
                            4'd4: begin m10 <= lq; rph <= 4'd5; end // issue D
                            4'd5: begin m11 <= lq; rph <= 4'd6; end
                            default: if (advance) begin // rph 6: emit
                                m_tdata <= cl_out;
                                m_tvalid <= 1'b1;
                                m_tuser <= (rx == {XW{1'b0}} && ry == {YW{1'b0}});
                                m_tlast <= (rx == w_last_r);
                                ra <= ra + {{(FW-1){1'b0}}, 1'b1};
                                if (ra == w_npix - {{(FW-1){1'b0}}, 1'b1})
                                    r_done <= 1'b1;
                                if (rx == w_last_r) begin
                                    rx <= {XW{1'b0}};
                                    r_tx <= 4'd0; r_dx <= 13'd0;
                                    if (ry == h_last_r) begin
                                        ry <= {YW{1'b0}};
                                        r_ty <= 4'd0; r_dy <= 13'd0;
                                    end else begin
                                        ry <= ry + 1'b1;
                                        if (r_dy == w_th - 13'd1) begin
                                            r_dy <= 13'd0; r_ty <= r_ty + 4'd1;
                                        end else r_dy <= r_dy + 13'd1;
                                    end
                                end else begin
                                    rx <= rx + 1'b1;
                                    if (r_dx == w_tw - 13'd1) begin
                                        r_dx <= 13'd0; r_tx <= r_tx + 4'd1;
                                    end else r_dx <= r_dx + 13'd1;
                                end
                                rph <= 4'd0;
                            end
                        endcase
                        if (advance && rph != 4'd6) m_tvalid <= 1'b0;
                    end
                end
                default: state <= S_ING;
            endcase
        end
    end

    // ------------------------------------------------------------------
    initial begin
        if ((BITS != 8 && BITS != 10) || MAX_W < 1 || MAX_H < 1 ||
            MAX_W * MAX_H > 65536 || (CLAHE_EN != 0 && CLAHE_EN != 1))
            $fatal(1, "unsupported histeq_stream parameters");
    end
endmodule
