`timescale 1ns/1ps
// ============================================================================
// ISP-19 geometric remapping: flip / rotate90 / affine / perspective /
// lens-distortion-map, with bilinear sampling over a bounded internal frame
// buffer.
//
// ARCHITECTURE (fill -> drain, NOT pixel-rate):
//   This is a frame-buffer remap core.  A single synchronous frame RAM
//   (FP = MAX_W*MAX_H entries x BITS, default 128x128x8) stores the input
//   frame.  The two phases never overlap:
//     FILL : s_* pixels write fram[raster addr]; s_tready high.
//     DRAIN: after the last input pixel is accepted (eot), s_tready drops
//            and the drain sequencer emits the out_w x out_h output frame
//            on m_*.  For every output pixel it computes the source
//            coordinate (sx,sy) in signed Q16, fetches the four bilinear
//            taps with four SEQUENTIAL frame-RAM reads, accumulates
//            p*wx*wy with one shared shift-add multiplier, and rounds.
//   There is no ping-pong buffer: frames are strictly serialised
//   (fill N_in cycles + drain ~K cycles/out-pixel).  A dual-buffer
//   overlap variant is possible but not implemented (see SPEC.md).
//
// COORDINATE GENERATION (shared generator -> shared sampler):
//   mode 0 FLIP_H : sx = in_w-1-ox , sy = oy
//   mode 1 FLIP_V : sx = ox        , sy = in_h-1-oy
//   mode 2 ROT90  : sx = oy        , sy = in_h-1-ox   (90 deg clockwise;
//                    legality requires out_w==in_h && out_h==in_w)
//   mode 3 AFFINE : sx = a0*ox + a1*oy + a2 , sy = a3*ox + a4*oy + a5
//                   evaluated by incremental raster accumulation (exact:
//                   +=a0 per pixel, +=a1 per row); a6..a8 ignored.
//   mode 4 PERSP  : nx,ny,d as above; sx = RNE(nx*2^16/d), sy = RNE(ny*2^16/d)
//                   through the shared fp_div_iter (infra/fixedpoint/
//                   rtl/recip_div.sv, AW=BW=42, FB=16, OUT_W=42).
//                   d==0 -> saturated coordinate -> out-of-bounds -> fill.
//                   ~2*59 divider cycles per output pixel.
//   mode 5 LENS   : source coordinate from a runtime-loaded mesh LUT.
//                   Mesh node (j,i) holds {sy,sx} Q16; node pitch is
//                   2^kx x 2^ky output pixels (i = min(ox>>kx, lx-2));
//                   the four corner nodes are bilinearly interpolated in
//                   Q8 weight space (floor-shift >>8, same style as LSC)
//                   to yield sx,sy.  Unwritten nodes make the lens APPLY
//                   illegal (written_bits coverage), so uninitialised
//                   mesh RAM can never reach an output.
//
// MATRIX FORMAT: 9 signed coefficients a0..a8, Q9.16 in 26 bits
//   (range [-512, 512) steps of 2^-16).  Internal accumulators are
//   42-bit signed Q16: |a*coord| <= 2^25*2^14 and |sum of 3| < 2^41.
//   Bilinear weights use the top 8 fraction bits of the clamped/floored
//   coordinate (truncation error <= 1/256 px, documented).
//
// OUT-OF-BOUNDS FILL (cfg_fill):
//   0 ZERO      : OOB taps contribute 0
//   1 BORDER    : OOB taps contribute cfg_border
//   2 REPLICATE : source coordinate clamped to [0, W-1]/[0, H-1] first
//   Per-tap OOB flags: tap(x0) OOB iff sx OOB; tap(x1) OOB iff sx OOB or
//   x0 == in_w-1.  If sx is fully OOB all four taps are the border value
//   and the weights sum to exactly 65536, so the output is exactly
//   cfg_border.  Tap addresses are always index-clamped, so the frame RAM
//   never sees an out-of-range address.
//
// BILINEAR ROUNDING: out = (sum p_k * wx_k * wy_k + 2^15) >> 16,
//   round-half-up, weights sum exactly 2^16 so the result never exceeds
//   the pixel range (no saturation path needed).
//
// CONFIG: one atomic 320-bit cfg_valid/cfg_ready bundle
//   [12:0] in_w [25:13] in_h [38:26] out_w [51:39] out_h
//   [54:52] mode [56:55] fill [66:57] border(10b; low BITS used)
//   [71:67] lx [76:72] ly [80:77] kx [84:81] ky
//   [85+26k +: 26] a_k (signed Q9.16), k=0..8   [319] clr_mesh
//   An accepted legal bundle is pending and commits atomically at the
//   next accepted SOF (tuser) input pixel; the SOF pixel itself already
//   sees the new config.  cfg_ready drops while pending so two bundles
//   can never mix; a bundle waiting on cfg_ready is only accepted on the
//   commit edge and then rejected with cfg_error if illegal.
//   clr_mesh=1 clears the mesh written_bits at the accept edge (allows a
//   mesh reload sequence: apply(clr) -> write nodes -> apply).
//
// MESH WRITE PORT l_valid/l_ready/l_row/l_col/l_data={sy,sx} (27b Q16
//   signed each).  Writes go directly into mesh RAM and set
//   written_bits[row*LXMAX+col].  l_ready drops during the lens mesh
//   read window of a drain (D_PIX + D_LN0..D_LN3 while mode==LENS);
//   writes proceed at up to 1/cycle everywhere else, including fills and
//   non-lens drains.  Scheduling contract: all mesh writes for a lens
//   frame must be accepted before that frame's fill completes.
//   Out-of-range row/col pulse l_error and change nothing.
//
// Markers: s_tuser=SOF at (0,0), s_tlast=EOL at x=in_w-1, checked on
//   every accepted pixel (SOF mid-frame / orphan / early/missing EOL
//   pulse o_error; no resynchronisation, same contract as framediff).
//   m_tuser/m_tlast follow the OUTPUT raster (SOF at out (0,0), EOL at
//   ox==out_w-1).  Single clk, low-active synchronous rst_n; reset drops
//   in-flight state; both RAMs are never cleared.
// ============================================================================
module remap_stream #(
    parameter BITS = 8,                    // pixel width: 8 or 10
    parameter MAX_W = 128,                 // max input width  1..8191
    parameter MAX_H = 128,                 // max input height 1..8191
    parameter LXMAX = 17,                  // max lens mesh nodes/row 2..31
    parameter LYMAX = 17,                  // max lens mesh nodes/col 2..31
    // Derived widths; override only to mirror the formulas.
    parameter FP  = (MAX_W < 1 || MAX_H < 1) ? 1 : MAX_W * MAX_H,
    parameter CWX = (MAX_W < 1) ? 1 : $clog2(MAX_W + 1),
    parameter CWY = (MAX_H < 1) ? 1 : $clog2(MAX_H + 1),
    parameter AW  = (FP < 2) ? 1 : $clog2(FP),
    parameter LC  = (LXMAX < 2 || LYMAX < 2) ? 1 : LXMAX * LYMAX,
    parameter LAW = (LC < 2) ? 1 : $clog2(LC)
)(
    input  wire clk, rst_n,
    // input pixel stream: tuser = SOF (0,0), tlast = EOL
    input  wire [BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    // output stream: remapped frame, tuser/tlast on the OUTPUT raster
    output reg  [BITS-1:0] m_tdata,
    output reg  m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    // atomic 320-bit configuration bundle (commits at next SOF take)
    input  wire cfg_valid, output wire cfg_ready,
    input  wire [319:0] cfg_data,
    output reg  cfg_done, cfg_error,
    // lens mesh write port {sy[26:0] signed, sx[26:0] signed} Q16
    input  wire l_valid, output wire l_ready,
    input  wire [4:0] l_row, input wire [4:0] l_col,
    input  wire [53:0] l_data,
    output reg  l_error,                   // out-of-range mesh write
    output reg  o_error,                   // stream marker violation pulse
    output wire busy
);
    // -------- modes / fill codes ----------
    localparam M_FLIPH = 3'd0, M_FLIPV = 3'd1, M_ROT90 = 3'd2,
               M_AFFINE = 3'd3, M_PERSP = 3'd4, M_LENS = 3'd5;
    localparam F_ZERO = 2'd0, F_BORDER = 2'd1, F_REP = 2'd2;
    // -------- drain sub-states ----------
    localparam D_PIX = 5'd0,  D_RB0 = 5'd1,  D_RB1 = 5'd2,
               D_RD0 = 5'd3,  D_RD1 = 5'd4,  D_RD2 = 5'd5,  D_RD3 = 5'd6,
               D_AC0 = 5'd7,  D_AC1 = 5'd8,  D_AC2 = 5'd9,  D_AC3 = 5'd10,
               D_FIN = 5'd11, D_EMIT = 5'd12,
               D_LN0 = 5'd13, D_LN1 = 5'd14, D_LN2 = 5'd15, D_LN3 = 5'd16,
               D_LI0 = 5'd17, D_LI1 = 5'd18, D_LI2 = 5'd19,
               D_LI3 = 5'd20, D_LI4 = 5'd21, D_LI5 = 5'd22,
               D_DX0 = 5'd23, D_DX1 = 5'd24, D_DY0 = 5'd25, D_DY1 = 5'd26;
    localparam ST_FILL = 1'b0, ST_DRAIN = 1'b1;

    // ---------------- config fields of the offered bundle --------------
    wire [12:0] c_iw = cfg_data[12:0];
    wire [12:0] c_ih = cfg_data[25:13];
    wire [12:0] c_ow = cfg_data[38:26];
    wire [12:0] c_oh = cfg_data[51:39];
    wire [2:0]  c_mode = cfg_data[54:52];
    wire [1:0]  c_fill = cfg_data[56:55];
    wire [BITS-1:0] c_border = cfg_data[57 +: BITS];
    wire [4:0]  c_lx = cfg_data[71:67];
    wire [4:0]  c_ly = cfg_data[76:72];
    wire [3:0]  c_kx = cfg_data[80:77];
    wire [3:0]  c_ky = cfg_data[84:81];
    wire        c_clr = cfg_data[319];
    // coefficients a0..a8 : signed 26-bit Q9.16 at [85+26k +: 26]

    // ---------------- pending / active configuration --------------------
    reg [12:0] p_iw, p_ih, p_ow, p_oh;
    reg [2:0]  p_mode; reg [1:0] p_fill; reg [BITS-1:0] p_border;
    reg [4:0]  p_lx, p_ly; reg [3:0] p_kx, p_ky;
    reg signed [25:0] p_coef [0:8];
    reg        pend_valid;
    reg [12:0] a_iw, a_ih, a_ow, a_oh;
    reg [2:0]  a_mode; reg [1:0] a_fill; reg [BITS-1:0] a_border;
    reg [4:0]  a_lx, a_ly; reg [3:0] a_kx, a_ky;
    reg signed [25:0] a_coef [0:8];
    reg        a_valid;
    reg [LC-1:0] written_bits;          // lens mesh coverage flags

    // ---------------- legality of the offered bundle --------------------
    wire [20:0] covx = ({8'd0, c_lx} - 21'd1) << c_kx;   // (lx-1)<<kx
    wire [20:0] covy = ({8'd0, c_ly} - 21'd1) << c_ky;
    wire [LC-1:0] lens_req;
    genvar gi;
    generate for (gi = 0; gi < LC; gi = gi + 1) begin : gmask
        assign lens_req[gi] =
            ((gi % LXMAX) < {27'd0, c_lx}) && ((gi / LXMAX) < {27'd0, c_ly});
    end endgenerate
    wire lens_ok = (c_lx >= 5'd2) && (c_lx <= LXMAX[4:0])
        && (c_ly >= 5'd2) && (c_ly <= LYMAX[4:0])
        && (covx >= {8'd0, c_ow} - 21'd1)
        && (covy >= {8'd0, c_oh} - 21'd1)
        && ((lens_req & ~written_bits) == {LC{1'b0}});
    wire cfg_bad = (c_iw == 13'd0) || (c_ih == 13'd0)
        || (c_ow == 13'd0) || (c_oh == 13'd0)
        || (c_iw > MAX_W[12:0]) || (c_ih > MAX_H[12:0])
        || (c_mode > M_LENS) || (c_fill > F_REP)
        || (c_mode == M_ROT90 && ((c_ow != c_ih) || (c_oh != c_iw)))
        || (c_mode == M_LENS && !lens_ok);

    // ---------------- stream bookkeeping (framediff idiom) --------------
    reg state;
    reg in_frame;
    reg [CWX-1:0] x;
    reg [CWY-1:0] y;
    reg [AW-1:0]  fi;

    wire fire = s_tvalid && s_tready;
    wire commit_edge = fire && s_tuser && pend_valid;
    assign s_tready = rst_n && (state == ST_FILL) && (a_valid || pend_valid);
    assign cfg_ready = rst_n && (!pend_valid || commit_edge);
    assign busy = rst_n && (in_frame || (state == ST_DRAIN)
                            || m_tvalid || pend_valid);

    wire e_pick = s_tuser && pend_valid;
    wire [CWX-1:0] e_w = e_pick ? p_iw[CWX-1:0] : a_iw[CWX-1:0];
    wire [CWY-1:0] e_h = e_pick ? p_ih[CWY-1:0] : a_ih[CWY-1:0];
    wire [CWX-1:0] cx = s_tuser ? {CWX{1'b0}} : x;
    wire [CWY-1:0] cy = s_tuser ? {CWY{1'b0}} : y;
    wire [CWX-1:0] wlast = e_w - {{(CWX-1){1'b0}}, 1'b1};
    wire [CWY-1:0] hlast = e_h - {{(CWY-1){1'b0}}, 1'b1};
    wire rowend = s_tlast || (cx == wlast);
    wire eot    = rowend && (cy == hlast);
    wire [AW:0] fi_e = {1'b0, fi};
    wire [AW-1:0] caddr = s_tuser ? {AW{1'b0}}
                         : ((fi_e >= FP[AW:0]) ? {AW{1'b0}} : fi);

    // ---------------- memories (synchronous; BSRAM friendly) ------------
    (* ram_style="block" *) reg [BITS-1:0] fram [0:FP-1];
    // Mesh RAM is split into two <=27-bit memories so each maps onto a
    // Gowin 18/36-bit block-RAM port width (a single 54-bit word does not).
    (* ram_style="block" *) reg [26:0] lram_x [0:LC-1];
    (* ram_style="block" *) reg [26:0] lram_y [0:LC-1];
    reg [BITS-1:0] frdata;
    reg [26:0] lrxd, lryd;

    // ---------------- drain-state registers -----------------------------
    reg [4:0]  dstate;
    reg [12:0] ox, oy;                   // output raster position
    reg signed [41:0] sx_reg, sy_reg;    // source coords, Q16
    reg signed [41:0] nxa, nya, nda;     // incremental numerator/denominator
    reg signed [41:0] rbx, rby, rbd;     // row-base accumulators
    reg [25:0] rb0, rb1;                 // frame-RAM row bases
    reg [12:0] ax0r, ax1r, ay0r, ay1r;   // clamped tap indices
    reg xo0r, xo1r, yo0r, yo1r;          // per-axis tap OOB flags
    reg [8:0] wx0r, wx1r, wy0r, wy1r;    // Q8 weights 0..256
    reg [16:0] wk0, wk1, wk2, wk3;       // weight products <= 65536
    reg [BITS-1:0] p0, p1, p2, p3;       // tap data
    reg [27:0] acc;                      // bilinear accumulator
    reg [4:0]  l_i, l_j;                 // mesh node index
    reg [8:0]  l_fx, l_fy;               // mesh interp weights 0..256
    reg [LAW-1:0] l_addr0;
    reg [53:0] n00, n01, n10, n11;       // mesh node words {sy,sx}
    reg signed [27:0] sxtop, sxbot, sytop, sybot;

    // ---------------- shared multiplier (LUT shift-add, no DSP) ---------
    // signed 28-bit x unsigned 17-bit -> signed 45-bit
    reg signed [27:0] mA;
    reg [16:0] mB;
    function [44:0] mul_s;
        input [27:0] a;
        input [16:0] b;
        integer k;
        reg [44:0] accm;
        reg [44:0] ae;
        begin
            ae = {{17{a[27]}}, a};
            accm = 45'd0;
            for (k = 0; k < 17; k = k + 1)
                if (b[k]) accm = accm + (ae << k);
            mul_s = accm;
        end
    endfunction
    wire [44:0] mprod = mul_s(mA, mB);
    wire signed [27:0] mpsh8 = mprod[35:8];   // (a*b) >> 8, |value| < 2^27

    // ---------------- tap-value selection --------------------------------
    wire rep = (a_fill == F_REP);
    wire [BITS-1:0] tv0 = (rep || !(xo0r | yo0r)) ? p0 : a_border;
    wire [BITS-1:0] tv1 = (rep || !(xo1r | yo0r)) ? p1 : a_border;
    wire [BITS-1:0] tv2 = (rep || !(xo0r | yo1r)) ? p2 : a_border;
    wire [BITS-1:0] tv3 = (rep || !(xo1r | yo1r)) ? p3 : a_border;

    // ---------------- integer-mode coordinates (comb) -------------------
    wire signed [15:0] oxs = $signed({3'b000, ox});
    wire signed [15:0] oys = $signed({3'b000, oy});
    wire signed [15:0] iws = $signed({3'b000, a_iw});
    wire signed [15:0] ihs = $signed({3'b000, a_ih});
    wire signed [15:0] icx = (a_mode == M_FLIPH) ? (iws - 16'sd1 - oxs)
                           : (a_mode == M_FLIPV) ? oxs : oys;
    // ROT90 clockwise: sy = in_h - 1 - ox
    wire signed [15:0] icy = (a_mode == M_FLIPH) ? oys
                           : (a_mode == M_FLIPV) ? (ihs - 16'sd1 - oys)
                                                 : (ihs - 16'sd1 - oxs);

    // ---------------- mesh node coordinate extraction -------------------
    function signed [27:0] nx27; input [53:0] w;
        nx27 = {w[26], w[26:0]}; endfunction
    function signed [27:0] ny27; input [53:0] w;
        ny27 = {w[53], w[53:27]}; endfunction

    // ---------------- lens index computation (comb, used in D_PIX) ------
    wire [4:0] lx_m2 = a_lx - 5'd2;
    wire [4:0] ly_m2 = a_ly - 5'd2;
    wire [12:0] ishf = ox >> a_kx;
    wire [12:0] jshf = oy >> a_ky;
    wire [4:0] li_c = ((ishf[12:5] != 8'd0) || (ishf[4:0] > lx_m2))
                      ? lx_m2 : ishf[4:0];
    wire [4:0] lj_c = ((jshf[12:5] != 8'd0) || (jshf[4:0] > ly_m2))
                      ? ly_m2 : jshf[4:0];
    wire [12:0] remx_c = ox - ({8'd0, li_c} << a_kx);
    wire [12:0] remy_c = oy - ({8'd0, lj_c} << a_ky);
    // (rem<<8)>>k <= 256 while mesh coverage holds (checked at APPLY)
    wire [20:0] lfxsh = ({8'd0, remx_c} << 8) >> a_kx;
    wire [20:0] lfysh = ({8'd0, remy_c} << 8) >> a_ky;
    wire [8:0] lfx_c = lfxsh[8:0];
    wire [8:0] lfy_c = lfysh[8:0];
    wire [LAW-1:0] lbase_c = lj_c * LXMAX[LAW-1:0] + li_c;

    // ---------------- tap geometry from sx_reg/sy_reg (comb, D_RB0) -----
    wire [41:0] iw16   = {13'd0, a_iw, 16'd0};          // in_w  << 16
    wire [41:0] iw16m1 = iw16 - 42'd65536;              // (in_w-1) << 16
    wire [41:0] ih16   = {13'd0, a_ih, 16'd0};
    wire [41:0] ih16m1 = ih16 - 42'd65536;
    wire sxn = sx_reg[41];
    wire syn = sy_reg[41];
    wire sxo = sxn || (sx_reg[41:0] >= iw16);
    wire syo = syn || (sy_reg[41:0] >= ih16);
    wire [41:0] sx_c = rep ? (sxn ? 42'd0 : (sxo ? iw16m1 : sx_reg))
                           : sx_reg;
    wire [41:0] sy_c = rep ? (syn ? 42'd0 : (syo ? ih16m1 : sy_reg))
                           : sy_reg;
    wire [7:0] fx8_c = sx_c[15:8];
    wire [7:0] fy8_c = sy_c[15:8];
    wire [12:0] ax0_c = sxn ? 13'd0
                        : (sxo ? (a_iw - 13'd1) : sx_c[28:16]);
    wire [12:0] ay0_c = syn ? 13'd0
                        : (syo ? (a_ih - 13'd1) : sy_c[28:16]);
    wire [12:0] ax1_c = (ax0_c >= a_iw - 13'd1) ? (a_iw - 13'd1)
                                              : ax0_c + 13'd1;
    wire [12:0] ay1_c = (ay0_c >= a_ih - 13'd1) ? (a_ih - 13'd1)
                                              : ay0_c + 13'd1;
    wire xo0_c = sxo;
    wire xo1_c = sxo || (ax0_c == a_iw - 13'd1);
    wire yo0_c = syo;
    wire yo1_c = syo || (ay0_c == a_ih - 13'd1);
    wire [8:0] wx1_c = {1'b0, fx8_c};
    wire [8:0] wx0_c = 9'd256 - {1'b0, fx8_c};
    wire [8:0] wy1_c = {1'b0, fy8_c};
    wire [8:0] wy0_c = 9'd256 - {1'b0, fy8_c};

    // ---------------- frame-RAM read port --------------------------------
    wire fram_rd_iss = (state == ST_DRAIN)
        && (dstate == D_RD0 || dstate == D_RD1
            || dstate == D_RD2 || dstate == D_RD3);
    wire [25:0] fr_base = (dstate == D_RD0 || dstate == D_RD1) ? rb0 : rb1;
    wire [12:0] fr_x = (dstate == D_RD0 || dstate == D_RD2) ? ax0r : ax1r;
    wire [26:0] fraddr = {1'b0, fr_base} + {14'd0, fr_x};

    // ---------------- mesh RAM ports ------------------------------------
    wire lens_rd_phase = (state == ST_DRAIN) && (a_mode == M_LENS)
        && (dstate == D_PIX || (dstate >= D_LN0 && dstate <= D_LN3));
    assign l_ready = rst_n && !lens_rd_phase;
    wire l_legal = (l_row < LXMAX[4:0]) && (l_col < LXMAX[4:0]);
    wire l_fire = l_valid && l_ready;
    wire [LAW-1:0] lwaddr = l_row * LXMAX[LAW-1:0] + l_col;
    wire lram_rd_iss = lens_rd_phase;
    wire [LAW-1:0] lraddr = (dstate == D_PIX) ? lbase_c
                          : (dstate == D_LN0) ? l_addr0 + 1'b1
                          : (dstate == D_LN1) ? l_addr0 + LXMAX[LAW-1:0]
                          : l_addr0 + LXMAX[LAW-1:0] + 1'b1;

    always @(posedge clk) begin
        if (fire) fram[caddr] <= s_tdata;
        if (fram_rd_iss) frdata <= fram[fraddr[AW-1:0]];
    end
    always @(posedge clk) begin
        if (l_fire && l_legal) begin
            lram_x[lwaddr] <= l_data[26:0];
            lram_y[lwaddr] <= l_data[53:27];
        end
        if (lram_rd_iss) begin
            lrxd <= lram_x[lraddr];
            lryd <= lram_y[lraddr];
        end
    end

    // ---------------- perspective divider (shared infra) -----------------
    wire [41:0] div_a = (dstate == D_DX0 || dstate == D_DX1) ? nxa : nya;
    wire [83:0] div_sd = {nda, div_a};          // {b, a} per fp_div_iter
    wire div_sv = (state == ST_DRAIN)
                  && (dstate == D_DX0 || dstate == D_DY0);
    wire div_sr, div_mv;
    wire [41:0] div_md;
    wire [1:0]  div_mu;
    fp_div_iter #(.AW(42), .BW(42), .FB(16), .OUT_W(42)) udiv (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(div_sd), .s_tvalid(div_sv), .s_tready(div_sr),
        .m_tdata(div_md), .m_tuser(div_mu),
        .m_tvalid(div_mv), .m_tready(1'b1));

    // ---------------- operand mux of the shared multiplier --------------
    always @* begin
        mA = 28'sd0;
        mB = 17'd0;
        case (dstate)
            D_RB0: begin mA = {15'd0, ay0_c};  mB = {4'd0, a_iw}; end
            D_RB1: begin mA = {15'd0, ay1r};   mB = {4'd0, a_iw}; end
            D_RD0: begin mA = {19'd0, wx0r};   mB = {8'd0, wy0r}; end
            D_RD1: begin mA = {19'd0, wx1r};   mB = {8'd0, wy0r}; end
            D_RD2: begin mA = {19'd0, wx0r};   mB = {8'd0, wy1r}; end
            D_RD3: begin mA = {19'd0, wx1r};   mB = {8'd0, wy1r}; end
            D_AC0: begin mA = {{(28-BITS){1'b0}}, tv0}; mB = wk0; end
            D_AC1: begin mA = {{(28-BITS){1'b0}}, tv1}; mB = wk1; end
            D_AC2: begin mA = {{(28-BITS){1'b0}}, tv2}; mB = wk2; end
            D_AC3: begin mA = {{(28-BITS){1'b0}}, tv3}; mB = wk3; end
            D_LI0: begin mA = nx27(n01) - nx27(n00); mB = {8'd0, l_fx}; end
            D_LI1: begin mA = nx27(n11) - nx27(n10); mB = {8'd0, l_fx}; end
            D_LI2: begin mA = sxbot - sxtop;         mB = {8'd0, l_fy}; end
            D_LI3: begin mA = ny27(n01) - ny27(n00); mB = {8'd0, l_fx}; end
            D_LI4: begin mA = ny27(n11) - ny27(n10); mB = {8'd0, l_fx}; end
            D_LI5: begin mA = sybot - sytop;         mB = {8'd0, l_fy}; end
            default: ;
        endcase
    end

    wire signed [27:0] sxir = sxtop + mpsh8;    // D_LI2 result
    wire signed [27:0] syir = sytop + mpsh8;    // D_LI5 result
    wire [28:0] rnd = {1'b0, acc} + 29'd32768;  // round-half-up >>16
    wire [BITS-1:0] outv = rnd[16+BITS-1 -: BITS];

    function [41:0] ex42; input signed [25:0] c;
        ex42 = {{16{c[25]}}, c}; endfunction

    // On a 1x1 frame the config commit and the fill-eot edge coincide; the
    // drain accumulators must load from the *committing* bundle.
    wire signed [25:0] dcoef2 = commit_edge ? p_coef[2] : a_coef[2];
    wire signed [25:0] dcoef5 = commit_edge ? p_coef[5] : a_coef[5];
    wire signed [25:0] dcoef8 = commit_edge ? p_coef[8] : a_coef[8];

    integer ci;
    // ---------------- main sequential block -----------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_FILL; in_frame <= 1'b0;
            x <= {CWX{1'b0}}; y <= {CWY{1'b0}}; fi <= {AW{1'b0}};
            p_iw <= 13'd0; p_ih <= 13'd0; p_ow <= 13'd0; p_oh <= 13'd0;
            p_mode <= 3'd0; p_fill <= 2'd0; p_border <= {BITS{1'b0}};
            p_lx <= 5'd0; p_ly <= 5'd0; p_kx <= 4'd0; p_ky <= 4'd0;
            a_iw <= 13'd0; a_ih <= 13'd0; a_ow <= 13'd0; a_oh <= 13'd0;
            a_mode <= 3'd0; a_fill <= 2'd0; a_border <= {BITS{1'b0}};
            a_lx <= 5'd0; a_ly <= 5'd0; a_kx <= 4'd0; a_ky <= 4'd0;
            for (ci = 0; ci < 9; ci = ci + 1) begin
                p_coef[ci] <= 26'sd0; a_coef[ci] <= 26'sd0;
            end
            pend_valid <= 1'b0; a_valid <= 1'b0;
            written_bits <= {LC{1'b0}};
            dstate <= D_PIX; ox <= 13'd0; oy <= 13'd0;
            sx_reg <= 42'sd0; sy_reg <= 42'sd0;
            nxa <= 42'sd0; nya <= 42'sd0; nda <= 42'sd0;
            rbx <= 42'sd0; rby <= 42'sd0; rbd <= 42'sd0;
            rb0 <= 26'd0; rb1 <= 26'd0;
            ax0r <= 13'd0; ax1r <= 13'd0; ay0r <= 13'd0; ay1r <= 13'd0;
            xo0r <= 1'b0; xo1r <= 1'b0; yo0r <= 1'b0; yo1r <= 1'b0;
            wx0r <= 9'd0; wx1r <= 9'd0; wy0r <= 9'd0; wy1r <= 9'd0;
            wk0 <= 17'd0; wk1 <= 17'd0; wk2 <= 17'd0; wk3 <= 17'd0;
            p0 <= {BITS{1'b0}}; p1 <= {BITS{1'b0}};
            p2 <= {BITS{1'b0}}; p3 <= {BITS{1'b0}};
            acc <= 28'd0;
            l_i <= 5'd0; l_j <= 5'd0; l_fx <= 9'd0; l_fy <= 9'd0;
            l_addr0 <= {LAW{1'b0}};
            n00 <= 54'd0; n01 <= 54'd0; n10 <= 54'd0; n11 <= 54'd0;
            sxtop <= 28'sd0; sxbot <= 28'sd0;
            sytop <= 28'sd0; sybot <= 28'sd0;
            // frdata/lrxd/lryd intentionally NOT reset here: their memory
            // read registers live in the RAM-port always block above.
            m_tdata <= {BITS{1'b0}}; m_tvalid <= 1'b0;
            m_tuser <= 1'b0; m_tlast <= 1'b0;
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            l_error <= 1'b0; o_error <= 1'b0;
        end else begin
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            l_error <= 1'b0; o_error <= 1'b0;
            // ---------- fill: marker check + frame bookkeeping ----------
            if (fire) begin
                if (s_tuser && in_frame)   o_error <= 1'b1;
                if (!s_tuser && !in_frame) o_error <= 1'b1;
                if (s_tlast && cx != wlast)  o_error <= 1'b1;
                if (!s_tlast && cx == wlast) o_error <= 1'b1;
                fi <= s_tuser ? {{(AW-1){1'b0}}, 1'b1}
                       : (eot ? {AW{1'b0}} : fi + {{(AW-1){1'b0}}, 1'b1});
                if (rowend) begin
                    x <= {CWX{1'b0}};
                    if (cy == hlast) begin
                        y <= {CWY{1'b0}}; in_frame <= 1'b0;
                    end else begin
                        y <= cy + {{(CWY-1){1'b0}}, 1'b1}; in_frame <= 1'b1;
                    end
                end else begin
                    x <= cx + {{(CWX-1){1'b0}}, 1'b1}; in_frame <= 1'b1;
                end
                if (eot) begin
                    state <= ST_DRAIN; dstate <= D_PIX;
                    ox <= 13'd0; oy <= 13'd0;
                    rbx <= ex42(dcoef2); rby <= ex42(dcoef5);
                    rbd <= ex42(dcoef8);
                    nxa <= ex42(dcoef2); nya <= ex42(dcoef5);
                    nda <= ex42(dcoef8);
                    acc <= 28'd0;
                end
            end
            // ---------- drain sequencer ---------------------------------
            if (state == ST_DRAIN) begin
                case (dstate)
                D_PIX: begin
                    case (a_mode)
                    M_FLIPH, M_FLIPV, M_ROT90: begin
                        sx_reg <= {{10{icx[15]}}, icx, 16'd0};
                        sy_reg <= {{10{icy[15]}}, icy, 16'd0};
                        dstate <= D_RB0;
                    end
                    M_AFFINE: begin
                        if (ox == 13'd0) begin
                            nxa <= rbx; nya <= rby; nda <= rbd;
                            sx_reg <= rbx; sy_reg <= rby;
                        end else begin
                            sx_reg <= nxa; sy_reg <= nya;
                        end
                        dstate <= D_RB0;
                    end
                    M_PERSP: begin
                        if (ox == 13'd0) begin
                            nxa <= rbx; nya <= rby; nda <= rbd;
                        end
                        dstate <= D_DX0;
                    end
                    default: begin // M_LENS
                        l_i <= li_c; l_j <= lj_c;
                        l_fx <= lfx_c; l_fy <= lfy_c;
                        l_addr0 <= lbase_c;
                        dstate <= D_LN0;
                    end
                    endcase
                end
                D_DX0: if (div_sr) dstate <= D_DX1;
                D_DX1: if (div_mv) begin
                    sx_reg <= div_md; dstate <= D_DY0;
                end
                D_DY0: if (div_sr) dstate <= D_DY1;
                D_DY1: if (div_mv) begin
                    sy_reg <= div_md; dstate <= D_RB0;
                end
                D_LN0: begin n00 <= {lryd, lrxd}; dstate <= D_LN1; end
                D_LN1: begin n01 <= {lryd, lrxd}; dstate <= D_LN2; end
                D_LN2: begin n10 <= {lryd, lrxd}; dstate <= D_LN3; end
                D_LN3: begin n11 <= {lryd, lrxd}; dstate <= D_LI0; end
                D_LI0: begin sxtop <= nx27(n00) + mpsh8; dstate <= D_LI1; end
                D_LI1: begin sxbot <= nx27(n10) + mpsh8; dstate <= D_LI2; end
                D_LI2: begin
                    sx_reg <= {{14{sxir[27]}}, sxir}; dstate <= D_LI3;
                end
                D_LI3: begin sytop <= ny27(n00) + mpsh8; dstate <= D_LI4; end
                D_LI4: begin sybot <= ny27(n10) + mpsh8; dstate <= D_LI5; end
                D_LI5: begin
                    sy_reg <= {{14{syir[27]}}, syir}; dstate <= D_RB0;
                end
                D_RB0: begin
                    rb0 <= mprod[25:0];
                    ax0r <= ax0_c; ax1r <= ax1_c;
                    ay0r <= ay0_c; ay1r <= ay1_c;
                    xo0r <= xo0_c; xo1r <= xo1_c;
                    yo0r <= yo0_c; yo1r <= yo1_c;
                    wx0r <= wx0_c; wx1r <= wx1_c;
                    wy0r <= wy0_c; wy1r <= wy1_c;
                    dstate <= D_RB1;
                end
                D_RB1: begin rb1 <= mprod[25:0]; dstate <= D_RD0; end
                D_RD0: begin wk0 <= mprod[16:0]; dstate <= D_RD1; end
                D_RD1: begin wk1 <= mprod[16:0]; p0 <= frdata; dstate <= D_RD2; end
                D_RD2: begin wk2 <= mprod[16:0]; p1 <= frdata; dstate <= D_RD3; end
                D_RD3: begin wk3 <= mprod[16:0]; p2 <= frdata; dstate <= D_AC0; end
                D_AC0: begin p3 <= frdata; acc <= mprod[27:0]; dstate <= D_AC1; end
                D_AC1: begin acc <= acc + mprod[27:0]; dstate <= D_AC2; end
                D_AC2: begin acc <= acc + mprod[27:0]; dstate <= D_AC3; end
                D_AC3: begin acc <= acc + mprod[27:0]; dstate <= D_FIN; end
                D_FIN: begin
                    m_tdata <= outv;
                    m_tvalid <= 1'b1;
                    m_tuser <= (ox == 13'd0) && (oy == 13'd0);
                    m_tlast <= (ox == a_ow - 13'd1);
                    dstate <= D_EMIT;
                end
                D_EMIT: if (m_tready) begin
                    m_tvalid <= 1'b0;
                    if ((ox == a_ow - 13'd1) && (oy == a_oh - 13'd1)) begin
                        state <= ST_FILL;
                    end else begin
                        dstate <= D_PIX;
                        nxa <= nxa + ex42(a_coef[0]);
                        nya <= nya + ex42(a_coef[3]);
                        nda <= nda + ex42(a_coef[6]);
                        if (ox == a_ow - 13'd1) begin
                            ox <= 13'd0; oy <= oy + 13'd1;
                            rbx <= rbx + ex42(a_coef[1]);
                            rby <= rby + ex42(a_coef[4]);
                            rbd <= rbd + ex42(a_coef[7]);
                        end else begin
                            ox <= ox + 13'd1;
                        end
                    end
                end
                default: dstate <= D_PIX;
                endcase
            end
            // ---------- pending -> active commit at the SOF take --------
            if (commit_edge) begin
                a_iw <= p_iw; a_ih <= p_ih; a_ow <= p_ow; a_oh <= p_oh;
                a_mode <= p_mode; a_fill <= p_fill; a_border <= p_border;
                a_lx <= p_lx; a_ly <= p_ly; a_kx <= p_kx; a_ky <= p_ky;
                for (ci = 0; ci < 9; ci = ci + 1)
                    a_coef[ci] <= p_coef[ci];
                a_valid <= 1'b1; pend_valid <= 1'b0;
            end
            // ---------- config bundle accept / reject -------------------
            if (cfg_valid && cfg_ready) begin
                if (cfg_bad) begin
                    cfg_error <= 1'b1;
                end else begin
                    p_iw <= c_iw; p_ih <= c_ih; p_ow <= c_ow; p_oh <= c_oh;
                    p_mode <= c_mode; p_fill <= c_fill; p_border <= c_border;
                    p_lx <= c_lx; p_ly <= c_ly; p_kx <= c_kx; p_ky <= c_ky;
                    for (ci = 0; ci < 9; ci = ci + 1)
                        p_coef[ci] <= cfg_data[85 + 26*ci +: 26];
                    pend_valid <= 1'b1; cfg_done <= 1'b1;
                    if (c_clr) written_bits <= {LC{1'b0}};
                end
            end
            // ---------- mesh write bookkeeping --------------------------
            if (l_fire) begin
                if (!l_legal) l_error <= 1'b1;
                else written_bits[lwaddr] <= 1'b1;
            end
        end
    end

    // ---------------- static parameter contract -------------------------
    initial begin
        if (BITS != 8 && BITS != 10)
            $fatal(1, "unsupported BITS (8 or 10)");
        if (MAX_W < 1 || MAX_W > 8191)
            $fatal(1, "unsupported MAX_W (1..8191)");
        if (MAX_H < 1 || MAX_H > 8191)
            $fatal(1, "unsupported MAX_H (1..8191)");
        if (FP < 1 || FP > 65536)
            $fatal(1, "unsupported MAX_W*MAX_H (must be <= 65536)");
        if (LXMAX < 2 || LXMAX > 31 || LYMAX < 2 || LYMAX > 31)
            $fatal(1, "unsupported LXMAX/LYMAX (2..31)");
    end
endmodule
