# Lens Shading Correction (LSC) — specification

Status: RTL/model simulation validated (`iverilog -g2012 -Wall`), yosys
`synth_gowin` resource numbers collected. No P&R/timing/board evidence yet.

`rtl/lsc_stream.sv` applies a per-channel gain mesh to a pixel stream:
`out = clamp(pix * g(x,y))` where `g` is bilinearly interpolated from a
runtime-loaded grid. Fully streaming: II=1, no frame storage, gain table is
the only memory.

## Interfaces

Pixel stream follows the shared contract: `s_tdata/s_tvalid/s_tready` with
`tuser`=SOF and `tlast`=EOL riding with the pixel; identical sidebands on the
master side. `s_tready = advance && (configured || pend_valid)`: the stream
is blocked after reset until the first config bundle is pending or active.
All state advances only on `advance = !m_tvalid || m_tready`; outputs are
held stable under stalls.

Scalar config bundle (one `cfg_valid && cfg_ready` beat): `width[12:0]`,
`height[12:0]`, `gw[4:0]`, `gh[3:0]`, `kx[3:0]`, `ky[3:0]`, `bayer`,
`order[1:0]`, `gswap`, `gmax[15:0]`. An accepted bundle is *pending* and
commits atomically at the next accepted SOF (`tuser`) pixel — the SOF pixel
itself already sees the new config (`commit_edge`). `cfg_ready` drops while a
bundle is pending so two bundles can never mix. `cfg_done` pulses on a legal
accept, `cfg_error` on rejection, never both.

Gain write port `g_valid/g_ready` with `g_phase[1:0], g_row[3:0],
g_col[4:0], g_data[15:0]` writes one grid node into the *shadow* (inactive)
buffer. `g_ready` is low only on the commit edge itself. `g_error` pulses on
out-of-range `row/col` (checked against pending dims if a config is pending,
else active dims; with neither, all writes are rejected). Each successful
write marks the shadow buffer as written.

`o_error` pulses on stream protocol violations: SOF mid-frame, pixel outside
a frame, early or missing EOL. Sticky-free pulse per offending pixel.

## Grid geometry and Bayer phase

Grid: `gw x gh` nodes per channel phase, 4 phases, ping-pong buffers.
Node spacing is a power of two: `2^kx` horizontally and `2^ky` vertically in
the interpolation domain. This is a hardware-friendly choice — index and
fraction come from shifts, no divider:

```
flat mode : u = x,        v = y        (dims W x H)
bayer mode: u = x>>1,     v = y>>1     (dims ceil(W/2) x ceil(H/2))
i   = min(u >> kx, gw-2)               // clamp at the last interior node
rem = u - (i << kx)                    // 0 .. 2^kx
fx  = (rem << 8) >> kx                 // Q8 weight, 0..256
```
same for `j, rem_y, fy` with `ky`. Coverage legality requires
`(gw-1)<<kx >= W_eff-1` and `(gh-1)<<ky >= H_eff-1`; the clamp `i <= gw-2`
lets the outermost node extend the mesh when `2^kx` overcovers the frame.
Weight 256 (100%) is reached exactly at the boundary node.

Phase select `ph` (bayer mode): `ph = T[order][y&1][x&1]` with
RGGB= `((0,1),(2,3))`, BGGR, GRBG, GBRG as the three remaining permutations
(RTL `phase_of`, model `PHASE_TABLE`). Each pixel is corrected only by the
subgrid of its own phase — grid nodes are defined in the 2x2-phase domain so
interpolation never mixes different color channel gains (Bayer phase
preservation). Flat mode always uses phase 0.

## Fixed-point derivation

- Node gains: unsigned Q4.12 in 16-bit words, range 0..15.9998.
- Interpolation weights: Q8 (0..256). `a = g00 + ((g01-g00)*fx >> 8)` etc —
  the product is signed 27-bit, the `>>8` is an arithmetic floor shift; the
  result stays inside `[min(g00,g01), max(g00,g01)]` by convexity, so 16 bits
  suffice. Vertical stage identical on `fy`.
- Gain clamp: `g = min(g_interp, gmax)` (Q4.12, runtime field).
- Apply: `out = min((pix*g + 2048) >> 12, 2^BITS-1)` — round half up (pix
  and g are non-negative), saturate to pixel range. Internal product
  27 bits (`1023 * 65535` max).
- An unwritten active buffer applies exact unity `0x1000` (passthrough);
  uninitialised RAM never reaches the output (synchronous-read banks +
  `written[]` flag per buffer).

Bilinear on power-of-two-spaced nodes with floor-shift interpolation matches
`models/model.py:fixed_frame` bit-exactly. The float model uses real-valued
`rem/2^kx` weights; measured error of the fixed path vs the saturated float
reference is <= 1 LSB across all regression frames (incl. corner regions).

## Storage: grid RAM

4 parity banks (`row&1, col&1`) x 2 ping-pong buffers x 4 phases x
`BANKCAP = ceil(GH_MAX/2) * ceil(GW_MAX/2)` entries x 16 bits. Each bank is a
synchronous-read `reg` array of `8*BANKCAP` words (504 at max dims);
bilinear reads of `(i,j),(i+1,j),(i,j+1),(i+1,j+1)` hit all four banks once —
single-port RAMs suffice. Bank offset `(j>>1)*PCAPW + (i>>1)` uses a fixed
stride; `PCAPW`/`BANKCAP` constants mean all address math is LUT shift-adds.
At GW_MAX=17, GH_MAX=13: 4 x 504 x 16 b = 32256 b -> mapped to 4 Gowin
DPX9B BSRAM blocks by `synth_gowin`.

## Atomicity and sequencing

- Config bundle commits at SOF only; mid-frame pixels never see mixed config.
- Gain writes always land in the shadow buffer; `gswap` in the committed
  bundle swaps buffers at SOF — whole table takes effect at once, mid-frame
  pixels keep the old table (tested: tables written during a live frame take
  effect at the next SOF only).
- While a `gswap` bundle is pending, writes still target the same shadow
  buffer the swap will activate, so the table being written *is* the table
  being committed. Only the commit edge itself blocks `g_ready` (one cycle).
- Recommended flows: same-dims table update = write table, then cfg with
  `gswap=1`. Changing dims = cfg with new dims first (commits at SOF), then
  write the new table, then cfg `gswap=1` (commits at the following SOF).
- `cfg_ready` backpressure while a bundle is pending is exercised in the
  regression (cfgwait counter > 0 required for PASS).

## Pipeline / latency / II

4-stage pipeline after accept: S1 bank read + index capture, S2 horizontal
interpolation (2 mults), S3 vertical interpolation (1 mult), S4 clamp,
gain apply (shift-add multiplier), quantize. No-stall latency = 4 cycles
(input accept to `m_tvalid`), II = 1 sustained (checked cycle-exact in the
full-rate epoch). A single output register is the only skid slot; the ready
path is `advance -> s_tready`, one comb hop. Insert a shared stream FIFO for
long ready chains.

## Config legality (rejected with cfg_error, no state change)

`width<2`, `height<2`, `gw<2 || gw>GW_MAX`, `gh<2 || gh>GH_MAX`,
insufficient coverage `((gw-1)<<kx) < W_eff-1` or the ky/H equivalent.
Static parameter check (`initial $fatal`): `BITS in {8,10}`,
`GW_MAX in 2..17`, `GH_MAX in 2..13`.

## Verification

`python cores/signal_processing/dsp_isp_library/isp/lsc/tests/test_lsc.py`

Four deterministic seeded cases (flat 32x24 9x7; Bayer all four orders 32x24;
max grid 17x13 on 33x25 with gain-clamp; tiny 8x6 2x2 Bayer), each run
through 3 epochs (full rate, sink stalls, sparse source) plus a mid-stream
reset and an orphan-pixel protocol-error check. Assertions: bit-exact vs the
fixed model on every output, markers/order/count checked, `tuser/tlast`
piped correctly, held outputs stable during stalls, II=1 at full rate,
illegal dims rejected (width 0, gw 1, gw 18, gh 14, non-covering kx/ky,
height 1), out-of-range gain write rejected, checker sensitivity proven by 4
mutation replays per case (data/sideband/order/count), static param rejects
(BITS=9, GW_MAX=1, GH_MAX=20). Flat-field case: shading-corrupted uniform
input returns to uniform (residual <= 1 LSB). Corner-band error vs saturated
float <= 1 LSB.

Evidence: `evidence/sim_<ts>/summary.json`, per-case compile/run/negative
logs, source hashes.

## Synthesis

`python cores/signal_processing/dsp_isp_library/isp/lsc/synth_lsc.py`
(`yosys read_verilog -sv` + `synth_gowin -top lsc_synth_top`, no -family)

| config | LUT | FF | DSP | BSRAM | ALU |
|--------|-----|----|-----|-------|-----|
| BITS=8 | 1132 | 381 | 3x MULT18X18 | 4x DPX9B | 616 |
| BITS=10| 1188 | 389 | 3x MULT18X18 | 4x DPX9B | 648 |

Well inside the <=15K LUT / <=4 DSP target. Timing/P&R not run.

## Limitations

- Power-of-two node spacing only: nodes sit at `i<<kx` (phase domain), not
  exactly on frame edges; outermost node is extended to the frame boundary by
  the index clamp. If exact edge-anchored spacing is required, that is a
  different (divider-based) datapath.
- Bayer phase domain uses `ceil(W/2)`/`ceil(H/2)` shared across all four
  phases; for odd W/H the even-column/row phases have one fewer sample and
  the last node is shared — documented approximation, error < 1 weight LSB.
- Node RAM is not cleared; unwritten buffers report unity gain via the
  `written` flag instead of emitting uninitialised data.
- Config commit is at SOF only; a pending bundle with no incoming frame
  waits indefinitely (by design).
- Single clk, synchronous `rst_n`; reset drops in-flight pixels and pending
  config (documented, exercised by the mid-stream reset epoch).
- No frame buffer: the block is strictly streaming; it cannot be placed where
  a full-frame lookahead is required.
- The tail wait loop is a hardware contract on `cfg_done` polling; software
  must observe `cfg_error` to detect rejection.
