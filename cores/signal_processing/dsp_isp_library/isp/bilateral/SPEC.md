# ISP-18 — Edge-Preserving Denoise: 3x3 Bilateral Filter

Status: RTL/model simulation validated (`iverilog -g2012 -Wall`), yosys
`synth_gowin` resource numbers collected. No P&R/timing/board evidence yet.

`rtl/bilateral_stream.sv` is a streaming 3x3 bilateral filter:

```
out = sum_k( ws[k] * wr(|tap_k - center|) * tap_k ) / sum_k( ws[k]*wr(|..|) )
```

with a spatial weight table `ws[9]` and a range (intensity-difference)
table `wr[2**WR_AW]` — both programmable LUTs, so sigma_d/sigma_r are fully
runtime-redefinable. Default (reset) tables are the reference configuration
sigma_d = 1.0, sigma_r = 25 (8-bit domain).

## Interfaces

Pixel stream follows the shared contract: `s_tdata/s_tvalid/s_tready` with
`tuser`=SOF, `tlast`=EOL riding with the pixel; identical sidebands on the
master side. Frame size `WIDTH x HEIGHT` is compile-time (parameters); the
output frame has the same W x H raster and marker placement as the input.

Scalar config bundle (one `cfg_valid && cfg_ready` beat):
`{cfg_rsvd[5:0], cfg_lswap, cfg_bypass}`. An accepted legal bundle is
*pending* and commits atomically at the next accepted SOF (`tuser`) pixel —
the commit edge is `take && s_tuser && pend`. `cfg_ready` drops while a
bundle is pending so two bundles can never mix. `cfg_done` pulses on legal
accept, `cfg_error` on `cfg_rsvd != 0` (rejected, no state change).

- `cfg_bypass`: per-frame bypass; output = centre pixel (exact input
  passthrough for PAD_MODE=1). `bypass` is sampled per emitted window and
  carried through the whole pipeline as a pixel attribute — a commit at the
  next frame's SOF can never leak into the current frame's tail outputs
  (found and fixed during verification; the earlier level-sampled mux
  corrupted up to DN+1 tail pixels of the previous frame).
- `cfg_lswap`: copies the shadow weight tables into the active copy in one
  cycle at commit.

LUT write port `lt_valid/lt_ready` with `lt_addr[WR_AW:0]`,
`lt_data[WR_W-1:0]` writes the *shadow* tables: addr `0..RLN-1` = range LUT,
`RLN..RLN+8` = spatial LUT (`RLN = 2**WR_AW = 64`). `lt_ready` drops only on
the commit edge itself (single-cycle block). `lt_error` pulses on an
accepted out-of-range address (`>= RLN+9`) or a spatial entry wider than
WS_W (`lt_data[WR_W-1:WS_W] != 0`). Tables written during frame f and
committed by a `lswap` bundle pending in frame f apply to frame f+1 — the
swap is atomic per frame, a table can never split a frame.

`o_error` is the sticky protocol-violation flag from the window core
(misplaced SOF/EOL); held once set, cleared by reset.

## Window provider (reuse)

`infra/window/stream_window_padded` (K=3, `PAD_MODE=1` replicate border;
`PAD_MODE=0` zero pad also legal) emits the full W x H window raster, tap k
at `m_tdata[k*BITS +: BITS]` row-major, tap 4 = centre. Reuse is possible
because its markers and contract already match the shared stream rules.

Throughput note: the padded window engine captures one source row into a
fabric row buffer, then replays the extended raster rows; it therefore
accepts input in bursts and sustains ~0.5 px/cycle (each input row of W
takes is followed by W+2 replay beats, plus top/bottom pad rows). The
bilateral datapath after the window is II=1 end to end. Documented
sustained rate: ~WH / (WH + (W+2)(H+2)) px/cycle ≈ 0.5 for large frames.

## Fixed-point derivation

| node | width | range / note |
|------|-------|--------------|
| tap diff `|tap-c|` | BITS | 0..255 (8b) |
| range index | WR_AW=6 | `diff >> (BITS-WR_AW)` = bin of 4 diffs |
| `wr` | WR_W=8 | LUT, 0..255 |
| `ws` | WS_W=4 | LUT, 0..15 |
| `wq = (ws*wr)>>WS_W` | 8 | 0..239, truncate (documented below) |
| `den = sum wq` | DEN_W=12 | <= 9*239 = 2151 |
| `num = sum tap*wq` | NUM_W=20 | <= 255*2151 = 548505 |
| quotient | OW=9 signed | <= 255 always (convex combination) |

All multiplies are explicit shift-adds (`mul_sw`, `mul_pw`) so no DSP is
spent in the datapath.

Normalization divide: `fp_div_pipe` from `infra/fixedpoint/rtl/recip_div.sv`
(shared infra, already verified), parameters `AW=NUM_W+1=21, BW=DEN_W+1=13,
FB=0, OUT_W=BITS+1`. Result = `RNE(num/den)` (round-half-even on the integer
quotient, exact — matches `models/model.py:rne_div`). II=1, latency
`AW+FB+1 = DN+1 = 22` cycles. `clip` cannot occur for `den>0` (the quotient
is a convex mean of 8-bit taps) but is mapped to full-scale defensively.

Zero-denominator policy: `den==0` is flagged by the divider (`m_tuser[1]`);
the output then selects the delayed centre pixel `cdf` — all-zero range
weights (or all-zero spatial weights) yield exact passthrough. The centre
and sidebands travel a delay line (`vd` mirrors the divider `vld` chain
stage-for-stage, including bubbles) so `cdf/uf/lf` align with `dq/dval`
under any stall pattern.

## LUT derivation and error budget

`models/gen_luts.py` emits both tables and the packed hex for the RTL
parameters:

- `slut[k] = RNE((2**WS_W-1) * exp(-d2_k / (2*sigma_d^2)))`, `d2` in {0,1,2}
  row-major; sigma_d=1.0 -> `{6,9,6,9,15,9,6,9,6}`.
- `rlut[i] = RNE((2**WR_W-1) * exp(-d_i^2 / (2*sigma_r^2)))` with
  `d_i = i << (BITS-WR_AW)` — the bin's *left* edge, so quantization always
  overestimates the true weight by a bounded factor. sigma_r=25 ->
  `RLUT_INIT` (512'h0000..0101020304060a0e151d2836475a7088a1b9d0e3f2fcff).

Error sources vs the float model (`float_frame`):

1. range-index binning: actual diff `d` in bin `i` sees weight `rlut[i]`
   instead of `exp(-d^2/2sr^2)`; relative overestimate per bin is bounded by
   `exp(((d_i+step)^2 - d_i^2)/2sr^2) - 1` with step=4 (max ~14% at the
   steep edge of sigma_r=8 near the cutoff, ~2.5% for sigma_r=25).
2. table quantization: +-0.5 LSB on ws (of 15) and wr (of 255).
3. `wq` truncation: `(ws*wr)>>4` drops up to 15/16 of a wq LSB per tap
   (relative <= 1/(wq+1)); small weights collapse to 0 — that is the same
   mechanism as the intentional zero-denominator guard.
4. final RNE: <= 0.5 LSB.

Measured (regression `max_err_vs_satfloat`): <= 2 LSB on every case —
random, step, flat, 8- and 10-bit. For context the reference config keeps
edge pixels within 0..5 LSB of their own side level on a 120-LSB step with
+-4..8 LSB noise, and reduces flat-region variance to ~0.12 of input
(see `evidence/sim_*/summary.json`).

## Latency / II / storage

- Window engine emits output (0,0) after roughly `4*W+8` input-side cycles
  (row0 capture + two padded replays + row1 capture + fill); measured
  first-output cycle 163-237 depending on epoch (W=32).
- Bilateral pipe: +3 stages (S1 diff/LUT read, S2 weight combine,
  S3 accumulate) + divider DN+1=22 cycles + combinational output select;
  all II=1.
- Storage: window line banks are `ram_style="registers"` fabric arrays
  inside the reused window core (3*(W+2)+W words of BITS bits) plus the
  2x(64x8 + 9x4) active/shadow LUT regs — no BSRAM needed at W=32.

## Verification

`python cores/signal_processing/dsp_isp_library/isp/bilateral/tests/test_bilateral.py`

Six deterministic seeded cases, each through 3 epochs (full rate, sink
stalls, sparse source) + a mid-stream reset + an orphan-pixel protocol
check; 4 mutation replays per case prove checker sensitivity:

| case | covers |
|------|--------|
| `step_w32h24` | 4 frames; clean step `edge_deviation_lsb=0`; flat region variance ratio 0.119; bypass cfg committed at SOF; queued-behind-pending illegal cfg; illegal lt addr / oversized spatial data |
| `rand_w32h24` | 3 random frames; shadow-table isolation (writes not committed have no effect) + committed garbage table |
| `reload_w32h24` | sigma_r=8 runtime reload mid-stream; sharper edge preserved (`edge_deviation_lsb=5` on +-5 noise) |
| `zeroden_w32h24` | all-zero range LUT -> den==0 -> centre passthrough for the whole frame; restore to reference table |
| `tiny_w8h6` | 8x6 minimal frame |
| `bits10_w16h12` | 10-bit datapath, pre-frame LUT preload via `wait_cfg/wait_lt` |

Static illegal-parameter rejection (`initial $fatal`): BITS=9, PAD_MODE=2,
WR_AW=9 all fail elaboration.

## Synthesis

`python cores/signal_processing/dsp_isp_library/isp/bilateral/synth_bilateral.py`
(`yosys read_verilog` + `synth_gowin -top bilateral_synth_top`, no -family)

| config | LUT | FF | DSP | BSRAM | ALU |
|--------|-----|----|-----|-------|-----|
| BITS=8, 32x24 | 7344 | 4005 | 0 | 0 | 1392 |
| BITS=10, 32x24 | 7966 | 4563 | 2x MULT18X18 | 0 | 1584 |
| BITS=8, 320x240 | 19728 | 13253 | 0 | 0 | 1453 |

8-bit reference config is well inside <=15K LUT / <=4 DSP. The two
MULT18X18 in the 10-bit run are inferred inside the shared
`stream_window` bank-index mux (`dut.win.core`), not in the bilateral
datapath. The 320x240 point is over budget: the reused window core keeps
its line banks in fabric registers (`ram_style="registers"`), so large
frames scale FF/LUT linearly with W — a BRAM-backed window variant would be
required for full-size images (limitation, below). Timing/P&R not run.

## Limitations

- Sustained throughput ~0.5 px/cycle (capture/replay window engine). The
  bilateral datapath itself is II=1; a future II=1 window core would lift
  the whole core to pixel-rate.
- Window line banks are fabric registers; W is compile-time and resource
  grows ~`(4W+6)*BITS` FF. Practical frames in this config are small
  (tested 8x6..32x24); large frames need a BRAM window variant.
- Reference config verified for 3x3 K=3 only (module is not parameterized
  for K=5).
- Table reload is frame-atomic (shadow + SOF commit); a `lswap` bundle
  pending with no incoming frame waits indefinitely (by design, same as
  lsc_stream).
- `PAD_MODE=0` (zero border) is implemented and parameterized but all
  regression cases use replicate borders.
- iverilog emits an informational "no explicit time unit" warning for the
  reused infra sources (they carry no `timescale`; read-only).
- No P&R, timing or board evidence; simulation + core synthesis only.
