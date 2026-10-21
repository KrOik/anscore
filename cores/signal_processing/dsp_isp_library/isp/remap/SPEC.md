# ISP-19 — Geometric Remapping (`remap_stream`)

Reusable ISP block that remaps an input frame by horizontal/vertical
flip, 90-degree rotation, affine transform, perspective transform, or a
runtime-loaded lens-distortion mesh, with bilinear sampling and
configurable out-of-bounds fill.

## Architecture: fill/drain, single frame buffer

General geometric remapping requires **random access** to the source
frame — affine/perspective/lens coordinates are arbitrary per output
pixel and cannot be covered by line buffers.  This core therefore uses
an honest two-phase pipeline:

```
FILL : s_* stream accepted at II=1; every pixel written into the
       internal frame RAM at its raster address.
DRAIN: s_tready drops at end-of-frame; for each output pixel the
       sequencer computes (sx,sy) in signed Q16, performs four
       sequential frame-RAM reads for the bilinear taps, accumulates
       p*w with one shared multiplier, rounds, and emits m_*.
```

* The two phases never overlap: a frame is stored completely before the
  first output pixel is generated.  There is **no ping-pong buffer** —
  frames are strictly serialised.  Overlapping fill/drain would require
  a second frame RAM (not implemented; see Limitations).
* The honest throughput contract is
  `N_in = in_w*in_h` fill cycles plus `≈ C_out * out_w*out_h` drain
  cycles where `C_out ≈ 13` (integer/affine/lens modes) and
  `≈ 2·59 + 13` for PERSP (two sequential divider passes).
  II=1 streaming is explicitly *not* claimed.

### Resources

One frame RAM `fram` (`FP = MAX_W*MAX_H` × `BITS`, default
128×128×8 = 131 072 bit) and two mesh RAMs `lram_x`, `lram_y`
(`LC = LXMAX*LYMAX` × 27 bit each; the 54-bit node word is split so both
arrays map onto Gowin 18/36-bit block-RAM port widths).  All ports are
single-clock synchronous; writes during FILL, reads during DRAIN.

## Streams and configuration

Single clock `clk`, low-active synchronous `rst_n`.  Input
`s_tdata/s_tvalid/s_tready/s_tuser(=SOF)/s_tlast(=EOL)`; output
`m_tdata/m_tvalid/m_tready/m_tuser/m_tlast` on the **output** raster
(SOF at output (0,0), EOL at `ox==out_w-1`).  `m_*` is a registered
held output — stable under backpressure (`D_EMIT` waits for
`m_tready`).

Input markers are checked on every accepted pixel (SOF mid-frame /
orphan pixel / early-EOL / missing-EOL each pulse `o_error` for one
cycle; the pixel is still committed — no resynchronisation attempt,
same contract as `framediff_stream`).

### Configuration bundle (320 bits, `cfg_valid`/`cfg_ready`)

| bits        | field                                        |
|-------------|----------------------------------------------|
| [12:0]      | `in_w`   (1..MAX_W)                          |
| [25:13]     | `in_h`   (1..MAX_H)                          |
| [38:26]     | `out_w`  (1..8191)                           |
| [51:39]     | `out_h`  (1..8191)                           |
| [54:52]     | `mode`   0=FLIPH 1=FLIPV 2=ROT90 3=AFFINE 4=PERSP 5=LENS |
| [56:55]     | `fill`   0=ZERO 1=BORDER 2=REPLICATE         |
| [66:57]     | `border` (10-bit field; **low `BITS` bits used**) |
| [71:67]     | `lx` mesh nodes/row (2..LXMAX)               |
| [76:72]     | `ly` mesh rows    (2..LYMAX)                 |
| [80:77]     | `kx` log2 mesh pitch x                       |
| [84:81]     | `ky` log2 mesh pitch y                       |
| [85+26k +:26] | `a_k` coefficients, signed Q9.16, k=0..8   |
| [319]       | `clr` clear mesh `written_bits` at accept    |

An accepted *legal* bundle becomes `pending` (`cfg_done` pulses) and
commits **atomically at the next accepted SOF pixel** — the SOF pixel
itself already belongs to the new configuration.  `cfg_ready` is low
while a bundle is pending, so two bundles can never interleave; a
bundle presented during the pending window can only be accepted on the
commit edge.  An accepted *illegal* bundle pulses `cfg_error` and is
dropped (no state change).

Illegal (→ `cfg_error`): any dim 0; `in_w>MAX_W`, `in_h>MAX_H`;
`mode>5`; `fill>2`; ROT90 with `out_w!=in_h || out_h!=in_w`; LENS with
`lx/ly` out of range, insufficient coverage
`(lx-1)<<kx < out_w-1` or `(ly-1)<<ky < out_h-1`, or unwritten mesh
nodes.  `border` has **no legality check** — only its low `BITS` bits
reach the sampler (upper bits truncate silently).

### Lens mesh write port

`l_valid/l_ready/l_row/l_col/l_data = {sy[53:27], sx[26:0]}` — both
fields signed Q11.16.  Accepted writes go straight into the mesh RAM
and set `written_bits[row*LXMAX+col]`; a LENS apply is legal only when
every node it can reference is covered.  Out-of-range `row/col` pulse
`l_error` and change nothing.  `clr=1` in an accepted bundle clears all
`written_bits` (use: apply(clr) → write nodes → apply).

`l_ready` is low only while a LENS drain is inside its mesh-read window
(`D_PIX` + `D_LN0..D_LN3`); writes run at up to 1/cycle at all other
times (including fills and non-lens drains).  **Contract:** all mesh
writes for a lens frame must be accepted before that frame's fill
completes — writes that land *during a lens drain* would race the read
window; `l_ready` deassertion prevents that in HW, but a test/source
must respect it (the reference TB holds cfg offers and source pixels
while a due mesh write is pending).

## Coordinate generation

All source coordinates are signed **Q16** integers in 42-bit
accumulators.  Output coordinates `ox,oy` are plain integers.

| mode  | equations |
|-------|-----------|
| FLIPH | `sx = in_w-1-ox`, `sy = oy` |
| FLIPV | `sx = ox`, `sy = in_h-1-oy` |
| ROT90 | `sx = oy`, `sy = in_h-1-ox` — 90° clockwise; requires `out_w==in_h`, `out_h==in_w` |
| AFFINE| `sx = a0·ox + a1·oy + a2`, `sy = a3·ox + a4·oy + a5` — evaluated incrementally (row base `+= a1/a4`, per pixel `+= a0/a3`), bit-exact vs. the closed form |
| PERSP | numerators as AFFINE, `d = a6·ox + a7·oy + a8`; `sx = RNE(nx·2^16/d)`, `sy = RNE(ny·2^16/d)` via shared `fp_div_iter` (`infra/fixedpoint/rtl/recip_div.sv`, AW=BW=42, FB=16, OUT_W=42); `d==0` saturates → OOB fill |
| LENS  | mesh nodes `{sy,sx}` Q16 at pitch `2^kx × 2^ky` output px; `i=min(ox>>kx, lx-2)`, `j=min(oy>>ky, ly-2)`; `fx=(remx<<8)>>kx` etc; bilinear node interp: `xt = n00x + ((n01x-n00x)·fx)>>8` … floor shifts |

Coefficient format: `a0..a8` signed 26-bit **Q9.16** (range
[−512, 512), step 2^-16).  42-bit accumulators keep
`|a·coord + …| < 2^41` for all legal inputs.

## Bilinear sampling and fill policy

Per pixel, `D_RB0` derives from `sx,sy`: `x0=floor(sx)`, tap column
`x1 = min(x0+1, in_w-1)` (index-clamped — the RAM never sees an
out-of-range address); OOB flags
`xo0 = sx OOB`, `xo1 = sx OOB || x0==in_w-1` (one-past-edge rule);
weights `wx1 = sx[15:8]`, `wx0 = 256-wx1` (sum exactly 256 per axis).

REPLICATE clamps the Q16 coordinate into `[0, dim-1]` before any of the
above (all OOB flags clear, weights from the clamped value).  For the
other fills an OOB tap contributes `0` (ZERO) or `border` (BORDER);
weights always sum to 2^16 so a fully-OOB pixel yields exactly
`border`/0.

Accumulation (one shared 28×17 shift-add multiplier, no DSP):
`acc = Σ tv_k·wx_k·wy_k`, `out = (acc + 2^15) >> 16`
(round-half-up; weights sum to 2^16 so the result never overflows the
pixel range — no saturation needed).

## Drain sequencer

`D_PIX` (coordinate gen; LENS also computes node indices and issues the
first mesh read) → `D_LN0..3` (mesh taps into `n00..n11`) →
`D_LI0..5` (node interpolation) → `D_RB0/D_RB1` (tap geometry + row
bases `rb0=ay0·in_w`, `rb1=ay1·in_w`) → `D_RD0..3` (four sequential
frame reads, weight products `wk`) → `D_AC0..3` (Σ p·w) → `D_FIN`
(loads output register + markers) → `D_EMIT` (waits `m_tready`;
advances ox/oy and the affine/perspective row bases).

Cycles per output pixel: integer modes 13, AFFINE 13, LENS 20
(`+4` mesh reads `+3` interp), PERSP ≈ 131 (two `fp_div_iter` passes ≈
59 cycles each).  So drain ≈ `out_w·out_h·C_out` cycles — the quoted
`N_in + M_out·C_out` contract.

## Static parameters / resource evidence

`BITS` ∈ {8,10}; `MAX_W,MAX_H` ∈ 1..8191 with `MAX_W·MAX_H ≤ 65536`
(frame RAM ≤ 64 Ki addresses); `LXMAX,LYMAX` ∈ 2..31.  `initial $fatal`
rejects anything else (sim-tested in `evidence/*/invalid_*`).

`yosys synth_gowin -top remap_synth_top` (no `-family`), core-only:

| BITS | MAX_W×MAX_H | mesh | LUT-class | FF | DSP(MULT9X9) | BSRAM | ALU |
|------|-------------|------|-----------|----|--------------|-------|-----|
| 8    | 128×128     | 17×17| 4248 | 2160 | 2 | 10 (8×DPB + 2×SDPX9B) | 2060 |
| 10   | 128×128     | 17×17| 4110 | 2176 | 2 | 12 | 2061 |
| 8    | 32×24       | 9×9  | 3575 | 1927 | 2 | 3  | 1971 |

(BSRAM: `fram` → DPB; `lram_x`,`lram_y` → SDPX9B.  LUT/DFF counts
exclude the RAM contents; ALU = carry-chain adders the mapper reports
separately from LUTs.)  Within the ≤15 K LUT / ≤4 DSP budget.

## Verified coverage (`tests/test_remap.py`)

Deterministic independent-model comparisons for flips, ROT90 (incl.
odd dims), affine translate/scale/shear/rotate-45°, perspective
(including d=0), lens identity/distorted/clr-reload, all three OOB
fill modes, 1×1 frames (commit==eot edge), 10-bit pixels; three
traffic epochs (full-rate, stalled sink, sparse source) plus a
mid-stream reset tail per case; four mutation classes (data, sideband,
ordering, count) proven to fail; illegal-bundle rejection incl. pending
window; illegal static params `$fatal`-checked; output-hold-under-stall
checked in TB.

## Limitations (explicit)

* **Serialised frames** — no overlap between fill and drain; a second
  frame buffer (ping-pong) would be needed for continuous frame-rate
  operation and is not implemented.
* Drain throughput is `≈13 cycles/pixel` (LENS 20, PERSP ≈131), not
  II=1 — arbitrary source access makes a line-buffer/pixel-rate
  architecture impossible for general affine/perspective/lens maps.
* Bilinear weights use the top 8 fraction bits of the Q16 coordinate —
  up to 1/256-pixel truncation error vs. a fully fractional weight
  (documented; matched bit-exactly by `models/model.py`).
* Mesh `lx/ly/kx/ky` coverage is enforced at APPLY; node *values* are
  not range-checked (Q11.16 contract on the write port; out-of-range
  row/col → `l_error`, but coordinate payload is stored as-is).
* Mesh writes must not race a lens drain's read window (see contract).
* Synthesis evidence is `synth_gowin` map-level only — no P&R, no
  timing closure, no board run.
* `opt`-generated carry chains report as `ALU` cells in addition to LUT
  counts; resource lines above list both.
