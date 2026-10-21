`timescale 1ns / 1ps
// tb_ips_barrel_align : production-line testbench for the 64-bit aligner.
//
// 208 deterministic beats, one enabled clock per beat, walking the shipped
// geometry (WIDTH = 64, MAXOFF = 7, PLACE = 8, MARK_VALUE = 32'h5C1A_7E3D,
// MARK_SHIFT = 0, MARK_MASK = 32'h0000_00FF) through the cases that define it:
//   P0  0..15    shift/extract right, amt sweeps 0..7 over a real 2-word stream
//   P1  16..31   rotate right, amt sweeps 7..0
//   P2  32..47   shift left, amt sweeps 0..7
//   P3  48..63   rotate left, amt sweeps in 3-step order
//   P4  64..79   all four fmode values interleaved
//   P5  80..95   right-mode drop sensitivity: one set bit, offset sweeps past it
//   P6  96..111  framing marks: 8 beats that must hit the MARK field, 8 that must
//                not, so mark_hits / mark_sticky are live
//   P7  112..127 left-mode drop sensitivity: bit at 63-k, offset 7-k
//   P8  128..143 clk_en = 0 with live stimulus (whole core must freeze)
//   P9  144..159 right/left pass resumed (proves P8 was inert)
//   P10 160..175 cur = all ones, nxt = 0, amt = 7, every mode (max offset)
//   P11 176..191 cur = 0, nxt = all ones (only the hi-guard refill can appear)
//   P12 192..207 rotate-right tail sweep, settled readback
// The aligner is checked against ealign()/edrop()/epos() written straight from
// the spec (word pair shift, rotate-by-split, index = PLACE +/- amt), which is a
// different formulation from the core's shrinking-width cascade.  drop_beats,
// mark_hits and the sticky flags are folded but deliberately NOT compared, so a
// change of MARK_VALUE / MARK_SHIFT / MARK_MASK moves the digest instead of
// turning the run into a build failure.  align_q is observed on a wire four bits
// wider than the port, and the headroom nibble is folded too, so a WIDTH change
// shows up in the digest rather than being truncated away.  Every output is
// X-checked with === each beat (docs/IP_CORE_SOP.md trap T6).  The expected
// stream is NOT written here: models/ips_barrel_align.py computes it
// independently and the gate compares the two digests (trap T1).
module tb_ips_barrel_align;

`include "ips_tb_common.vh"

localparam integer WIDTHB = 64;
localparam integer PLACEB = 8;
localparam integer NBEATS = 208;
localparam integer S_P0   = 0;
localparam integer S_P1   = 16;
localparam integer S_P2   = 32;
localparam integer S_P3   = 48;
localparam integer S_P4   = 64;
localparam integer S_P5   = 80;
localparam integer S_P6   = 96;
localparam integer S_P7   = 112;
localparam integer S_P8   = 128;
localparam integer S_P9   = 144;
localparam integer S_P10  = 160;
localparam integer S_P11  = 176;
localparam integer S_P12  = 192;
localparam [7:0]   MARKB  = 8'h3D;

reg                 clk_en;
reg                 rst_n;
reg  [65:0]         cur;
reg  [65:0]         nxt;
reg  [2:0]          amt;
reg  [1:0]          fmode;

wire [67:0]         align_q;
wire [3:0]          pos_q;
wire [9:0]          drop_q;
wire                drop_sticky;
wire [3:0]          drop_beats;
wire [3:0]          mark_hits;
wire                mark_sticky;
wire                cfg_error;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the configuration the manifest records.
ips_barrel_align dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .cur         (cur),
    .nxt         (nxt),
    .amt         (amt),
    .fmode       (fmode),
    .align_q     (align_q),
    .pos_q       (pos_q),
    .drop_q      (drop_q),
    .drop_sticky (drop_sticky),
    .drop_beats  (drop_beats),
    .mark_hits   (mark_hits),
    .mark_sticky (mark_sticky),
    .cfg_error   (cfg_error)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// Stream word n of the framing that feeds cur / nxt.
function [63:0] swrd;
    input [15:0] k;
    reg   [31:0] lo;
    reg   [31:0] hi;
    begin
        lo = ({16'd0, k} * 32'h0101_7A57) ^ 32'h9E37_79B9;
        hi = ({16'd0, k} * 32'hC2B2_AE3D) ^ 32'h85EB_CA6B;
        swrd = {hi, lo};
    end
endfunction

// Aligned word, straight from the spec sentence.
function [63:0] ealign;
    input  [63:0] c;
    input  [63:0] n;
    input  [2:0]  a;
    input  [1:0]  fm;
    reg    [71:0] p;
    reg    [6:0]  la;
    begin
        la = 7'd64 - {4'd0, a};
        case (fm)
            2'd0:    ealign = (({8'd0, n[6:0], c}) >> a);
            2'd1:    ealign = (c >> a) | (c << la);
            2'd2:    ealign = c << a;
            default: ealign = (c << a) | (c >> la);
        endcase
    end
endfunction

// Bits the datapath gave up this beat; a rotate gives up nothing.
function [7:0] edrop;
    input  [63:0] c;
    input  [2:0]  a;
    input  [1:0]  fm;
    reg    [7:0]  m;
    begin
        case (a)
            3'd0:    m = 8'h00;
            3'd1:    m = 8'h01;
            3'd2:    m = 8'h03;
            3'd3:    m = 8'h07;
            3'd4:    m = 8'h0F;
            3'd5:    m = 8'h1F;
            3'd6:    m = 8'h3F;
            default: m = 8'h7F;
        endcase
        if (fm[0]) begin
            edrop = 8'h00;
        end else if (fm[1]) begin
            edrop = c[63:56] & {m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7]};
        end else begin
            edrop = c[7:0] & m;
        end
    end
endfunction

// Extract index the window geometry implies.
function [3:0] epos;
    input  [2:0] a;
    input  [1:0] fm;
    begin
        epos = fm[1] ? (PLACEB - {1'b0, a}) : (PLACEB + {1'b0, a});
    end
endfunction

integer beat;
integer j;
integer k;
reg       fold_d;
reg       fold_q;
reg       bad;
reg       proc;
reg  [63:0] exp_al;
reg  [3:0]  exp_ps;
reg  [7:0]  exp_dr;
reg  [63:0] cur64;
reg  [63:0] msk64;

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    cur       = 66'd0;
    nxt       = 66'd0;
    amt       = 3'd0;
    fmode     = 2'd0;
    fold_d    = 1'b0;
    fold_q    = 1'b0;
    bad       = 1'b0;
    proc      = 1'b0;
    exp_al    = 64'd0;
    exp_ps    = 4'd0;
    exp_dr    = 8'h00;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (beat = 0; beat < NBEATS; beat = beat + 1) begin
        @(negedge ips_clk);

        // ---- observe what the access issued at the previous beat reported ----
        fold_q = fold_d;

        if ((^align_q) === 1'bx)        bad = 1'b1;
        if ((^pos_q) === 1'bx)          bad = 1'b1;
        if ((^drop_q) === 1'bx)         bad = 1'b1;
        if (drop_sticky === 1'bx)       bad = 1'b1;
        if ((^drop_beats) === 1'bx)     bad = 1'b1;
        if ((^mark_hits) === 1'bx)      bad = 1'b1;
        if (mark_sticky === 1'bx)       bad = 1'b1;
        if (cfg_error === 1'bx)         bad = 1'b1;

        if (fold_q) begin
            if (align_q[63:0] !== exp_al)                   bad = 1'b1;
            if (pos_q !== exp_ps)                           bad = 1'b1;
            if (drop_q[7:0] !== exp_dr)                     bad = 1'b1;
            ips_fnv_word(align_q[31:0]);
            ips_fnv_word(align_q[63:32]);
            ips_fnv_word({24'd0, align_q[67:64]});
            ips_fnv_word({28'd0, pos_q});
            ips_fnv_word({22'd0, drop_q[7:0]});
            ips_fnv_word({24'd0, mark_hits, drop_beats});
            ips_fnv_word({29'd0, cfg_error, mark_sticky, drop_sticky, 1'b0});
        end

        // ---- drive this beat's access ----
        fold_d = (beat >= 1);
        cur    = 66'd0;
        nxt    = 66'd0;
        amt    = 3'd0;
        fmode  = 2'd0;
        j      = 0;
        k      = 0;
        if (beat < S_P1) begin
            fmode = 2'd0;
            amt   = beat % 8;
            cur   = swrd(beat);
            nxt   = swrd(beat + 1);
        end else if (beat < S_P2) begin
            j     = beat - S_P1;
            fmode = 2'd1;
            amt   = 3'd7 - (j % 8);
            cur   = swrd(beat + 3);
            nxt   = swrd(beat + 4);
        end else if (beat < S_P3) begin
            j     = beat - S_P2;
            fmode = 2'd2;
            amt   = j % 8;
            cur   = swrd(beat + 7);
            nxt   = swrd(beat);
        end else if (beat < S_P4) begin
            j     = beat - S_P3;
            fmode = 2'd3;
            amt   = (j * 3) % 8;
            cur   = swrd(beat + 11);
            nxt   = swrd(beat + 5);
        end else if (beat < S_P5) begin
            j     = beat - S_P4;
            fmode = j % 4;
            amt   = (j * 5) % 8;
            cur   = swrd(beat);
            nxt   = swrd(beat + 1);
        end else if (beat < S_P6) begin
            j     = beat - S_P5;
            fmode = 2'd0;
            amt   = j % 8;
            k     = 7 - (j % 8);
            cur   = 64'h1 << k;
            nxt   = 64'd0;
        end else if (beat < S_P7) begin
            j     = beat - S_P6;
            fmode = 2'd0;
            amt   = j % 8;
            cur64 = swrd(beat);
            msk64 = ({56'd0, MARKB}) << (j % 8);
            if (j < 8) begin
                cur = (cur64 & ~msk64) | msk64;
            end else begin
                cur = cur64 & ~msk64;
            end
            nxt   = swrd(beat + 1);
        end else if (beat < S_P8) begin
            j     = beat - S_P7;
            fmode = 2'd2;
            amt   = 3'd7 - (j % 8);
            k     = j % 8;
            cur   = 64'h8000_0000_0000_0000 >> k;
            nxt   = swrd(beat + 2);
        end else if (beat < S_P9) begin
            clk_en = 1'b0;
            j      = beat - S_P8;
            fmode  = j % 4;
            amt    = (j * 7) % 8;
            cur    = swrd(beat + 13);
            nxt    = swrd(beat);
        end else if (beat < S_P10) begin
            clk_en = 1'b1;
            j      = beat - S_P9;
            fmode  = (j < 8) ? 2'd0 : 2'd2;
            amt    = j % 8;
            cur    = swrd(beat + 5);
            nxt    = swrd(beat + 6);
        end else if (beat < S_P11) begin
            j     = beat - S_P10;
            fmode = j % 4;
            amt   = 3'd7;
            cur   = 64'hFFFF_FFFF_FFFF_FFFF;
            nxt   = 64'd0;
        end else if (beat < S_P12) begin
            j     = beat - S_P11;
            fmode = (j < 8) ? 2'd0 : 2'd1;
            amt   = j % 8;
            cur   = 64'd0;
            nxt   = 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            j     = beat - S_P12;
            fmode = 2'd1;
            amt   = j % 8;
            cur   = swrd(beat + 17);
            nxt   = swrd(beat + 19);
        end

        // the core only moves on an enabled clock, so the expectation follows
        // the stimulus that is actually sampled
        proc = clk_en === 1'b1;
        if (proc) begin
            exp_al = ealign(cur[63:0], nxt[63:0], amt, fmode);
            exp_ps = epos(amt, fmode);
            exp_dr = edrop(cur[63:0], amt, fmode);
        end
    end

    // ---- observe the last beat, then the settled flags ----
    @(negedge ips_clk);
    fold_q = fold_d;

    if ((^align_q) === 1'bx)      bad = 1'b1;
    if ((^drop_q) === 1'bx)       bad = 1'b1;
    if (align_q[63:0] !== exp_al) bad = 1'b1;
    if (pos_q !== exp_ps)         bad = 1'b1;
    if (drop_q[7:0] !== exp_dr)   bad = 1'b1;
    if (drop_sticky !== 1'b1)     bad = 1'b1;
    if (cfg_error !== 1'b0)       bad = 1'b1;
    if (clk_en !== 1'b1)          bad = 1'b1;

    if (fold_q) begin
        ips_fnv_word(align_q[31:0]);
        ips_fnv_word(align_q[63:32]);
        ips_fnv_word({24'd0, align_q[67:64]});
        ips_fnv_word({28'd0, pos_q});
        ips_fnv_word({22'd0, drop_q[7:0]});
        ips_fnv_word({24'd0, mark_hits, drop_beats});
        ips_fnv_word({29'd0, cfg_error, mark_sticky, drop_sticky, 1'b0});
    end

    ips_fnv_word(align_q[31:0]);
    ips_fnv_word(align_q[63:32]);
    ips_fnv_word({24'd0, align_q[67:64]});
    ips_fnv_word({28'd0, pos_q});
    ips_fnv_word({22'd0, drop_q[7:0]});
    ips_fnv_word({24'd0, mark_hits, drop_beats});
    ips_fnv_word({29'd0, cfg_error, mark_sticky, drop_sticky, 1'b0});
    ips_fnv_word(NBEATS);

    ips_verdict(!bad, "ips_barrel_align");
end

endmodule
