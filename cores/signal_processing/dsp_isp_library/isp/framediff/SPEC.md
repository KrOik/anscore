# ISP-17 frame differencing / background modelling — specification

Status: RTL/model simulation validated (`iverilog -g2012 -Wall`, clean),
yosys `synth_gowin` resource numbers collected (BSRAM inferred). No
P&R/timing/board evidence yet.

`rtl/framediff_stream.sv` compares an unsigned `BITS`-wide (8 or 10) pixel
stream against a per-pixel **reference store** kept in one synchronous RAM
and emits, per configured mode, a binary change mask or the updated
running-mean background. Frame geometry is runtime-configured
(`W x H <= MAX_W*MAX_H <= 65536`, default bound 128x128x8b). Fully
streaming: II=1 sustained, one frame-RAM read + one write per pixel.

## Interfaces

Pixel stream follows the shared contract: `s_tdata/s_tvalid/s_tready` with
`tuser`=SOF and `tlast`=EOL riding with the pixel; identical sidebands on
`m_*`. `s_tready = rst_n && advance && (configured || pend_valid)`: the
stream is blocked after reset until the first config bundle is pending or
active. All state advances only on `advance = !m_tvalid || m_tready`;
outputs are held stable under stalls. `busy` is high while a frame is
open, a pixel is in the pipe, an output is held, or a config is pending.

Atomic config bundle (one `cfg_valid && cfg_ready` beat), fields:
`width`, `height`, `mode[1:0]`, `thresh[BITS-1:0]`, `alpha[3:0]`,
`scn[7:0]`, `scpol`. An accepted legal bundle is *pending* and commits at
the next accepted SOF pixel — the SOF pixel itself already sees the new
config (`e_pick`). `cfg_ready` drops while a bundle is pending so two
bundles can never mix; it re-asserts for exactly the commit edge.
`cfg_done` pulses on a legal accept, `cfg_error` on rejection, never both.

`o_error` pulses on stream violations seen at a take: SOF mid-frame,
pixel outside a frame, early or missing EOL. `scn_event` pulses once per
frame ending with a scene-change decision (see below).

## Modes and the reference update rule

The reference RAM holds one `BITS`-wide value per raster address
`a = y*W + x`. Every accepted pixel performs:

    ref  = ref_ram[a]                  (synchronous read at the take edge)
    diff = |cur - ref|
    ref' = mode == 0          ? cur                    # frame differencing
         : (!bg_valid)        ? cur                    # seeding
         : fa                 ? cur                    # fast-adapt frame
         : ref + ((cur - ref) >>> alpha)               # running mean
    ref_ram[a] <= ref'        (committed one edge later)

`>>>` is an arithmetic (floor) shift of the signed difference, matching
Python `>>` exactly. `|step| <= |diff|`, so `ref'` always lies inside
`[min(ref,cur), max(ref,cur)]` — no clamp needed, no wrap.

Outputs per mode (`m_tdata`, BITS wide):

| mode | name   | output                              | ref update |
|-----:|--------|-------------------------------------|------------|
| 0    | DIFF   | `diff > thresh ? MPX : 0`           | `cur`      |
| 1    | BG     | `ref'` (the new background value)   | running mean |
| 2    | MOTION | `diff > thresh ? MPX : 0`           | running mean |

The mask is canonical binary `0` / all-ones (`MPX = 2^BITS-1`), suitable
to feed a downstream binary morphology/threshold stage. "Above
threshold" is strict `>`: `diff == thresh` is static.

Mode 0's write rule makes the reference hold *the previous frame*, so
`diff` is exactly `|cur - prev|`. Mode switching does not re-seed: after
a 0→1/2 switch the first background updates continue from the stored
last frame; after a 1/2→0 switch the first frame diffs against the last
background estimate, then the reference resumes tracking `cur`.
Committing a *different W/H* clears `bg_valid` so the new-geometry frame
re-seeds instead of diffing against stale geometry.

## Seeding and uninitialised RAM

`bg_valid` is 0 after reset, after a RESET-policy scene change, and after
a geometry-changing commit. During a *seed frame* (`bg_valid==0`):
`ref' := cur`, `diff` is forced to 0, mask outputs are all-zero and the
mode-1 output is `cur`. `bg_valid` sets at the frame's last pixel (a
complete raster pass). Uninitialised RAM can never reach an output: the
only consumers of `rd` (diff, running mean) are masked off while seeding.
RAM is never cleared, per the reset contract.

## Background convergence bound

With constant scene `c` and residual `e_n = c - bg_n`, the update is
`e_{n+1} = e_n - floor(e_n / 2^a)` (resp. ceil behaviour via floor of the
negative for `e_n < 0`).

- **From above** (`c < bg`): `floor(e/2^a) <= -1` while `e < 0`, so the
  background descends to `c` exactly.
- **From below** (`c > bg`): the step is 0 once `e < 2^a`, so the
  background parks at residual `<= 2^a - 1` (bound is tight — a residual
  of exactly `2^a - 1` can persist forever). Documented asymmetry of the
  spec's literal `bg += (cur-bg)>>alpha` rule.
- While `e >= 2^a`: `e_n <= (e0 - (2^a-1)) * (1-2^-a)^n + (2^a-1)`.
  `frames_to_bound(err0, alpha, eps)` in `models/model.py` solves for n;
  e.g. err0=200, a=4 -> ~83 frames to reach residual <= 15+1.

`alpha` range: 0..15. `alpha=0` adopts `cur` in one frame (the update is
exactly `ref' = cur`, identical write to mode 0 / fast-adapt). Large
alpha converges slowly; residual bound `2^a - 1` grows correspondingly.
Verified in sim: a=4 run parks at residual 15 (= bound), a=0 at 0.

## Scene-change detection and recovery

Per frame, `chg` counts pixels with a real (`bg_valid`) `diff > thresh`.
At the last pixel of the frame:

    event = (chg << 7) > (W*H * scn)        # scn in 0..128, units of 1/128

`scn = 128` disables detection (`chg <= W*H` can never exceed the bound);
`scn = 0` fires whenever any pixel changed. On an event `scn_event`
pulses and `scpol` selects the recovery policy, applied to the **next**
frame (the ending frame's own updates already happened):

| scpol | policy     | next frame behaviour |
|------:|------------|----------------------|
| 0     | RESET      | `bg_valid := 0`: next frame re-seeds (`ref' = cur`, masks all-zero). Clean recovery = 1 frame. |
| 1     | FAST_ADAPT | `fa := 1`: next frame updates with `alpha_eff = 0` (`ref' = cur`) while still emitting real diffs vs the old reference — the new scene appears as one all-motion transition frame, then the background equals it. Recovery = 2 frames; note the adapt frame itself may trip a second event (observed: cascaded events in `scnfa` case), then settles. |

Detection runs in all modes (the diff is free); in mode 0 the FAST_ADAPT
write equals the mode's own write rule, so only RESET visibly changes
behaviour there. The compare `npix*scn` is a constant shift-add multiply
captured at the config commit (`a_scmp`) — no DSP and no divider.

## Frame storage and bandwidth

Single synchronous `reg [BITS-1:0] ref_ram [0:FP-1]`,
`FP = MAX_W*MAX_H <= 65536`. This is **internal** storage: at the default
128x128x8 it is 131072 bit -> 8 Gowin DPB dual-port BSRAM blocks under
`synth_gowin`; no external/frame memory interface is consumed. For
resolutions beyond the bound, `FP` would have to map to off-chip memory
and this block is not the right structure (documented limitation).

Bandwidth proof for II=1: the pipeline uses *one* stage — at the take
edge the reference read is issued (`rd <= ref_ram[a]`); one edge later
the stage-1 slot computes diff/update and commits `ref_ram[a] <= ref'`.
Consecutive pixels therefore need per cycle: 1 read (new take) + 1 write
(previous pixel's write-back) = exactly one access per direction per
cycle -> a single 1R/1W (semi-dual-port) RAM sustains II=1, no ping-pong
needed. The RAM address is strictly `+1` within a frame; the only
possible same-address read/write collision is between consecutive takes
of identical address (1x1 frames or malformed streams). A 1-deep
`(addr,data)` forwarding register covers it, and also makes the RTL
indifferent to read-old vs write-through BSRAM collision behaviour.
Regression `w1h1` exercises the collision path every frame.

## Latency / II

- Take -> `m_tvalid`: 2 cycles (no stall); II = 1 sustained, verified
  cycle-exact in the full-rate epoch for every output.
- No fill/drain phases: continuous frames stream back-to-back at II=1;
  the only output register is the single skid slot; ready path is
  `advance -> s_tready` (one comb hop). Insert a shared stream FIFO for
  long ready chains.
- Seed frames, adapt frames and mode changes cost zero extra cycles.

## Config legality (`cfg_error`, no state change)

`width==0 || width>MAX_W`, `height==0 || height>MAX_H`, `mode>2`,
`scn>128`. `alpha` 0..15 and `thresh` `0..2^BITS-1` are always legal.
Static parameters (initial `$fatal`): `BITS in {8,10}`, `MAX_W/MAX_H in
1..8191`, `MAX_W*MAX_H <= 65536`.

## Verification

`python cores/signal_processing/dsp_isp_library/isp/framediff/tests/test_framediff.py`

Nine deterministic seeded cases, each run through 3 epochs (full rate,
random sink stalls, sparse source) plus a mid-stream reset tail and an
orphan-pixel protocol check:

| case | covers |
|------|--------|
| fdiff_w16h12 | mode-0 moving block, seed frame, 6 illegal-config rejects inside pending windows |
| thresh_edge_w8h8 | diff = thresh-2..+3 boundary columns, strict `>` |
| bgconv_a4_w8h8 | mode-1 running mean, 102 frames; residual 15 == 2^4-1 bound |
| bgconv_a0_w8h8 | alpha=0 instant adoption, residual 0 |
| motion_w16h12 | mode-2 mask vs converging background, object appear/move/vanish |
| scnreset_w16h12 | 100%-change frame -> event, RESET policy, recovery 1 frame, NSCN=1 |
| scnfa_w16h12 | same flip, FAST_ADAPT: adapt frame all-motion, NSCN=2 (cascade), recovery 2 frames |
| dimswitch_w4h4 | runtime W/H change mid-stream -> auto re-seed |
| w1h1 | 1-pixel frames: same-address RAM collision forwarding each frame |
| bits10_w8h8 | BITS=10, mode 0 -> mode 1 switch mid-sequence |

Assertions: bit-exact vs `models/model.py` on every output,
markers/order/count checked, `tuser/tlast` piped correctly, held outputs
stable during stalls, II=1 at full rate, first-output latency = 2,
`scn_event` count exact (`NSCN`), `cfg_ready` backpressure observed,
illegal dims/mode/scn rejected with `cfg_error`, 4 mutation replays
(data/sideband/order/count) must fail, static param rejects
(BITS=9, MAX_W=0/8192, MAX_H=0/8192, 256x512 > 65536).

Evidence: `evidence/sim_<ts>/summary.json` (+ per-case logs) and
`evidence/synth_<ts>/summary.json`.

## Synthesis

`python cores/signal_processing/dsp_isp_library/isp/framediff/synth_framediff.py`
(`yosys read_verilog -sv` + `synth_gowin -top framediff_synth_top`,
no `-family` flag). Mapped cells:

| config | frame RAM | LUT-class* | FF | DSP | BSRAM |
|--------|-----------|-----------:|---:|----:|------:|
| BITS=8, 128x128 | 128 Kib | 527 LUT + 300 ALU | 239 | 0 | 8x DPB |
| BITS=10, 128x128 | 160 Kib | 553 LUT + 308 ALU | 253 | 0 | 10x DPB |
| BITS=8, 32x24 | 6 Kib | 389 LUT + 207 ALU | 198 | 0 | 1x DPB |

\* LUT-class = LUT1..8 + MUX2_LUT5 + ALU; worst config ~860 LUT-class,
0 DSP — well inside the <=15K LUT / <=4 DSP budget. Yosys reports
`mapping memory ... via $__GOWIN_DP_`: DPB is the actual Gowin dual-port
BSRAM primitive (1 read + 1 write port), matching the bandwidth proof.
Remaining synth warnings are the vendor brams_map.v port-padding notes
and ABC's combinational-network note; no latch or width warnings.
Timing/P&R not run.

## Limitations

- Reference store is internal RAM only: `W*H <= 65536` pixels, and the
  array is *always* sized `MAX_W*MAX_H*BITS` regardless of the runtime
  dims in use (smaller frames leave tail entries untouched).
- The literal `bg += (cur-bg)>>alpha` rule cannot converge upward through
  residuals `< 2^alpha`: parked error up to `2^alpha - 1` LSB (exact from
  above). Choose alpha so `2^alpha - 1` is below the mask threshold or
  accept the residual.
- Seed frames emit all-zero masks (they cannot know the previous scene);
  a dims change forces a seed frame — schedule re-seeding deliberately.
- Single reference store: no separate "clean background freeze" image;
  a paused/disabled update mode is not provided (use `thresh`/`scn=128`
  and stop feeding frames, or an external mux).
- Markers are checked at the take edge; a malformed beat that is never
  accepted is not flagged (source contract violation handling is out of
  scope, same as sibling cores).
- `scpol` FAST_ADAPT can cascade a second scene event on the adapt frame
  (by construction; deterministic and modelled bit-exactly).
- Single `clk`, synchronous `rst_n`; reset drops in-flight pixels and
  pending config (exercised by the mid-stream reset epoch).
- No P&R, timing or board evidence yet; BSRAM inference is from mapped
  `synth_gowin` cells, not placed silicon.
