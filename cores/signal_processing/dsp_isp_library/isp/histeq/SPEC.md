# ISP-11 histogram equalization / CLAHE

Streaming raster core `histeq_stream` implementing full-frame histogram
equalization (HE) and contrast-limited adaptive histogram equalization
(CLAHE) over unsigned `BITS`-wide pixels, `BITS` in {8, 10}. Image
geometry is a runtime configuration `img_w` in [1, MAX_W], `img_h` in
[1, MAX_H], static bound `MAX_W*MAX_H <= 65536` (covers qualification
sizes 1x1, 2x2, 7x5, 32x24 and up to e.g. 64x64 / 128x128 within BRAM).

The wave2 `img_histogram`/`hist_clahe` cores use the legacy
`clk_en`/`pix_valid`/`new_line`/`w2_dpram` contract and cannot be
instantiated under the new Stream contract; this core re-implements the
proven mechanisms inside `histeq_stream` (single `clk`, `rst_n`,
`tdata/tvalid/tready` + `tuser`=SOF + `tlast`=EOL): the histogram bin
RAM read-modify-write with 1-deep same-bin forwarding (identical hazard
schedule to `hist256.v`/`img_histogram.v`), drain-clears-bins reuse, the
combinational restoring divider and shift-add multipliers (zero DSP),
and the tile-centre bilinear apply pass of `hist_clahe.v` generalized to
run-time tile grids, proper clipped-mass redistribution and full-range
bins.

## Modes and statistics policy (the required design decision)

Runtime field `mode`:

| mode | name | statistics | frame buffer | streaming contract |
|------|------|-----------|--------------|--------------------|
| 0 | `HE_PREV` | **previous frame** histogram | not used | streamable II=1; inter-frame LUT rebuild |
| 1 | `HE_CUR`  | **current frame** histogram | required | ingest II=1 -> build -> replay II=1 |
| 2 | `CLAHE`   | **current frame**, per-tile | required | ingest II=1 -> build -> replay ~7 cyc/px |

Mode 0 semantics: the output of frame N applies the mapping LUT built
from frame N-1's histogram. The very first frame after reset uses the
identity LUT built during `S_INIT`. While pixels stream (II=1) the
current frame's histogram is accumulated; at end of frame the core
deasserts `s_tready` for the CDF/LUT build (~520 + pipeline cycles) and
the next frame then uses the fresh LUT. No frame buffer is consumed.

Modes 1/2 semantics: equalization of a frame requires the *complete*
frame statistics before the first output can be produced, so a full
frame buffer (`MAX_W*MAX_H*BITS` bits, BRAM) is mandatory and always
instantiated. The frame is ingested at II=1 (histogram accumulated
concurrently), the LUT(s) are built, then the buffered frame is
replayed through the LUT(s). `s_tready` stays low from end-of-ingest
until replay drains (single buffer: no ingest/replay overlap).
Turnaround is honestly one frame of latency plus the build (~0.5k
cycles HE, up to ~3.7k cycles CLAHE-16-tile) plus the replay.

`GLUT` always holds the map from the most recently completed HE build
(modes 0/1). A mode-0 frame between mode-1/2 frames uses whatever LUT
is current at its SOF — deterministic and documented; CLAHE builds do
not touch `GLUT`/`HIST`.

## Histogram / CDF quantization

- Global HE: `NBINS = 256`; bin index `gb(p) = p >> (BITS-8)`
  (8-bit: p itself; 10-bit: top 8 bits). Count width 18 bits
  (no overflow: max count = 65536).
- CLAHE: `CBINS = 64` per tile; `cb(p) = p >> (BITS-6)`
  (8-bit: p>>2; 10-bit: p>>4). Tile grid `NTX x NTY = 2^txl x 2^tyl`,
  `txl+tyl <= 4` (<= 16 tiles), so tile histograms occupy one
  1024x18 RAM `{tile[3:0], bin[5:0]}` and tile LUTs one 1024xBITS RAM.
- Tile geometry: `tw = img_w >> txl`, `th = img_h >> tyh`, uniform grid;
  legality requires `img_w % 2^txl == 0` and `img_h % 2^tyl == 0`
  (`cfg_error` otherwise). Tile area `T = tw*th`, tile of pixel (x,y) is
  `(y/th)*NTX + (x/tw)`.

## Mapping formulas (bit-exact; `//` = floor division)

`MPX = 2^BITS - 1`, `N = img_w*img_h`.

**Global HE** (`cdf[i] = sum_{j<=i} h[j]`, `cdf_min` = cdf at the first
nonzero bin, `den = N - cdf_min`):

    den == 0  (single occupied bin) :
        map[i] = min(MPX, (2*i*MPX + 255) // 510)        # identity ramp
    else :
        d      = max(0, cdf[i] - cdf_min)
        map[i] = min(MPX, (2*d*MPX + den) // (2*den))    # round-half-up

For `BITS=8` the identity ramp is `map[i]=i` exactly. For `BITS=10` it
is `round(i*1023/255)` (~4i): equalization decisions are made at 8-bit
bin resolution and outputs span the 10-bit range; the constant-image
output is `map[gb(v)]`, within ~2 LSB of `v`. A constant frame is
therefore passed through essentially unchanged rather than blown out to
a rail — this is the defined degenerate behavior (it also matches the
first-frame identity LUT, so no special case exists in the datapath).

**CLAHE per tile** (`clip` = `cfg_clip`, 1..65535):

    hc[i]   = min(h[i], clip)
    excess  = sum_i (h[i] - hc[i])            # = T - sum(hc)
    base    = excess >> 6 ;  rem = excess & 63
    h'[i]   = hc[i] + base + (i < rem ? 1 : 0)
    cdf'[i] = sum_{j<=i} h'[j]                # cdf'[63] = T exactly
    map_t[i]= min(MPX, (2*cdf'[i]*MPX + T) // (2*T))

Single-pass even redistribution with remainder to the lowest bins —
the defined remainder rule (no iterative re-clip; `h'` may exceed
`clip`, deterministic). Sum preservation `sum(h') = T` is exact and
tested. Note CLAHE maps the CDF directly onto `[0, MPX]` (no `cdf_min`
subtraction — classic CLAHE contrast). A constant tile yields a legal
ramped map; combined with bilinear interpolation the result is
deterministic.

**Inter-tile bilinear interpolation** (power-of-two-free tile sizes
supported): tile centres are at `c = floor(t/2)` inside each tile.
For pixel column x in tile `tx` at offset `dx`:

    cx = tw>>1
    dx <  cx : pair (tx-1, tx), nx = dx + tw - cx   (tx==0 -> pair (0,0))
    dx >= cx : pair (tx, tx+1), nx = dx - cx        (tx==NTX-1 -> pair (tx,tx))
    fx6 = (pair degenerate) ? 0 : fxt[nx],  fxt[n] = (128*n + tw)//(2*tw)

`fx6` is the weight of the second tile in units of 1/64; the table is
rebuilt per frame during the build phase (`tw` divisions, ~1/cycle, so
odd tile sizes need no per-pixel divider). Same for `fy6`/`th`.
Per pixel, `m00,m01,m10,m11` are the four tile LUT entries at `cb(p)`:

    out = (m00*(64-fx6)*(64-fy6) + m01*fx6*(64-fy6)
         + m10*(64-fx6)*fy6 + m11*fx6*fy6 + 2048) >> 12,  clamped <= MPX

Edge tiles are clamped (no extrapolation); weights sum to exactly 4096
so the output can only exceed `MPX` by the +2048 rounding term.
The interpolation is spatially continuous: across a tile boundary the
weight changes by exactly `64/tw` per column.

## Stream, configuration, reset

Single `clk`, synchronous active-low `rst_n`. Input
`tdata/tvalid/tready` + `tuser`(SOF) + `tlast`(EOL) bound to each pixel.
Output stream carries the equalized image, same size/markers.
`tvalid && !tready` holds data and markers.

**Markers**: input `tuser`/`tlast` are checked against the configured
geometry on every accepted pixel; violations set sticky `marker_error`
(until reset) and do not resynchronize.

**Atomic config** (`cfg_valid/cfg_ready`, all fields committed or
rejected together): `cfg_img_w`, `cfg_img_h`, `cfg_mode` (0/1/2),
`cfg_txl`, `cfg_tyl` (0..4, CLAHE only), `cfg_clip` (16-bit, CLAHE only;
ignored in modes 0/1). `cfg_ready` asserts whenever no input frame is
open (`!fopen && !pend`) — this deliberately also covers build/replay,
because build/replay geometry is latched into `w_*` registers at the
last accepted pixel of the frame; a config committed during replay
applies to the *next* frame. Illegal fields pulse `cfg_error` and keep
the previous configuration. Defaults after reset: img = MAX_W x MAX_H,
mode 0, txl = tyl = 0, clip = 0.

Illegal configurations (`cfg_error`): out-of-range image, mode > 2,
mode 2 with `CLAHE_EN=0`, `clip < 1`, `txl > 4`, `tyl > 4`,
`txl+tyl > 4`, or `img_w/img_h` not divisible by `2^txl`/`2^tyl`.

**`busy`** = frame-open OR pending pipeline OR any non-idle state OR
held output; it therefore covers ingest gaps, build and replay.

**Reset** discards the in-flight transaction and re-enters `S_INIT`
(~1024-cycle identity-LUT + histogram clear). RAM contents are never
read before being written for the current frame, so stale data can
never reach an output. A mid-frame reset simply restarts the contract;
the next frame is expected to carry SOF.

## Architecture

- Ingest pipeline (all modes): stage A (`take`) captures the pixel,
  issues the histogram bin read (and mode-0 `GLUT` read); stage B
  commits the RMW count on the next advance edge. A same-bin hazard
  exists only between adjacent accepted pixels (write commit collides
  with the next read capture), covered by the 1-deep
  `(addr,count)` forwarding register — the same schedule as the
  proven `hist256.v`/`img_histogram.v` cores.
- `S_INIT`: clears `hmem`/`cmem`, writes identity `GLUT` (i*MPX/255
  rounded), ~1024 cycles once after reset.
- HE build: pass 1 walks the 256 bins in place (`hmem[i] <= cdf[i]`)
  tracking `cdf_min`; pass 2 converts cdf->map into `GLUT` and writes 0
  back (clear-on-drain, ready for the next frame).
- CLAHE build per tile: pass 1 clips bins in place and accumulates
  `excess`; pass 2 adds `base + (i<rem)`, accumulates `cdf'`, writes the
  tile LUT and clears the bin. Then `fx6`/`fy6` tables are built
  (`tw`/`th` entries, one combinational divide per cycle).
- Replay: mode 1 is a 3-stage II=1 pipeline (frame RAM -> GLUT -> out);
  mode 2 is a 7-phase per-pixel FSM (frame read, four tile-LUT reads,
  two shift-add lerp stages) — ~7 cycles/pixel sustained, honest.
- All divisions use one shared combinational restoring divider and all
  multiplies use shift-add functions (as `hist_clahe.v`): zero DSP and
  zero `/` or `*` operators in the datapath.

## Latency / throughput (no-backpressure, full-speed)

| phase | cost |
|-------|------|
| mode 0 ingest+output | II=1; first `m_tvalid` 1 cycle after first take |
| inter-frame HE build | ~ 2*256*2 + ~10 cycles, `s_tready` low |
| mode 1/2 ingest | II=1 |
| HE build (mode 1) | same ~1.0k cycles |
| CLAHE build | ~ NT*2*64*2 + max(tw,th) + ~20 cycles (<= ~4.3k) |
| mode 1 replay | II=1, 3-cycle pipeline latency |
| mode 2 replay | ~7 cycles/pixel sustained |
| `S_INIT` | 1024 (or 256 with `CLAHE_EN=0`) cycles after reset |

Mode-0 continuous throughput = `N` pixel cycles + ~1.1k inter-frame
gap per frame. Modes 1/2 throughput = ingest + build + replay per
frame with no overlap (single frame buffer).

## Resource expectations (isolated `synth_gowin -noalu -family gw2a`)

BRAM: `hmem` 256x18 (1), `cmem` 1024x18 (1), `gmem` 256xBITS (1),
`lmem` 1024xBITS (1), `fmem` MAX_W*MAX_H*BITS (1..~10 by config).
No DSP. See `ip_manifest.json` / `evidence/synth_*/summary.json`.

## Limits

- 10-bit equalization decisions quantized to 8-bit (global) / 6-bit
  (CLAHE) bins; LUT outputs still span the full 10-bit range.
- Mode-0 one-frame-older statistics: scene changes lag one frame
  (documented semantics, not a defect).
- CLAHE tile grid limited to <=16 tiles total and requires exact
  divisibility; tile histogram bin depth is 64.
- Single frame buffer: modes 1/2 cannot ingest the next frame during
  build/replay; throughput is frame-cyclic, not II=1 end to end.
- CLAHE single-pass redistribution may leave `h'` above `clip`
  (standard non-iterative variant, deterministic).
- No P&R, timing or board claim yet; RAM inference follows the same
  `ram_style="block"` pattern as the window foundation.
