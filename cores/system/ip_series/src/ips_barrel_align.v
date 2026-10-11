// =============================================================================
// ips_barrel_align
// -----------------------------------------------------------------------------
// Spec (cores/system/ip_series/ip_series_spec.json, family "path"):
//   "64-bit barrel shifter and bit-offset aligner for unaligned word
//    extraction from a stream"
//
// FUNCTION
//   A WORD-aligned stream of 64-bit words arrives as `cur` (word n) and `nxt`
//   (word n+1).  The core extracts the 64 bits that start `amt` bit positions
//   away from the edge of `cur`, in one enabled clock:
//     fmode = {dir, rot}  (numeric select bits, NOT booleans)
//       00  shift/extract right : align = (cur >> amt) | (nxt << (64-amt))
//       01  rotate right        : align = (cur >> amt) | (cur << (64-amt))
//       10  shift left          : align = (cur << amt), low `amt` bits zero
//       11  rotate left         : align = (cur << amt) | (cur >> (64-amt))
//   `amt` is 0..MAXOFF (=7), i.e. full sub-byte (bit) de-alignment in both
//   directions; byte-level de-alignment belongs to the framing that feeds the
//   stream into `cur`/`nxt`.
//
// STRUCTURE (this is what keeps it inside the 340 LUT-class budget)
//   All four modes are ONE extract from a single 79-bit guard window, so the
//   direction and rotate selects cost guard-region muxes instead of extra
//   barrel stages:
//     win = { hi_guard[6:0], cur[63:0], lo_guard[7:0] }          (79 bits)
//     lo_guard = (dir & rot) ? cur[63:56] : 0      (rotate-left wrap)
//     hi_guard = rot ? cur[6:0] : nxt[6:0]         (refill / rotate-right wrap)
//     s = dir ? (PLACE - amt) : (PLACE + amt)      (PLACE = MAXOFF + 1 = 8)
//     align = win[s +: 64]     realised as the 4-stage cascade l3>l2>l1>l0
//   Right modes read win at s = 8..15 (hi_guard supplies the refill bits),
//   left modes at s = 1..8 (lo_guard supplies the zeros or the wrapped byte).
//   The cascade is written as explicit slices of shrinking width
//   (71, 67, 65, 64 muxes) because a dynamic part-select win[s +: 64] maps to
//   542..735 LUT-class cells in this flow while the explicit cascade needs 267.
//
// REPORTING (folded into the digest; the framing check is a checker output, it
//   does not steer the datapath)
//   drop_q   : the bit values that left the datapath this beat (MSB-aligned for
//              dir=1, LSB-aligned for dir=0, always zero in the rotate modes
//              because a rotate loses nothing).
//   drop_sticky / drop_beats : sticky flag and saturating count of lost beats.
//   mark_hits / mark_sticky  : `align[31:0]` is masked by MARK_MASK after
//              MARK_SHIFT and compared against the same field of MARK_VALUE;
//              hits saturate at 4'hF.  This is the frame-sync check.
//   pos_q    : the extract index s, echoed so the window geometry is visible.
//   cfg_error: sticky, set if amt exceeds the implemented MAXOFF.
//
// CLOCKING / RESET
//   Single clock domain.  All state lives in ONE synchronous
//   always @(posedge clk or negedge rst_n) block; every register in it,
//   including the sticky flags and the saturating counters, is written only
//   when clk_en is high, so a clk_en=0 cycle freezes the whole core.
//   rst_n is an active-LOW asynchronous reset that clears every register to
//   zero.  There is no memory array in this core, so no read port exists; the
//   datapath is purely combinational (win/cascade) feeding registers.
//   Latency: `align_q` for a stimulus applied on one enabled clock appears on
//   the next enabled clock, i.e. exactly one enabled-beat pipeline stage.
//
// PARAMETERS (defaults are the values the golden model and testbench use; they
//   are declared without an explicit `integer` keyword because the series
//   wrapper generator in tools/package_core.py only parses the bare
//   `parameter NAME = value` form)
//   WIDTH      datapath width, also the stream word width.
//   MAXOFF     highest bit offset implemented  = WIDTH/8 - 1.
//   PLACE      position of cur inside win       = MAXOFF + 1.
//   MARK_VALUE / MARK_SHIFT / MARK_MASK  framing-pattern field definition.
// =============================================================================
`timescale 1ns / 1ps

module ips_barrel_align #(
    parameter WIDTH      = 64,
    parameter MAXOFF     = WIDTH / 8 - 1,
    parameter PLACE      = MAXOFF + 1,
    parameter MARK_VALUE = 32'h5C1A_7E3D,
    parameter MARK_SHIFT = 0,
    parameter MARK_MASK  = 32'h0000_00FF
) (
    input  wire                clk,
    input  wire                clk_en,
    input  wire                rst_n,

    input  wire [WIDTH-1:0]    cur,
    input  wire [WIDTH-1:0]    nxt,
    input  wire [2:0]          amt,
    input  wire [1:0]          fmode,

    output reg  [WIDTH-1:0]    align_q,
    output reg  [3:0]          pos_q,
    output reg  [WIDTH/8-1:0]  drop_q,
    output reg                 drop_sticky,
    output reg  [3:0]          drop_beats,
    output reg  [3:0]          mark_hits,
    output reg                 mark_sticky,
    output reg                 cfg_error
);

    // ---- window geometry ----------------------------------------------------
    localparam integer DBITS    = WIDTH / 8;                  // 8
    localparam integer GUARD_LO = PLACE;                      // 8
    localparam integer GUARD_HI = MAXOFF;                     // 7
    localparam integer WIN_BITS = WIDTH + GUARD_LO + GUARD_HI; // 79
    localparam integer SBITS    = 4;

    localparam integer SH3 = WIDTH / 8;                       // 8
    localparam integer SH2 = WIDTH / 16;                      // 4
    localparam integer SH1 = WIDTH / 32;                      // 2
    localparam integer SH0 = WIDTH / 64;                      // 1
    localparam integer N3    = WIDTH + SH2 + SH1 + SH0;       // 71
    localparam integer N2    = WIDTH + SH1 + SH0;             // 67
    localparam integer N1    = WIDTH + SH0;                   // 65

    localparam [SBITS-1:0]  PLACE_V  = PLACE;
    localparam [SBITS-1:0]  MAXOFF_V = MAXOFF;

    wire dir = fmode[1];
    wire rot = fmode[0];

    // ---- guard window -------------------------------------------------------
    wire [GUARD_LO-1:0] blo_v = cur[WIDTH-1 -: GUARD_LO];
    wire [GUARD_LO-1:0] blo_m = (dir & rot) ? blo_v : {GUARD_LO{1'b0}};
    wire [GUARD_HI-1:0] bhi_v = rot ? cur[GUARD_HI-1:0] : nxt[GUARD_HI-1:0];
    wire [WIN_BITS-1:0] win   = {bhi_v, cur, blo_m};

    // ---- extract index ------------------------------------------------------
    wire [SBITS-1:0] amt4 = {1'b0, amt};
    wire [SBITS-1:0] s_r  = PLACE_V + amt4;
    wire [SBITS-1:0] s_l  = PLACE_V - amt4;
    wire [SBITS-1:0] s_v  = dir ? s_l : s_r;

    // ---- 4-stage aligner cascade ------------------------------------------
    wire [N3-1:0]    l3 = s_v[3] ? win[SH3 +: N3] : win[0 +: N3];
    wire [N2-1:0]    l2 = s_v[2] ? l3[SH2 +: N2] : l3[0 +: N2];
    wire [N1-1:0]    l1 = s_v[1] ? l2[SH1 +: N1] : l2[0 +: N1];
    wire [WIDTH-1:0] l0  = s_v[0] ? l1[SH0 +: WIDTH] : l1[0 +: WIDTH];

    // ---- dropped-bit masks (bit j set when the offset discards it) ---------
    wire [DBITS-1:0] dmask;
    wire [DBITS-1:0] lmask;
    genvar gj;
    generate
        for (gj = 0; gj < DBITS; gj = gj + 1) begin : g_msk
            localparam [SBITS-1:0] LIMV = gj;
            assign dmask[gj]            = (amt4 > LIMV);
            assign lmask[DBITS-1-gj]    = (amt4 > LIMV);
        end
    endgenerate

    wire [DBITS-1:0] drop_r = cur[DBITS-1:0]            & dmask;
    wire [DBITS-1:0] drop_l = cur[WIDTH-1 -: DBITS]     & lmask;
    wire [DBITS-1:0] drop_v = rot ? {DBITS{1'b0}} : (dir ? drop_l : drop_r);
    wire             drop_nz = (|drop_v);

    // ---- framing-pattern check ---------------------------------------------
    wire [31:0] aline  = l0[31:0];
    wire [31:0] afld   = (aline >> MARK_SHIFT) & MARK_MASK;
    wire [31:0] mval   = (MARK_VALUE >> MARK_SHIFT) & MARK_MASK;
    wire        mark_ok = (afld === mval);

    // ---- out-of-range offset ----------------------------------------------
    wire cfg_bad = (amt4 > MAXOFF_V);

    // ---- one clocked block, everything gated by clk_en ---------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            align_q     <= {WIDTH{1'b0}};
            pos_q       <= {SBITS{1'b0}};
            drop_q      <= {DBITS{1'b0}};
            drop_sticky <= 1'b0;
            drop_beats  <= 4'h0;
            mark_hits   <= 4'h0;
            mark_sticky <= 1'b0;
            cfg_error   <= 1'b0;
        end else if (clk_en) begin
            align_q     <= l0;
            pos_q       <= s_v;
            drop_q      <= drop_v;
            drop_sticky <= drop_sticky | drop_nz;
            mark_sticky <= mark_sticky | mark_ok;
            cfg_error   <= cfg_error | cfg_bad;
            if (drop_nz) begin
                if (drop_beats != 4'hF) drop_beats <= drop_beats + 4'h1;
            end
            if (mark_ok) begin
                if (mark_hits != 4'hF) mark_hits <= mark_hits + 4'h1;
            end
        end
    end

endmodule
