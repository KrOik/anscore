# units_feat.md — wave2 group C (feature/statistics, idx 10–14)

Stimulus: `w2_img_stim` 32×32, frame 0 (boost square x∈[6,9], y∈[5,10]).
Window units use `../imgwin_20k/src/win3x3_gen.v` (+`line_buf_ram.v`),
edge-replication clamp taps. All RAM goes through `w2_dpram` (T9).
Golden model: `tools/golden_feat.py` (independent; EXP digests are NOT
backfilled from sim — T1). TBs print `W2TB <TAG> PASS/FAIL` and dump the
raw byte stream to `sim/dump_<unit>.txt` (byte-identical to
`sim/golden_<unit>.txt` in all five units).

## Unit summary

| idx | TAG | module | EXP digest (golden) | TB result | LUT-class* | DFF | BSRAM | DSP |
|-----|-----|--------|---------------------|-----------|-----------|-----|-------|-----|
| 10 | HAR | `feat_harris`    | `AB859D8F` | PASS C=1104  | ~1335 | 155 | 4 | 0 |
| 11 | FST | `feat_fast`      | `E1DEB6B0` | PASS C=51281 | ~614  | 373 | 1 | 0 |
| 12 | LBP | `feat_lbp`       | `45C677F3` | PASS C=1104  | ~79   | 11  | 0 | 0 |
| 13 | HOG | `feat_hog`       | `0AB2FBF5` | PASS C=1104  | ~313  | 170 | 0 | 0 |
| 14 | INT | `img_integral`   | `18ED7B54` | PASS C=1069  | ~138  | 64  | 1 | 0 |

\* LUT-class ≈ LUT1–4 + ALU + MUX2_LUT5 from `yosys stat` (ALU occupies a
LUT slot on GW2A). All well under the 1500 LUT4 / 0-DSP per-unit target.

## idx10 HAR `feat_harris` — Harris corner score

- In: `win[71:0]`/`win_valid`/`new_line_out` (win3x3_gen contract).
  Out: `score_out[31:0]` (signed) + `flag_out` (8'h01/00) + `out_valid`,
  one output per input window (3-beat latency, in-order).
- Sobel gradients `gx,gy` (shift-add, ±1020), quantized `qx=gx>>>QSH`,
  `qy=gy>>>QSH` (QSH=7 → 4-bit signed, |q|≤8). Products `pxx,pyy,pxy`
  via 4×4 shift-add `mul4u`.
- Accumulation window = **causal 3×3** with edge replication:
  `S(y,x)=Σ_{i,j∈0..2} p[clamp(y-i)][clamp(x-j)]`. Vertical sums via two
  history rows in `w2_dpram`: `histA*` packs `{pxx[6:0],pyy[6:0]}` (W=14),
  `histB*` packs `pxy[7:0]` (W=8) → 4 BSRAM total. Row-0 clamp is
  write-propagated (`hist2[x]<=eff(p(y-1,x))`), so no X ever reaches the
  datapath. Horizontal sums via 2-tap shift regs + x<2 clamp muxes.
- `score = (Sxx·Syy − Sxy·Sxy) − ((Sxx+Syy)² >>> 5)` — k≈1/32≈0.031.
  Three shift-add multipliers (`mul10u` ×2, `mul11u` ×1) — no `*`
  operator anywhere → 0 DSP.
- `flag = (score > THRESH)`, THRESH=500 (golden: 472/1024 flags set,
  score range [−1796, 13499]).
- Width note: internal widths are sized for QSH=7; other QSH values need
  the product/sum widths re-checked (see module header).
- Emit bytes/pixel: score[7:0], [15:8], [23:16], [31:24], flag.

## idx11 FST `feat_fast` — FAST corner detector (N=9, T=24)

- Two-phase core: `pix`/`pix_valid`/`new_line` capture into internal
  frame `w2_dpram` (W=8, DEPTH=1024), then `start` runs `w2_win_rd`
  (K=7) over all 1024 pixels (per-tap clamp borders).
- Circle taps inside the 7×7 window (indices 3,4,12,20,27,34,40,46,45,
  44,36,28,21,14,8,2) packed into a 128-bit ring.
- **Serial** ring scan: 33 beats per window (tap `i mod 16` over the
  doubled ring 0..31, saturating run counters for bright `circ>c+T` and
  dark `circ+T<c`) — fits inside the reader's 49+2-beat window cadence,
  uses ONE comparator instead of 32 (a fully-parallel version blew the
  LUT budget: ~1950 vs ~614 LUT-class serialized).
- Emit per pixel: `flag_out` (8'h01/00) then `arc_out` (max run 0..16).
  Corner = bright-run ≥ N OR dark-run ≥ N. Golden: 325/1024 corners @T=24.
- `done` rises after the last window's emit (tracks `w2_win_rd.done`).

## idx12 LBP `feat_lbp` — local binary pattern + uniform flag

- Ring order clockwise from top-left: `w0 w1 w2 w5 w8 w7 w6 w3`;
  `code[i] = ring_i >= w4`. `uniform` = ring transition count ≤ 2.
- Emit per pixel: `code_out`, `uni_out` (8'h01/00). 1-beat latency,
  pure comb + regs. Trivial size.

## idx13 HOG `feat_hog` — 8×8-cell direction histogram, 4 bins

- Central difference per window: `dx=w5−w3`, `dy=w7−w1` (±255).
- Unsigned orientation: fold dx<0 (`u=|dx|`, `v=±dy`); `steep=(|v|≥u)`;
  `bin = steep ? (v<0 ? 2 : 1) : (v<0 ? 3 : 0)`.
  (Zero gradient lands in bin1 — documented, golden-identical.)
- One vote/pixel; four cell-column accumulators `{b3,b2,b1,b0}` (4×32-bit
  regs, no RAM) persist across the 8 rows of a band; emit `cell_bins` +
  `cell_valid` at `(x%8==7 && y%8==7)` → 16 cells/frame, row-major.
  Emit order b0..b3.

## idx14 INT `img_integral` — summed-area table

- `I(y,x) = pix + left + above − above_left`; previous integral row in
  ONE `w2_dpram` (W=18, DEPTH=32).
- **Width cap (documented):** stored row values are 18-bit. For
  32×32×8-bit input max I = 261120 < 2^18 → exact. Larger/denser frames
  wrap mod 2^18; a full-32-bit row would need two W=18 banks (not needed
  for the selftest geometry).
- `int_out`/`out_valid` lag `pix_valid` by one beat, 1:1 stream;
  `done` after last pixel. Row-0 RAM reads are masked to 0 (X-safe).
- Emit bytes/pixel: int_out[7:0], [15:8], [23:16], [31:24] (top bytes 0).

## Verification commands (from `cores/system/extended_library/`)

```bash
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:\
/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
python tools/golden_feat.py        # writes sim/golden_*.txt, prints digests

IMG="../imgwin_20k/src/win3x3_gen.v ../imgwin_20k/src/line_buf_ram.v"
iverilog -g2012 -I src -o sim/tb_st_feat_lbp.vvp -s tb_st_feat_lbp \
    sim/tb_st_feat_lbp.v src/feat_lbp.v src/st_feat_lbp.v \
    src/w2_img_stim.v src/w2_dpram.v $IMG sim/gowin_bsram_sim.v
vvp sim/tb_st_feat_lbp.vvp          # -> W2TB LBP PASS D=45c677f3
# (same pattern for feat_hog [+$IMG], img_integral, feat_harris [+$IMG],
#  feat_fast [+src/w2_win_rd.v, no $IMG])

yosys -p "read_verilog -sv src/<u>.v [deps]; synth_gowin -top <u>; stat"
```

iverilog evidence (all dumps `diff`-clean vs golden):

```
W2TB LBP PASS D=45c677f3 C= 1104
W2TB HOG PASS D=0ab2fbf5 C= 1104
W2TB INT PASS D=18ed7b54 C= 1069
W2TB FST PASS D=e1deb6b0 C=51281
W2TB HAR PASS D=ab859d8f C= 1104
```

## Known limits / notes

- `feat_harris`: causal (not centred) 3×3 score window; gradient quantized
  to 4-bit signed (QSH=7). k = 1/32 fixed. Widths assume QSH=7.
- `feat_fast`: requires the window reader's ≥33-beat-per-window cadence
  (true for `w2_win_rd` K=7 = 49+2 beats). IMG_W must be a power of two
  (w2_win_rd constraint). Capture phase must complete before `start`.
- `feat_hog`: IMG_W must be a multiple of 8; cell grid = (IMG_W/8) ×
  (IMG_H/8); counts ≤64 fit in each byte.
- `img_integral`: 18-bit row cap as documented above; for bigger
  frames split the row store into two W=18 banks.
- `feat_lbp`: none notable.
- All units: no DSP cells, all regs `clk_en`-gated, `===`/`!==` verdicts,
  golden digests from `tools/golden_feat.py` only.
