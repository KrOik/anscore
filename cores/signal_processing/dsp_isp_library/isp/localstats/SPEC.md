# ISP-10 integral image / local statistics / adaptive threshold

Streaming raster core `integral_stats` (with combinational submodule
`adaptive_threshold`) computing, per input pixel, in raster order:

- **integral image**: `isum = I(x,y) = Σ p` over rows 0..y, cols 0..x;
  `isq = I2(x,y) = Σ p²` (sideband outputs `m_isum`, `m_isq`).
- **local statistics** over a runtime-configured rectangular window:
  `wsum`, `wsq`, `area`, `mean`, `var` (sideband outputs).
- **mean-C adaptive threshold**: `m_tdata` = all-ones when the pixel is
  foreground, else 0 (same-size binary image stream).

## Data formats and window contract

Pixels are unsigned `BITS`-wide, `BITS` in {8, 10}. Image geometry is a
runtime configuration `img_w` in [1, MAX_W], `img_h` in [1, MAX_H] with
static bound `MAX_W*MAX_H <= 65536` (covers all qualification sizes
1x1, 2x2, 7x5, 32x24 and up to e.g. 256x256).

The local window for output pixel (x,y) is the **causal trailing**
rectangle rows `max(0,y-WH+1)..y` × cols `max(0,x-WW+1)..x`. Boundary
rule: the window is **clipped (shortened) at the top and left edges**;
no padding values are invented and the window never looks ahead, so no
bottom/right clipping can occur. Output size equals input size
(same-size stream, `tuser`=SOF at (0,0), `tlast`=EOL at x=img_w-1).
A centered-window equivalent is obtainable by delaying the input frame
by WH/2 rows plus WW/2 pixels upstream; this core deliberately keeps the
zero-lookahead causal form.

Runtime window `win_w` in [1, WIN_W_MAX], `win_h` in [1, WIN_H_MAX],
rectangular (any WxH combination, not only odd/square). Static bounds
`WIN_W_MAX <= 15`, `WIN_H_MAX <= 15`; maximum window area 225.

## Integer contract (bit-exact, shared by RTL and `models/reference.py`)

    area = min(x+1, win_w) * min(y+1, win_h)
    mean = floor(wsum / area)                    exact floor division
    var  = floor(wsq / area) - mean*mean         always >= 0
    bin  = (pixel + C) * area > wsum             exact, see below
    m_tdata = bin ? 2^BITS-1 : 0

`bin` equals the real rule `pixel > wsum/area - C` *exactly* for any
positive integer area — no division and no rounding decision is needed
for the threshold itself. `C` is signed 8-bit, runtime-configured.
Tie behavior: equality `(pixel+C)*area == wsum` yields background
(strict `>`), matching `pixel == mean - C` under the real rule.

`var` is the defined integer variance `floor(E[p²]) − floor(E[p])²`;
its deviation from the exact rational variance is in (−1, 2·mean+1),
and it is exact whenever `wsum % area == 0` (in particular on uniform
regions, where it correctly reports 0). `mean` is the exact floor.
Both are reporting quantities; the binary decision does not use them.

## Accumulator widths (no overflow by construction)

Let `MPX = 2^BITS − 1`, `FP = MAX_W*MAX_H <= 65536`.

| signal   | bound                         | width |
|----------|-------------------------------|-------|
| col_sum  | ≤ 15·MPX                      | CSW = clog2(15·MPX+1) (12/14) |
| col_sq   | ≤ 15·MPX²                     | CQW = CSW+BITS (20/24) |
| wsum     | ≤ 225·MPX                     | WSW = clog2(225·MPX+1) (16/18) |
| wsq      | ≤ 225·MPX²                    | WSSW = WSW+BITS (24/28) |
| isum     | ≤ FP·MPX ≤ 65536·1023         | IW = clog2(FP·MPX+1) (≤27) |
| isq      | ≤ FP·MPX²                     | ISW = IW+2·BITS (≤46) |
| area     | ≤ 225                         | AW = 8 |
| var      | < MPX²                        | VW = 2·BITS |

Intermediate updates keep one extra pixel term of headroom
(`16·MPX`, `16·MPX²`, `226·MPX`, `226·MPX²` respectively) and stay inside
the listed widths for every legal configuration; overflow wrap is
prohibited by construction, not by runtime saturation.

## Stream, configuration, reset

Single `clk`, synchronous active-low `rst_n`. Input
`tdata/tvalid/tready` + `tuser`(SOF) + `tlast`(EOL) bound to each pixel.
Output `m_tdata` stream carries the binary image with the same marker
contract; statistic sidebands (`m_isum/m_isq/m_wsum/m_wsq/m_area/
m_mean/m_var`) are valid while `m_tvalid` and are not separately
backpressured. `tvalid && !tready` holds data and all sidebands/markers;
`s_tready = advance && !(cfg_valid && cfg_ready)` gives a single-level
ready path (one elastic beat), and a pending config has priority over a
new input beat.

**Markers**: input `tuser`/`tlast` are checked against the configured
geometry on every accepted pixel; violations set sticky `marker_error`
(until reset) and do not resynchronize — position counters keep their
raster contract.

**Atomic config** (`cfg_valid/cfg_ready`, all fields committed or
rejected together): `cfg_img_w`, `cfg_img_h`, `cfg_win_w`, `cfg_win_h`,
`cfg_c` (signed8). `cfg_ready` asserts only between frames (`busy` low),
so a held request waits for the frame gap; legal updates pulse
`cfg_done`, out-of-range fields pulse `cfg_error` and leave the previous
configuration intact. Reset default: `img = MAX_W×MAX_H`,
`win = 3×3`, `C = 0`.

`busy` = frame-open (inputs started, not complete) OR outstanding
accepted-not-emitted pixels; it therefore also covers mid-frame input
gaps, so configuration can never land inside a frame.

**Reset** discards the in-flight transaction and clears valid/control/
accumulator state; RAM contents are not cleared but are masked by
validity (`row 0` / `y < win_h` / `x < win_w` conditions), so stale data
can never reach an output. A mid-frame reset simply restarts the frame
contract at (0,0); the next frame is expected to carry SOF.

## Architecture (prefix-sum / sliding-accumulator foundation)

Per accepted pixel the core performs O(1) work — this is what makes the
strict II=1 contract honest at any window size:

1. **Pixel history**: `WIN_H_MAX` rotating line banks of `{p², p}`
   (synchronous-read RAM; the read-before-write edge supplies the
   leaving pixel `win_h` rows above).
2. **Column accumulators** `col_sum[x]`, `col_sumsq[x]`: running
   vertical window sums `col_new = col_prev + p − p_leaving` (masked for
   `y < win_h`, reinitialized on `y == 0`).
3. **Horizontal running sums**: `wsum += col_new[x] − col_new[x−win_w]`
   via a `win_w`-deep delay of the fresh column sums (masked for
   `x < win_w`); area accumulated incrementally (+`min(y+1,win_h)` while
   `x < win_w`), so no area multiplier exists.
4. **Integral image**: row prefix `rowsum(x,y) = rowsum(x−1,y) + p` plus
   previous-row integral line `imem[x]`/`imem2[x]` (`I = I_prev + rowsum`,
   likewise for squares).

Pipeline: stage A (take edge) captures the pixel and issues all five
synchronous RAM reads; stage B commits the combinational update on the
next advance edge (writebacks + output registers). Commit edges write
address `x` while the next take reads `x+1`; for `img_w == 1` the
write and the next row's read collide on one edge, which is covered by
`last_*` forwarding registers (the condition `last_addr == cap_x` can
only be true for width 1, so the forward is exact and can never fire
spuriously).

## Latency / throughput

- II = 1 sustained: one output beat per input beat, every cycle, for any
  legal window/image configuration. No drain phase, no row replay.
- First output `m_tvalid` rises 1 cycle after the first accepted pixel;
  first output transfer completes 2 cycles after it with `m_tready` high.
- Under backpressure, valid/data/markers hold; `busy` blocks config.

## Resource summary (isolated `synth_gowin -noalu -family gw2a`)

See `ip_manifest.json` and `evidence/synth_*/summary.json` for the
measured table. Qualification-scale builds are ≈2.4K LUT, ≈0.9–1.2K FF,
≤3 Gowin DSP multipliers (p², mean², (pixel+C)·area) and BRAM covering
pixel banks, column accumulators and integral lines.

## Limits

- Causal trailing window only; centered windows need an upstream
  frame/line delay.
- `isq` at 10-bit/256×256 reaches 46-bit sideband width.
- No P&R, timing or board claim yet; RAM inference follows the same
  `ram_style="block"` pattern as the window foundation.
- Malformed marker streams flag `marker_error` but are not resynced.
