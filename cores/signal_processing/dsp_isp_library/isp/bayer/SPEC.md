# ISP-07 Bayer demosaic — bilinear RGGB/BGGR/GRBG/GBRG → RGB

Streaming raster core `bayer_demosaic` wrapping the shared, silicon-qualified
`infra/window/stream_window_padded` (K=3, PAD_MODE=REPLICATE) foundation.
One `{R,G,B}` output beat per input Bayer pixel, same raster order and same
SOF/EOL marker contract.

## Data formats

- Input pixel: unsigned `BITS`-wide Bayer sample, `BITS` in {8, 10}.
- Output pixel: `m_tdata = {R, G, B}`, each `BITS` wide (3·BITS total).
- Image geometry: **static** `WIDTH`/`HEIGHT` parameters (the window
  foundation is elaboration-sized; any size ≥ 1x1 is legal, verified down to
  1x1 and including the minimum useful 3x3).
- `s_tuser` = SOF on frame pixel (0,0); `s_tlast` = EOL on column WIDTH-1.
  Both are checked on the input side by the window core and re-checked for
  alignment at the output (`marker_error` latches any violation).

## Bayer phase and ROI origin

The phase coordinate of frame pixel `(x,y)` is

    pp = { yp, xp } = { (y + cfg_oy) & 1, (x + cfg_ox) & 1 }

The pattern is anchored automatically at each frame's SOF pixel (frame
origin); `cfg_ox`/`cfg_oy` carry the parity of that frame origin inside the
full sensor array — i.e. the Bayer phase **after an ROI crop** is handled by
setting the origin parity, which is the only residual information an ROI can
inject into a bilinear demosaic.

`cfg_cfa` selects the named pattern by the phase position of its R site; the
B site is always the diagonally opposite phase `rph ^ 2'b11`:

| cfa | name | R site pp | B site pp |
|-----|------|-----------|-----------|
| 0   | RGGB | 00        | 11        |
| 1   | BGGR | 11        | 00        |
| 2   | GRBG | 01        | 10        |
| 3   | GBRG | 10        | 01        |

Equivalently BGGR/GRBG/GBRG are RGGB observed at ROI origin parities
(1,1)/(1,0)/(0,1) — the model regression asserts these identities exactly.

## Interpolation kernel (bit-exact, truncating averages)

Taps of the 3x3 window `w[i]`, index `i = row*3 + col`:

    tl up tr      0 1 2
    lf  c rt  =   3 4 5
    bl dn br      6 7 8

    cross = (up + dn + lf + rt) >> 2      4-tap axial, floor
    diag  = (tl + tr + bl + br) >> 2      4-tap diagonal, floor
    h2    = (lf + rt) >> 1                2-tap horizontal, floor
    v2    = (up + dn) >> 1                2-tap vertical, floor

Per output pixel, by site color:

| site      | R            | G            | B            |
|-----------|--------------|--------------|--------------|
| R         | c            | cross        | diag         |
| B         | diag         | cross        | c            |
| G (hcol=R)| h2           | c            | v2           |
| G (hcol=B)| v2           | c            | h2           |

For a G site, `hcol` is the *pattern* color of the horizontal-neighbor phase
`{yp, ~xp}`; the channel found on the horizontal axis averages `lf/rt`, the
other averages `up/dn`.  The site channel itself is copied, never averaged.

Averages are truncating (floor), identical to the legacy
`wave2_ip_20k/isp_demosaic` RGGB kernel; this core generalizes it to all four
patterns plus ROI origin parity, 8/10-bit, and the Stream contract.

## Boundary handling

The padded window implements REPLICATE edges — each axis is clamped
independently:

    tap(dx,dy) = frame[min(max(y+dy,0),H-1)][min(max(x+dx,0),W-1)]

No zeros are injected.  Consequences (shared exactly by model and RTL):
at a corner, e.g. (0,0), the up/lf taps replicate the center sample, so a
cross or diagonal average includes same-site edge values; interior pixels
(≥1 away from the border) always see nine genuine neighbors.  Degenerate
geometry: a 1x1 frame yields all nine taps = the single pixel, hence
R=G=B=that pixel; 1×N / N×1 frames analogously collapse the clamped axis.

## Stream, configuration, reset

- Single `clk`, synchronous active-low `rst_n`.  All state (including window
  engine, counters, output register) resets.
- Output stage is one registered beat after the window beat (service latency
  1); `m_tvalid` holds its payload stable across `m_tready` stalls — every
  state element is gated by the same advance condition, and the window core
  only advances when the output register can accept.  No CE-gated RAM reads
  hold data across stalls (fabric-register `ram_style` in the window infra).
- Throughput is window-engine-bound: row capture/replay of the padded
  foundation, not II=1; cadence is fixed and deterministic per frame size
  (measured first-output latency 139 cycles at 32x24).
- `cfg_valid`/`cfg_ready`: atomic commit between frames only (`cfg_ready =
  rst_n && !busy`).  `cfg_reserved != 0` is rejected with `cfg_error` and the
  active config is preserved (verified by replaying a frame after a rejected
  config).  All 16 (cfa, ox, oy) combinations are legal.
- `busy` covers a frame from first accepted input to last emitted output;
  `marker_error` is sticky until reset and covers both input-side marker
  violations and output-side SOF/EOL misalignment.

## Verification scope

- `tests/test_models.py` — 517 model cases: phase/site coverage for all CFA
  names, origin-shift identities, float (exact rational) vs integer contract,
  per-channel-constant interior exactness, REPLICATE tap semantics, known
  hand-computed vectors, illegal config/input rejection.
- `tests/test_rtl.py` — iverilog/vvp regression over
  (BITS,WIDTH,HEIGHT) ∈ {8,10}×{(32,24),(16,16),(7,5),(3,3),(4,3),(2,2),
  (1,1)}: 24 frames per case covering all 16 phase combos plus uniform/zeros/
  max/gradient/checker/random/luma patterns, 3 epochs with mid-frame held
  output + reset, randomized ready/valid fuzz, illegal config each epoch,
  config-retention replay, and +data/+sideband/+order/+count checker
  mutations that must all fail.  Illegal static parameters (BITS=9/12,
  WIDTH=0, HEIGHT=0) must die in elaboration.
- `tests/synthesize.py` — isolated `yosys synth_gowin -noalu -family gw2a`
  mapping of `bayer_demosaic` **including** the window infra.

## Isolated synthesis results (LUT1-4 / FF / DSP / BSRAM)

| config           | LUT1-4 | FF   | DSP | BSRAM | MUX2_LUT5 |
|------------------|--------|------|-----|-------|-----------|
| 8b  32x24        | 1384   | 1329 | 0   | 0     | 140       |
| 10b 64x64        | 2854   | 2934 | 0   | 0     | 347       |
| 10b 128x128      | 5909   | 5510 | 0   | 0     | 1301      |

Zero multipliers by construction; the window row banks map to fabric
registers (`ram_style="registers"`), so BSRAM stays 0 and FF scales with
WIDTH.

## Limits

- Isolated mapping only — no P&R, routed timing, pin fit, board or
  production acceptance.
- Static image geometry per elaboration (window foundation is
  parameter-sized); runtime image-size reconfiguration would need a
  different window contract.
- Boundary rule is plain edge replication via the padded window; smarter
  border-aware interpolation (e.g. 2-tap-only corners) is out of scope.
- Bayer input only — no black-level, DPC, or channel gain stage inside.
