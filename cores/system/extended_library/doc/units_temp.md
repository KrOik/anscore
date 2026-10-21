# wave2_ip_20k — Group E unit record (idx20..24, temporal analysis + CCL)

Agent E.  All digests produced by `tools/golden_temp.py` (independent Python
model, trap T1) — EXP constants in `src/st_*.v` were filled from its output
*before* any simulation comparison.  Verdicts use `===`/`!==` (T6); every
register is `clk_en` gated (T2); no multipliers anywhere (T4-safe); all
storage goes through `w2_dpram` (T9).

Stimulus everywhere is `w2_img_stim` 32x32 (base formula +
moving 4x6 bright square, `+8'h50` boost).  Note the stimulus quirk
handled inside the DUTs: `fidx` increments on the edge that produces a
frame's *last* pixel, so frame counting is done with internal
completed-frame counters, never the raw `fidx` value.

## Verification evidence (iverilog -g2012, run from project root)

```
iverilog -g2012 -I src -o sim/tb_st_<u>.vvp -s tb_st_<u> \
    sim/tb_st_<u>.v src/<u>.v src/st_<u>.v src/w2_dpram.v \
    src/w2_img_stim.v sim/gowin_bsram_sim.v
vvp sim/tb_st_<u>.vvp
```
(tb_st_mot_bbox additionally needs `src/frame_diff.v` — the cell feeds the
DUT through the FDIF mask generator.)

Results:

```
W2TB FDIF PASS D=6a760ebd C= 3175
W2TB BGS  PASS D=17cd4105 C= 5257
W2TB BBOX PASS D=221b2f39 C= 3182
W2TB CCL  PASS D=84ea8e24 C= 6659
W2TB PRJ  PASS D=1dbd11e7 C= 1190
```

`cmp sim/dump_<u>.txt sim/golden_<u>.txt` — identical for all 5
(byte-for-byte output stream match, not just digest equality).

Golden files written by `tools/golden_temp.py` (also prints
`TAG DIGEST=XXXXXXXX` lines): `sim/golden_{frame_diff,bg_model,mot_bbox,
ccl_bbox,meas_proj}.txt` = 2048/2048/12/282/128 bytes.

## Unit table

| idx | TAG  | module     | EXP digest | bytes | LUT-class | DFF | BSRAM | DSP |
|-----|------|------------|------------|-------|-----------|-----|-------|-----|
| 20  | FDIF | frame_diff | 6A760EBD   | 2048  | ~57       | 60  | 1     | 0   |
| 21  | BGS  | bg_model   | 17CD4105   | 2048  | ~130      | 61  | 1     | 0   |
| 22  | BBOX | mot_bbox   | 221B2F39   | 12    | ~241      | 112 | 0     | 0   |
| 23  | CCL  | ccl_bbox   | 84EA8E24   | 282   | ~550      | 132 | 5     | 0   |
| 24  | PRJ  | meas_proj  | 1DBD11E7   | 128   | ~1362     | 1077| 0     | 0   |

LUT-class = LUT1..4 + MUX2_LUT5 + ALU from `synth_gowin -top <u>; stat`
(yosys 0.64+181, GW2A).  All under the ~1500 LUT4 / 0 DSP budget; 0 DSP
everywhere.  `check` pass reports 0 problems on all five.

CCL note: an earlier register-array version of the equivalence/stats
tables synthesised to ~5.6K LUT4 — the shipped version keeps all five
tables (frame, labels, union {parent,root}, stats A, stats B) in
`w2_dpram` banks, which is also what T9 demands anyway.

## Interfaces

All five DUTs share the stream-contract inputs
`clk, clk_en, rst_n, pix[7:0], pix_valid, new_line, fidx[7:0]` and produce
`out_byte`/`mask_out[7:0] + out_valid + done`.  `fidx`/`new_line` are
accepted for contract uniformity even where unused (ccl_bbox, meas_proj).

### frame_diff #(IMG_W=32, IMG_H=32, N_FRAMES=3, THR=32)
```
pix,pix_valid,new_line,fidx -> mask_out, out_valid, nl_out, fidx_out, done
```
Previous frame held in one `w2_dpram` (W8 x NPIX).  Per pixel:
`mask = (|pix - prev| >= THR) ? 8'h01 : 8'h00` written back-to-back for the
last N_FRAMES-1 frames (frame 0 only primes the RAM — `have_prev` gate).
`nl_out`/`fidx_out` track the stream through the 1-beat RAM latency.

### bg_model #(IMG_W=32, IMG_H=32, N_FRAMES=4, ALPHA=4, THR=32)
```
pix,pix_valid,new_line,fidx -> out_byte, out_valid, done
```
Running average `bg += (pix - bg) >>> ALPHA` (signed shift, no multiplier),
background bytes in one `w2_dpram`.  After the last frame emits 1024
foreground-mask bytes (`|pix-bg| > THR`) then 1024 background bytes —
2048 total.

### mot_bbox #(IMG_W=32, IMG_H=32, NFR=2)
```
pix,pix_valid,new_line,fidx -> out_byte, out_valid, done
```
Consumes a binary mask stream (selftest wires `frame_diff` in front).
Per frame emits one 6-byte record `{minx,miny,maxx,maxy,count_lo,count_hi}`
in raster order; zeroed record if the frame had no fg pixels.  Final-pixel
bug class handled explicitly: the last pixel only extends the box when it
is actually foreground.

### ccl_bbox #(IMG_W=32, IMG_H=32, MAXLBL=63)
```
pix,pix_valid,new_line,fidx -> out_byte, out_valid, done
```
Two-pass 4-connectivity CCL on one 32x32 binary frame (`pix != 0` = fg;
selftest thresholds stim pixels `>=160`, giving 56 labels / 40 components
/ 26 union events — real equivalence activity, under the 63-label cap).
Five `w2_dpram` banks: frame, per-pixel labels, union table
`{parent,root}` (W12x64), stats A `{area,minx}` (W18x64), stats B
`{miny,maxx,maxy}` (W18x64).  Emits `[ncomp][ovf]` then per root label
(ascending) `label, area_lo, area_hi, minx, miny, maxx, maxy` — 7 bytes.
Documented simplifications: labels capped at 63 (fg needing label 64+ is
dropped, `ovf` set); pass-1 stalls while the serialized root chase runs;
single eq read port so the two chase cursors run sequentially.  Full
minimum-root union + path-compressed resolve IS implemented.

### meas_proj #(IMG_W=32, IMG_H=32)
```
pix,pix_valid,new_line,fidx -> out_byte, out_valid, done
```
One frame in, then emits 32 row sums followed by 32 column sums,
16 bits little-endian each (128 bytes).  Row/column accumulators are the
indexed register arrays that account for most of its ~1362 LUT-class —
still inside budget; a w2_dpram variant is a possible follow-up if the
global budget tightens.

## Known limits

- All units are single-frame-count, `start`-to-`done` selftest scope; no
  backpressure on inputs beyond `pix_valid` cadence.
- `meas_proj` sums saturate at 16 bits (max legal sum 255*32 = 8160, no
  wrap at 32x32x8-bit).
- `ccl_bbox` label capacity 63; overflow is reported in the `ovf` header
  byte rather than silently dropped.
- `bg_model` runs the recurrence only over `N_FRAMES` frames; it is not a
  continuously-adapting engine (restart the cell to re-seed).
