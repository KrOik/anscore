# wave2_ip_20k — Group G geometry/statistics/matching units (idx 15–19)

Agent G deliverables. Stimulus: `w2_img_stim` 32x32 (`pix`, fidx=0).
Golden: `tools/golden_geom.py` (Python, independent — all EXP values below
come ONLY from its output, T1). Verdicts use `===`/`!==` (T6); every
register is `clk_en`-gated (T2); all constant/variable multiplies are
shift-add — zero DSP slices everywhere (T4); all frame/bin storage goes
through `w2_dpram`/DPX9B (T9).

## Unit table

| idx | TAG | module         | EXP digest | TB result                             | cycles |
|-----|-----|----------------|------------|---------------------------------------|--------|
| 15  | SCL | `img_scaler`   | `A34F3413` | `W2TB SCL PASS D=a34f3413 C=11574`    | 11574  |
| 16  | HST | `img_histogram`| `F14561DD` | `W2TB HST PASS D=f14561dd C= 2343`    | 2343   |
| 17  | CLA | `hist_clahe`   | `A267A0F3` | `W2TB CLA PASS D=a267a0f3 C=12644`    | 12644  |
| 18  | SAD | `match_sad`    | `A661F628` | `W2TB SAD PASS D=a661f628 C=43565`    | 43565  |
| 19  | CRP | `img_crop`     | `450E7855` | `W2TB CRP PASS D=450e7855 C= 1062`    | 1062   |

TB dump files `sim/dump_<unit>.txt` are byte-identical (`diff` clean) to
`sim/golden_<unit>.txt` for all five units.

## Interfaces

All units share the imgwin-style input contract (`pix`, `pix_valid`,
`new_line`) and emit `pix_out`/`out_valid` (+ `new_line_out` where the
output is a 2-D image) plus a latching `done`.

### `img_scaler` (SCL) — bilinear rescaler
`#(IMG_W=32, IMG_H=32, OUT_W=16, OUT_H=16)`; STX/STY are elaboration
constants `(DIM*256)/OUT_DIM` in Q8.

- Frame is stored in one `w2_dpram` (1024x8), then each output pixel takes
  8 beats: 4 neighbour reads (registered DO → one tap per beat) + 3 shared
  signed×unsigned shift-add multiplier beats (`mulsu`, time-muxed over
  `top`, `bot`, `res` lerps) + emit.
- Source coordinates are *accumulated* (`sx_acc += STX`), so no multiplier
  is needed for positions.
- Rounding: `out = clamp((res + 0x8000) >> 16)`. Neighbour column/row is
  clamped at the frame edge (`min(xi+1, W-1)`).
- Tested configuration: 32x32 → 16x16 downscale. Upscale also works
  (STX < 256 makes multiple outputs share neighbours) but is untested;
  `IMG_W*IMG_H <= 1024` and `IMG_W/IMG_H` must be powers of two.

### `img_histogram` (HST) — 256-bin histogram
`#(IMG_W=32, IMG_H=32)`; extra outputs `bins_ok`, `rdy`.

- Bins: one `w2_dpram` (W=18 counters × 256).
- `rdy` is high only in S_ACC; the `st_` cell holds the stim in reset until
  `rdy` (bin clear takes 256 beats first — RAM contents are X).
- **RMW hazard:** read issued at beat a → `q` usable at a+2 → write-back
  commits end of a+3. A depth-2 forwarding queue tagged with the 16-bit
  issue-beat handles pixels arriving on consecutive beats *and* with gaps
  (new_line beats): forwarding applies only when the beat distance is 1 or
  2.
- S_DRN re-reads bins 0..255, emits `{count[7:0], count[15:8]}` per bin
  and writes 0 back (clear-on-drain → re-usable without reset).
- Internal check: `bins_ok = (drained sum == IMG_W*IMG_H)`.

### `hist_clahe` (CLA) — simplified tile CLAHE
`#(IMG_W=32, IMG_H=32, CLIP=8)`; 4x4 grid of 8x8 tiles.

Simplifications vs full CLAHE (replicated verbatim in `golden_geom.py`):
- per-tile histogram has only **16 bins** (`pix>>4`), held in a flat
  16x8-bit register vector — no RAM hazard;
- clipped-out mass is **not redistributed**: `clip=min(h,CLIP)` then the
  CDF is normalised by `S = sum(clipped)` ("clip + renormalise" variant);
- `LUT[i] = min(255, floor(cdf*255/S))` via an unrolled restoring divider
  (no `/` operator, no DSP);
- apply pass blends the 4 nearest tile-centre LUTs with **3-bit**
  fractions: `x<4` → column of tile 0 only, `x>=28` → tile 3 only, else
  `fx=(x-4)&7` between tiles `(x-4)>>3` and +1 (same for y);
- one shared `mulsu` shift-add multiplier does all three lerps.
- Storage: frame RAM (1024x8) + LUT RAM (256x8, addr `{tile,bin}`).

### `match_sad` (SAD) — 8x8 template match
`#(IMG_W=32, IMG_H=32, TS=8)`; template load port `t_we/t_addr/t_data`,
kick-off input `go`, results `best_x/best_y/min_sad`.

- Frame RAM (1024x8) + template RAM (64x8).
- After `go` (one `clk_en` beat **after** the frame is ingested — the cell
  delays `stim_done` by one beat because `w2_img_stim` raises it during
  the last `pix_valid` beat), all 25x25 candidate origins are scanned
  row-major: 64 paired reads per candidate, `sad += |fq-tq|`.
- Emits `{sad_lo, sad_hi}` per candidate, then `{best_x, best_y,
  min_lo, min_hi}`; `done` latches. Min tracking uses strict `<` →
  first (top-left) minimum wins.
- Cell loads the template = stim formula evaluated at patch origin
  (10,9) → golden best = (10,9), min_sad = 0.

### `img_crop` (CRP) — ROI crop streamer
`#(IMG_W=32, IMG_H=32)`; ROI given as **input registers**
`x0,y0,cw,ch` (sampled combinationally — hold stable during the frame).

- Pass-through streamer: `new_line_out` on the beat after input
  `new_line` when the upcoming row intersects the ROI; `pix_out` for
  `x0 <= x < x0+cw` inside rows `y0 <= y < y0+ch`.
- ROI clipped automatically at the image edge; requires `cw,ch >= 1`.
- Cell uses ROI (x0,y0,cw,ch) = (5,7,13,9) → 13x9 = 117 pixel bytes;
  `new_line_out` beats carry no folded byte.
- No RAM (pure streaming unit).

## synth_gowin stats (yosys, core top only)

`LUT-class` = LUT1+LUT2+LUT3+LUT4+MUX2_LUT5+ALU (all occupy LUT4 sites).

| unit            | LUT-class                     | DFF | BSRAM (DPX9B) | DSP |
|-----------------|-------------------------------|-----|---------------|-----|
| `img_scaler`    | 565 (303 LUT + 14 MUX5 + 248 ALU) | 133 | 1 | 0 |
| `img_histogram` | 313 (178 LUT + 26 MUX5 + 109 ALU) | 255 | 1 | 0 |
| `hist_clahe`    | 1353 (856 LUT + 44 MUX5 + 453 ALU) | 315 | 2 | 0 |
| `match_sad`     | 256 (156 LUT + 13 MUX5 + 87 ALU)  | 129 | 2 | 0 |
| `img_crop`      | 109 (27 LUT + 1 MUX5 + 81 ALU)    | 24  | 0 | 0 |

All five are under the ~1500 LUT4 budget; `hist_clahe` is the largest
(flat 16x8-bin register histogram + restoring divider dominate).

## Commands (from project root, oss-cad-suite on PATH)

```
python tools/golden_geom.py                      # writes sim/golden_<u>.txt
iverilog -g2012 -I src -o sim/tb_st_<u>.vvp -s tb_st_<u> \
  sim/tb_st_<u>.v src/<u>.v src/st_<u>.v src/w2_img_stim.v \
  src/w2_dpram.v sim/gowin_bsram_sim.v
vvp sim/tb_st_<u>.vvp
yosys -p "read_verilog -sv src/<u>.v src/w2_dpram.v; synth_gowin -top <u>; stat"
```

(`<u>` ∈ `img_scaler img_histogram hist_clahe match_sad img_crop`;
`img_crop` needs no `w2_dpram` but including it is harmless.)

## Known limitations

- `img_scaler`: powers-of-two input dims, ≤1024 pixels, one frame per
  reset; upscale path untested.
- `img_histogram`: source must not stream while `rdy` is low (256-beat
  bin clear after reset).
- `hist_clahe`: fixed 32x32/4x4-tile geometry; 16-level bins; clip mass
  renormalised rather than redistributed; 3-bit interpolation fractions.
- `match_sad`: fixed 8x8 template, ≤1024-pixel frames, one `go` per
  reset; `go` must pulse after frame ingest (see SAD note above).
- `img_crop`: `x0..ch` are static registers, not per-frame parameters.
