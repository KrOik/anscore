`timescale 1ns/1ps
// ============================================================================
// ISP-17 frame differencing / background modelling streaming core.
//
// Runtime modes (cfg_mode):
//   0 DIFF   : mask = |cur - ref| > thresh; ref' = cur
//              -> ref RAM holds the previous frame; canonical |cur - prev|.
//   1 BG     : out  = ref' = ref + ((cur - ref) >>> alpha_eff)
//              running-mean background stream (bg' is emitted per pixel).
//   2 MOTION : mask = |cur - ref| > thresh; ref' updated like mode 1.
//
// One synchronous frame RAM (FP = MAX_W*MAX_H entries x BITS) holds the
// per-pixel reference.  A take issues the reference read; the single
// pipeline stage computes the difference and commits the reference
// write-back one edge later, so the RAM performs exactly 1 read +
// 1 write per pixel cycle -> II=1 sustained (single-port-per-direction
// semantics; maps to one semi-dual-port BSRAM, no external memory).
// A 1-deep (addr,data) forward register covers the only possible
// same-address read-during-write collision (take at edge T reading the
// address that the previous pixel's write commits at the same edge) --
// raster addresses are strictly +1 inside a frame, so that collision can
// only occur between consecutive takes of identical address (1x1 frames
// or malformed SOF sequences).  Forwarding also makes the RTL insensitive
// to read-old vs write-through BSRAM collision behaviour.
//
// Seeding: after reset, after a reset-policy scene change, or after a
// committed geometry change, bg_valid=0 and the next frame is a *seed*
// frame: ref' := cur per pixel, diff is forced to 0 (masks are all-zero,
// mode-1 output is cur).  bg_valid sets at the frame's last pixel.
// Uninitialised RAM never reaches an output.
//
// Scene change: per frame, chg = #{pixels with diff > thresh} (0 while
// seeding).  At the last pixel, if (chg << 7) > npix*cfg_scn the frame is
// declared a scene change (cfg_scn in 0..128 units of 1/128; 128 disables
// detection), scn_event pulses, and cfg_scpol selects recovery:
//   0 RESET      : bg_valid := 0 -> the next frame re-seeds (silent masks)
//   1 FAST_ADAPT : next frame updates with alpha_eff = 0 (ref' := cur)
//                  while still emitting real diffs vs the old reference.
// scn_event pulses once per detected frame.  The decision and the policy
// field belong to the ending frame's committed configuration; the effect
// (bg_valid / fa) applies to the following frame.
//
// Configuration: cfg_valid/cfg_ready bundle {width,height,mode,thresh,
// alpha,scn,scpol}; an accepted legal bundle is pending and commits
// atomically at the next accepted SOF pixel -- the SOF pixel itself
// already sees the new config.  cfg_ready drops while a bundle is pending
// so two bundles can never mix.  cfg_done pulses on a legal accept,
// cfg_error on rejection, never both.  Illegal: width/height == 0 or
// > MAX_W/MAX_H, mode > 2, scn > 128.  A commit whose W/H differ from
// the active geometry clears bg_valid (the next frame re-seeds) so stale
// geometry references can never produce diffs.
//
// Markers: tuser=SOF at (0,0), tlast=EOL at x=W-1, checked on every
// accepted pixel; violations pulse o_error and do not resynchronise.
// Single clk, low-active synchronous rst_n; reset clears valid/control
// and drops in-flight pixels; the RAM is never cleared.
// ============================================================================
module framediff_stream #(
    parameter BITS = 8,                    // pixel width: 8 or 10
    parameter MAX_W = 128,                 // maximum frame width  1..8191
    parameter MAX_H = 128,                 // maximum frame height 1..8191
    // Derived widths; override only to mirror the formulas.
    parameter FP  = (MAX_W < 1 || MAX_H < 1) ? 1 : MAX_W * MAX_H,
    parameter CWX = (MAX_W < 1) ? 1 : $clog2(MAX_W + 1),
    parameter CWY = (MAX_H < 1) ? 1 : $clog2(MAX_H + 1),
    parameter FW  = (FP < 2) ? 1 : $clog2(FP + 1),
    parameter AW  = (FP < 2) ? 1 : $clog2(FP)
)(
    input  wire clk, rst_n,
    // Pixel stream: tuser = SOF (0,0), tlast = EOL.
    input  wire [BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    // Output stream: mask (0 / all-ones) or background value, same markers.
    output reg  [BITS-1:0] m_tdata,
    output reg  m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    // Atomic configuration bundle; commits at the next SOF take.
    input  wire cfg_valid, output wire cfg_ready,
    input  wire [CWX-1:0] cfg_width,
    input  wire [CWY-1:0] cfg_height,
    input  wire [1:0]  cfg_mode,          // 0 DIFF, 1 BG, 2 MOTION
    input  wire [BITS-1:0] cfg_thresh,
    input  wire [3:0]  cfg_alpha,         // background step 2^-alpha, 0..15
    input  wire [7:0]  cfg_scn,           // change threshold, units of 1/128
    input  wire        cfg_scpol,         // 0 RESET, 1 FAST_ADAPT
    output reg  cfg_done, cfg_error,
    output reg  o_error,                  // stream marker violation pulse
    output reg  scn_event,                // scene-change detection pulse
    output wire busy
);
    localparam [BITS-1:0] MPX = {BITS{1'b1}};

    // ---------------- active / pending scalar configuration ---------------
    reg [CWX-1:0]  a_w;
    reg [CWY-1:0]  a_h;
    reg [1:0]      a_mode;
    reg [BITS-1:0] a_thr;
    reg [3:0]      a_al;
    reg [7:0]      a_scn;
    reg            a_pol;
    reg [23:0]     a_scmp;   // npix * scn of the committed configuration
    reg            a_valid;  // a_* holds a committed configuration

    reg [CWX-1:0]  p_w;
    reg [CWY-1:0]  p_h;
    reg [1:0]      p_mode;
    reg [BITS-1:0] p_thr;
    reg [3:0]      p_al;
    reg [7:0]      p_scn;
    reg            p_pol;
    reg            pend_valid;

    // ---------------- stream position / frame bookkeeping ------------------
    reg [CWX-1:0] x;
    reg [CWY-1:0] y;
    reg in_frame;
    reg [AW-1:0] fi;        // raster index of the next take
    reg bg_valid;           // reference RAM holds a complete frame
    reg fa;                 // fast-adapt frame in progress (alpha_eff = 0)
    reg [FW-1:0] chg;       // changed-pixel count, current frame

    // ---------------- reference RAM (synchronous read) ----------------------
    // No ram_style attribute: measured 2026-10-03, yosys already chooses 8x DPB
    // for the 1024-pixel default geometry with or without "block", but at the
    // rate-harness geometry (4x4 = 16 entries) the attribute forced a 128-bit
    // array into an 18 Kb DPX9B.  Block RAM is the one part of a board image
    // nothing in this flow can simulate - OSS CAD's Gowin deck declares DPX9B
    // and SDPX9B as empty black boxes - so pinning it there made the silicon
    // divergence unauditable.  Left to the tool the small array maps to
    // RAM16SDP4, which the deck does model.
    reg [BITS-1:0] ref_ram [0:FP-1];
    reg [BITS-1:0] rd;

    // ---------------- stage-1 pipeline registers ---------------------------
    reg v1;
    reg [BITS-1:0] s1_pix;
    reg [AW-1:0]   s1_addr;
    reg            s1_u, s1_l, s1_eot;

    // committed-write forwarding record (same-address read/write collision)
    reg          wr_v;
    reg [AW-1:0]   wr_addr;
    reg [BITS-1:0] wr_data;

    // ---------------- constant shift-add multiplies (never a DSP) ----------
    function [23:0] mul_npix;               // width * height, <= 65536
        input [CWX-1:0] a;
        input [CWY-1:0] b;
        integer k;
        reg [23:0] acc;
        begin
            acc = 24'd0;
            for (k = 0; k < CWY; k = k + 1)
                if (b[k]) acc = acc + ({{(24-CWX){1'b0}}, a} << k);
            mul_npix = acc;
        end
    endfunction
    function [23:0] mul_scn;                // npix * scn, <= 2^23
        input [16:0] a;
        input [7:0]  b;
        integer k;
        reg [23:0] acc;
        begin
            acc = 24'd0;
            for (k = 0; k < 8; k = k + 1)
                if (b[k]) acc = acc + ({7'd0, a} << k);
            mul_scn = acc;
        end
    endfunction
    wire [23:0] p_npix_w = mul_npix(p_w, p_h);
    wire [23:0] p_scmp_w = mul_scn(p_npix_w[16:0], p_scn);

    // ---------------- handshake ---------------------------------------------
    wire advance = !m_tvalid || m_tready;
    assign s_tready  = rst_n && advance && (a_valid || pend_valid);
    wire  fire = s_tvalid && s_tready;
    wire  commit_edge = fire && s_tuser && pend_valid;
    assign cfg_ready = rst_n && (!pend_valid || commit_edge);
    assign busy = rst_n && (in_frame | v1 | m_tvalid | pend_valid);

    // Effective geometry for the accept cycle: a pending bundle takes
    // effect exactly at the SOF pixel it commits on.
    wire e_pick = s_tuser && pend_valid;
    wire [CWX-1:0] e_w = e_pick ? p_w : a_w;
    wire [CWY-1:0] e_h = e_pick ? p_h : a_h;

    wire [CWX-1:0] cx = s_tuser ? {CWX{1'b0}} : x;
    wire [CWY-1:0] cy = s_tuser ? {CWY{1'b0}} : y;
    wire [CWX-1:0] wlast = e_w - {{(CWX-1){1'b0}}, 1'b1};
    wire [CWY-1:0] hlast = e_h - {{(CWY-1){1'b0}}, 1'b1};
    wire rowend = s_tlast || (cx == wlast);
    wire eot    = rowend && (cy == hlast);
    wire [AW:0] fi_e = {1'b0, fi};
    // fi can only run past FP-1 on malformed (over-long) streams, which are
    // flagged via o_error; clamp keeps the address inside the RAM.
    wire [AW-1:0] caddr = s_tuser ? {AW{1'b0}} :
                         ((fi_e >= FP) ? {AW{1'b0}} : fi);

    // ---------------- stage-1 datapath (combinational) ----------------------
    wire [BITS-1:0] ref_v = (wr_v && (wr_addr == s1_addr)) ? wr_data : rd;
    wire signed [BITS:0] sdiff =
        $signed({1'b0, s1_pix}) - $signed({1'b0, ref_v});
    wire [BITS-1:0] adiff = sdiff[BITS]
        ? (~sdiff[BITS-1:0] + {{(BITS-1){1'b0}}, 1'b1}) : sdiff[BITS-1:0];
    wire [3:0] alpha_eff = fa ? 4'd0 : a_al;
    wire signed [BITS:0] step = sdiff >>> alpha_eff;
    wire signed [BITS:0] nbg  = $signed({1'b0, ref_v}) + step;
    // |step| <= |sdiff| keeps nbg inside [min(ref,cur), max(ref,cur)]; no
    // clamp is required.
    wire [BITS-1:0] new_ref = (!bg_valid || a_mode == 2'd0)
                              ? s1_pix : nbg[BITS-1:0];
    wire [BITS-1:0] adiff_e = bg_valid ? adiff : {BITS{1'b0}};
    wire moved = adiff_e > a_thr;
    wire [BITS-1:0] outpix = (a_mode == 2'd1) ? new_ref
                             : (moved ? MPX : {BITS{1'b0}});
    wire [FW-1:0] chg_next = s1_u ? {{(FW-1){1'b0}}, moved}
                                  : chg + {{(FW-1){1'b0}}, moved};
    wire [23:0] chg128 = {chg_next, 7'b0000000};
    wire scn_hit = chg128 > a_scmp;

    // ---------------- config legality ---------------------------------------
    wire cfg_bad = (cfg_width == {CWX{1'b0}}) || (cfg_height == {CWY{1'b0}})
        || (cfg_width > MAX_W[CWX-1:0]) || (cfg_height > MAX_H[CWY-1:0])
        || (cfg_mode > 2'd2) || (cfg_scn > 8'd128);

    // ---------------- sequential --------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            a_w <= {CWX{1'b0}}; a_h <= {CWY{1'b0}}; a_mode <= 2'd0;
            a_thr <= {BITS{1'b0}}; a_al <= 4'd0; a_scn <= 8'd0;
            a_pol <= 1'b0; a_scmp <= 24'd0; a_valid <= 1'b0;
            p_w <= {CWX{1'b0}}; p_h <= {CWY{1'b0}}; p_mode <= 2'd0;
            p_thr <= {BITS{1'b0}}; p_al <= 4'd0; p_scn <= 8'd0;
            p_pol <= 1'b0; pend_valid <= 1'b0;
            x <= {CWX{1'b0}}; y <= {CWY{1'b0}}; in_frame <= 1'b0;
            fi <= {AW{1'b0}};
            bg_valid <= 1'b0; fa <= 1'b0; chg <= {FW{1'b0}};
            rd <= {BITS{1'b0}};
            v1 <= 1'b0; s1_pix <= {BITS{1'b0}}; s1_addr <= {AW{1'b0}};
            s1_u <= 1'b0; s1_l <= 1'b0; s1_eot <= 1'b0;
            wr_v <= 1'b0; wr_addr <= {AW{1'b0}}; wr_data <= {BITS{1'b0}};
            m_tdata <= {BITS{1'b0}}; m_tvalid <= 1'b0;
            m_tuser <= 1'b0; m_tlast <= 1'b0;
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            o_error <= 1'b0; scn_event <= 1'b0;
        end else begin
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            o_error <= 1'b0;  scn_event <= 1'b0;
            // ---- marker check on every accepted pixel --------------------
            if (fire) begin
                if (s_tuser && in_frame)   o_error <= 1'b1; // SOF mid-frame
                if (!s_tuser && !in_frame) o_error <= 1'b1; // orphan pixel
                if (s_tlast && cx != wlast)  o_error <= 1'b1; // early EOL
                if (!s_tlast && cx == wlast) o_error <= 1'b1; // missing EOL
                rd <= ref_ram[caddr];
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
            end
            // ---- pipeline stage 1: reference write-back + output ---------
            if (advance) begin
                v1 <= fire;
                m_tvalid <= v1;
                wr_v <= v1;
                if (fire) begin
                    s1_pix  <= s_tdata;
                    s1_addr <= caddr;
                    s1_u    <= s_tuser;
                    s1_l    <= s_tlast;
                    s1_eot  <= eot;
                end
                if (v1) begin
                    ref_ram[s1_addr] <= new_ref;
                    wr_addr <= s1_addr;
                    wr_data <= new_ref;
                    chg <= chg_next;
                    m_tdata <= outpix;
                    m_tuser <= s1_u;
                    m_tlast <= s1_l;
                    if (s1_eot) begin
                        if (scn_hit) begin
                            scn_event <= 1'b1;
                            bg_valid  <= a_pol; // RESET(0) clears, FA keeps
                            fa        <= a_pol;
                        end else begin
                            bg_valid <= 1'b1;   // a full raster was written
                            fa <= 1'b0;
                        end
                    end
                end
            end
            // ---- pending->active commit at the SOF take --------------------
            // Placed after the stage-1 block so that a geometry change
            // committed at the *next* frame's SOF wins over this frame's
            // end-of-frame bg_valid set when both happen on the same edge.
            if (commit_edge) begin
                a_w <= p_w; a_h <= p_h; a_mode <= p_mode; a_thr <= p_thr;
                a_al <= p_al; a_scn <= p_scn; a_pol <= p_pol;
                a_scmp <= p_scmp_w;
                a_valid <= 1'b1; pend_valid <= 1'b0;
                if (!a_valid || p_w != a_w || p_h != a_h) bg_valid <= 1'b0;
            end
            if (cfg_valid && cfg_ready) begin
                if (cfg_bad) begin
                    cfg_error <= 1'b1;
                end else begin
                    p_w <= cfg_width; p_h <= cfg_height; p_mode <= cfg_mode;
                    p_thr <= cfg_thresh; p_al <= cfg_alpha;
                    p_scn <= cfg_scn;   p_pol <= cfg_scpol;
                    pend_valid <= 1'b1; cfg_done <= 1'b1;
                end
            end
        end
    end

    // ---------------- static parameter contract ------------------------------
    initial begin
        if (BITS != 8 && BITS != 10)
            $fatal(1, "unsupported BITS (8 or 10)");
        if (MAX_W < 1 || MAX_W > 8191)
            $fatal(1, "unsupported MAX_W (1..8191)");
        if (MAX_H < 1 || MAX_H > 8191)
            $fatal(1, "unsupported MAX_H (1..8191)");
        if (FP < 1 || FP > 65536)
            $fatal(1, "unsupported MAX_W*MAX_H (must be <= 65536)");
    end
endmodule
