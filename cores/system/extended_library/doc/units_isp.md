# wave2_ip_20k — Group A ISP units (idx 0–5)

Agent A deliverables. Stimulus: `w2_img_stim` 32x32 (`pix` for the windowed
units, `pix24` for the RGB units). Golden: `tools/golden_isp.py`
(Python, independent — EXP values below come ONLY from its output, T1).
Verdicts use `===`/`!==` (T6); every register is `clk_en`-gated (T2);
all constant/variable multiplies are shift-add (T4); LUT RAMs go through
`w2_dpram`/DPX9B (T9).

## pix24 stimulus quirk (documented, replicated in golden)

`w2_img_stim.pix` is registered (the true pixel), but `pix24`/`fidx` are
combinational on the `x,y,fidx` counters, which have already advanced during
each `pix_valid` beat. Consequence for every RGB unit: the pix24 stream is
the raster **rotated left by one pixel** — beat i carries pixel i+1, and the
last beat of frame f carries pixel (0,0) of frame f+1 (of the same frame on
the last frame). `fidx` flips one beat early on that wrap beat, so
mode-selects keyed on `fidx` follow the *source* frame of the rotated pixel.
`golden_isp.py::pix24_seq()` models this verbatim; `st_` cells fold what the
DUT actually emits. (Shared file is read-only; noted here per SPEC.)

## Unit table

| idx | TAG | module | EXP digest | TB result | cycles |
|-----|-----|--------|------------|-----------|--------|
| 0 | DPC | `isp_dpc`      | `660DE1FA` | `W2TB DPC PASS D=660de1fa C=1102` | 1102 |
| 1 | DEM | `isp_demosaic` | `43C5DA1F` | `W2TB DEM PASS D=43c5da1f C=1102` | 1102 |
| 2 | AWB | `isp_awb`      | `AF39F01C` | `W2TB AWB PASS D=af39f01c C=2121` | 2121 |
| 3 | GAM | `isp_gamma`    | `61B5D82E` | `W2TB GAM PASS D=61b5d82e C=1321` | 1321 |
| 4 | CSC | `isp_csc`      | `CE41D92D` | `W2TB CSC PASS D=ce41d92d C=2121` | 2121 |
| 5 | GRY | `isp_rgb2gray` | `9D413162` | `W2TB GRY PASS D=9d413162 C=1065` | 1065 |

TB dump files `sim/dump_isp_<unit>.txt` are byte-identical (`diff` clean) to
`sim/golden_isp_<unit>.txt` for all six units.

## synth_gowin stats (yosys, core top only)

`LUT-class` = LUT1+LUT2+LUT3+LUT4+MUX2_LUT5+ALU (all occupy LUT4 sites).

| unit | LUT-class | DFF | BSRAM (DPX9B) | DSP |
|------|-----------|-----|---------------|-----|
| `isp_dpc`      | 399 (238 LUT + 161 ALU) | 10  | 0 | 0 |
| `isp_demosaic` | 190 (131 LUT + 16 MUX5 + 43 ALU) | 32 | 0 | 0 |
| `isp_awb`      | 949 (437 LUT + 2 MUX5 + 510 ALU) | 135 | 0 | 0 |
| `isp_gamma`    | 2   (28 DFF + 3 DPX9B only)      | 28  | 3 | 0 |
| `isp_csc`      | 835 (655 LUT + 53 MUX5 + 127 ALU) | 26 | 0 | 0 |
| `isp_rgb2gray` | 223 (180 LUT + 27 MUX5 + 16 ALU) | 10 | 0 | 0 |

Commands (from project root, oss-cad-suite on PATH):
```
iverilog -g2012 -I src -o sim/tb_st_isp_dpc.vvp -s tb_st_isp_dpc \
  sim/tb_st_isp_dpc.v src/isp_dpc.v src/st_isp_dpc.v src/w2_img_stim.v \
  ../imgwin_20k/src/win3x3_gen.v ../imgwin_20k/src/line_buf_ram.v sim/gowin_bsram_sim.v
vvp sim/tb_st_isp_dpc.vvp
# demosaic: same file list; awb/csc/rgb2gray: drop win3x3_gen+line_buf_ram;
# gamma: add src/w2_dpram.v
yosys -p "read_verilog -sv src/<u>.v [src/w2_dpram.v]; synth_gowin -top <u>; stat"
python tools/golden_isp.py
```

## Per-unit interfaces

### `isp_dpc` (idx 0) — defective pixel correction
`win[71:0], win_valid, new_line_out` in (imgwin window contract, edge
replication) → `pix_out, out_valid, nl_out`, 1-beat registered latency.
`med8 = (s3+s4)>>1` of the 8 sorted neighbours (Batcher odd-even 19-comparator
network, proven == sort in golden); `|c-med8| > THR` (param, 32 in selftest)
replaces centre with med8.

### `isp_demosaic` (idx 1) — Bayer RGGB → RGB888 bilinear
Same window stream in → `rgb_out[23:0], out_valid, nl_out`, 1-beat latency.
Bayer phase tracked internally (`new_line_out` must pulse at x==0 of each
output row; `IMG_W` param for the column counter). Averages truncate
(`>>1`, `>>2`). Fold order per pixel: R, G, B.

### `isp_awb` (idx 2) — gray-world auto white balance
`pix24, pix_valid, new_line` in → `pix24_out, out_valid, nl_out`, 1-beat
latency; `gain_r/gain_b[9:0]` observability outputs. **Documented policy:
next-frame application** — frame N accumulates sums (18-bit), means =
`sum>>10` (requires `IMG_W*IMG_H` = 2^k), gains `clamp((mean_g<<8)/mean_x,
10'h3FF)` latch one beat after the last pixel and apply from frame N+1
pixel 0. Frame 0 runs at reset gain 0x100 (identity). Selftest streams
N_FRAMES=2; fold = frame0 passthrough + frame1 corrected, {R',G,B'} per
pixel. Divider = unrolled 16-iter restoring shift/subtract; pixel*gain =
10-term shift-add; **no `*` anywhere**.

### `isp_gamma` (idx 3) — 256-entry gamma LUT
`lut_we/lut_addr[7:0]/lut_data[7:0]` write port (broadcasts to three
identical `w2_dpram` 256x8 banks = 3 BSRAM); `pix24,pix_valid,new_line` in →
`pix24_out,out_valid,nl_out` with **2-beat** latency (registered DOB + output
register; `out_valid = pix_valid` delayed 2). st cell loads the gamma-2.2
table from `sim/gamma_lut.mem` (written by `golden_isp.py`,
`lut[i]=round(255*(i/255)^(1/2.2))`) over 256 beats before streaming.

### `isp_csc` (idx 4) — RGB↔YCbCr (BT.601 full range, Q8)
`mode`=0 fwd {R,G,B}→{Y,Cb,Cr}, =1 inv {Y,Cb,Cr}→{R,G,B}; sampled per
`pix_valid`. Forward: `Y=(77R+150G+29B)>>8`, `Cb=(128B-43R-85G+32768)>>8`,
`Cr=(128R-107G-21B+32768)>>8` — all provably within [0,255], no clip.
Inverse: `R=clip(Y+((359·cri+128)>>>8))`, `G=clip(Y-((88·cbi+183·cri+128)>>>8))`,
`B=clip(Y+((454·cbi+128)>>>8))`, signed floor shifts. All coefficients are
shift-add constants. Selftest: 2 frames, `mode=fidx[0]` — fwd on frame 0,
inv on frame 1 (incl. the wrap beat where fidx leads). **Gotcha fixed in
development: an unsigned concat operand in a signed expression makes `>>>`
logical — all inverse-path operands are `signed`.**

### `isp_rgb2gray` (idx 5) — BT.601 luma
`pix24` in → `pix_out[7:0]` = `(77R+150G+29B)>>8` (coeffs sum to 256 → no
clip needed), 1-beat latency, shift-add only.

## Known limits / notes

- `isp_awb` requires `IMG_W*IMG_H` to be a power of two (mean = shift); sums
  sized for NP ≤ 1024 (extend `sum_*` width for larger frames).
- `isp_demosaic` needs `new_line_out` at each row's first window and a
  contiguous row-major window stream (win3x3_gen/w2_win_rd semantics).
- `isp_gamma` LUT write port shares port A only during load; streaming reads
  are port B — writes during streaming are legal (independent ports) but the
  selftest does not exercise mid-stream table updates.
- `isp_dpc`/`isp_demosaic` do not own RAMs; the window source
  (`win3x3_gen` + 2×`line_buf_ram` inside the st cell) supplies the 3x3 taps.
- RGB units inherit the `pix24` one-pixel-lead stream described above; any
  integration consuming `pix24` from `w2_img_stim` must account for it (or
  register `pix24` one beat to realign with `pix`).
- `st_isp_gamma` uses `$readmemh("sim/gamma_lut.mem")`; the file is generated
  by `tools/golden_isp.py` — regenerate before sim/synth if absent.
