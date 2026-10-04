# ISP-16 — Canny Edge Chain (`canny_stream`)

Pixel-streamed Canny edge detector for bounded-resolution frames
(`WIDTH`,`HEIGHT` compile-time parameters, each 1..128, `WIDTH*HEIGHT<=16384`).
Input and output are the repo-standard stream contract: `tdata/tvalid/tready`
with `tuser` = SOF (first pixel of frame) and `tlast` = EOL.

> **Status note on hysteresis.** Exact Canny hysteresis is a full-frame
> connected-component flood. This core implements the documented bounded
> variant **(b): two-pass-style sweeps over an internal frame buffer** — see
> §6. It is bit-exact against `models/model.py`, which also computes the exact
> flood for error quantification.

## 1. Block diagram

```
pixels ──▶ [W1] 3x3 padded window (PIXEL, PAD_MODE)
           │  per-pixel combinational:
           ▼  Gaussian smooth [1 2 1;2 4 2;1 2 1]/16 (cfg_smooth) or bypass
        [W2] 3x3 padded window (SMOOTHED pixel)
           │  per-pixel combinational: Sobel Gx,Gy -> L1 magnitude,
           ▼  8-sector direction fold -> 4 NMS sectors
        [W3] 3x3 padded window (packed record {sec[1:0],avalid,mag})
           │  per-pixel combinational: NMS -> double threshold -> class
           ▼
        FRAME BUFFER fb[NP] (2-bit class per pixel, SDP BSRAM)
           │  PASSES alternating serpentine hysteresis sweeps
           ▼
        READOUT: edge mask stream (0 / all-ones), raster order, II=1
```

W1/W2/W3 are `infra/window/stream_window_padded` instances (reused, unchanged;
K=3). Frames are fully serialized: while a frame is in hysteresis or readout,
`s_tready=0` (`busy=1`).

## 2. Interfaces and configuration

| Port | Meaning |
|------|---------|
| `s_tdata/tvalid/tready/tuser/tlast` | pixel stream in, `BITS` bits |
| `m_tdata/tvalid/tready/tuser/tlast` | edge mask out; `tdata` = `{BITS{1}}` on edge else `0` |
| `cfg_valid/cfg_ready` | config handshake; **accepted only while idle** (`busy=0`) |
| `cfg_t_lo`, `cfg_t_hi` | weak/strong thresholds, `MB=BITS+3` bits, on the L1 magnitude scale (0..8·maxpix) |
| `cfg_smooth` | 1 = 3×3 Gaussian (`[1 2 1;2 4 2;1 2 1]`/16, round-half-up); 0 = bypass smoother (sigma→0 mode) |
| `cfg_reserved` | must be `00` else `cfg_error` |
| `cfg_done`, `cfg_error` | accept / reject pulses |
| `marker_error` | sticky stream-protocol violation (SOF/EOL), from the window cores |
| `busy` | frame in progress |

Illegal configs pulse `cfg_error` and are not applied: `cfg_reserved!=0`,
`cfg_t_lo > cfg_t_hi`. Illegal static params (`BITS∉{8,10}`,
`WIDTH/HEIGHT∉[1,128]`, `NP>16384`, `PAD_MODE∉{0,1}`, `PASSES∉[1,16]`) abort
at elaboration (`$fatal`).

Parameters: `BITS`, `WIDTH`, `HEIGHT`, `PAD_MODE` (0=zero, 1=replicate — applied
to all three window stages), `PASSES` (serpentine hysteresis sweeps).

## 3. Fixed-point derivation (stage by stage)

Let `M = 2^BITS - 1`.

* **Smooth (S1).** `acc = Σ k·p`, `k ∈ {1,2,4}`, `acc ≤ 16M` (BITS+4 bits).
  `s = (acc + 8) >> 4` — round-half-up, `s ≤ M`, never overflows.
* **Sobel (S2).** `Gx = (p2-p0)+2(p5-p3)+(p8-p6)` on smoothed pixels;
  `|Gx|,|Gy| ≤ 4M` → signed `MB+1` bits (`MB=BITS+3`).
* **Magnitude (S2).** `mag = |Gx| + |Gy| ≤ 8M`, `MB` bits. **This is the L1
  magnitude, not the Euclidean magnitude** — the same documented
  approximation class as `isp/gradient`'s `l1` mode. NMS compares L1 with L1
  so it is self-consistent; thresholds are on the L1 scale.
* **Direction (S2).** Sector bound `tan(22.5°) ≈ 53/128` (0.41406 vs true
  0.41421 — the identical integer comparison used by `isp/gradient`, so both
  cores agree): `128·|Gy| < 53·|Gx|` → sector 0 (neighbours W/E);
  `128·|Gx| < 53·|Gy|` → sector 1 (N/S); else diagonal — equal signs →
  sector 2 (NE/SW pair), opposite signs → sector 3 (NW/SE pair). `avalid=0`
  when `Gx=Gy=0`.
* **NMS (S3).** Center kept iff `mag >= n1 && mag >= n2` where `n1,n2` are the
  two neighbours along the quantized gradient sector. **Tie rule: `>=` —
  plateau edges keep both pixels** (documented; strict `>` would thin ridges
  but can drop valid maxima). Flat pixels (`avalid=0`) forced to class NONE.
* **Double threshold.** `mag >= t_hi` → EDGE(2); `mag >= t_lo` → WEAK(1);
  else NONE(0). `t_lo == t_hi` legal (weak set empty).
* **Padding.** `PAD_MODE=0`: outside pixels contribute `0` (window 1/2) or
  record `{sec=0,av=0,mag=0}` (window 3) — creates real border gradients that
  can produce border edges (documented Canny behaviour under zero pad).
  `PAD_MODE=1`: edge replication (replicated records at window 3 copy the
  border magnitude/sector).

## 4. Hysteresis — what it is

Class bitmap is stored in `fb` (NP×2-bit, one BSRAM SDP block). `PASSES`
sweeps, alternating direction (pass 0 forward raster L→R,T→B; pass 1 backward
R→L,B→T; ...). Within a sweep a WEAK pixel is promoted to EDGE iff any
8-neighbour is EDGE, where:

* **causal** neighbours (already visited this sweep: `prow` row + `prev_prom`)
  see *this-pass* promotions — propagation along scan-causal paths is
  unbounded within one sweep;
* **anti-causal** neighbours (not yet visited: `crow`, `nrow` stored values)
  count only when already EDGE at sweep start (incl. promotions from earlier
  sweeps — they are written back as EDGE).

This is exactly a serial flood bounded to `PASSES` scan-direction reversals;
the model implements identical in-place semantics.

## 5. Hysteresis — what it is NOT (error bound vs exact Canny)

Exact hysteresis keeps every WEAK pixel 8-connected (transitively) to any EDGE
pixel. The bounded mode drops a weak pixel when **every path** from it to an
anchoring EDGE requires more than `PASSES` sweep reversals. Concretely, a weak
chain that zig-zags `r` times against the current sweep direction needs at
least `r+1` sweeps.

Quantified example (model, `h=9` snake, 11 weak pixels, 2 reversals):

| PASSES | promoted | diff vs exact |
|--------|----------|---------------|
| 1 | 4 | 7 |
| 2 | 10 | 1 |
| 3+ | 11 | 0 |

On all test-suite frames (steps, diagonals, rings, corners, noisy edges,
fading lines) `diff_vs_exact = 0` — recorded per case in
`evidence/sim_*/summary.json`. Long serpentine weak chains are the failure
mode; increase `PASSES` or accept the documented truncation.

## 6. Latency, II, throughput

Let `NP = W·H`, `P = PASSES`.

* Pass 1 (windows): ≈ `3·(W+2)(H+2)` accept+replay cycles of the padded
  windows (dominated by `stream_window_padded`'s row capture/replay), plus
  drain. W=8,H=8,P=4: 864 cycles to first output.
* Hysteresis: per sweep ≈ `2·H·W + O(W)` (row load + one-pixel-per-cycle
  process + row copy); total ≈ `2·P·NP`.
* Readout: `NP` pixels at II=1 once started.
* Total ≈ `O(NP·(2P+3))`. For 128×128, P=4 ≈ 165k cycles/frame — the
  frame-serialized two-buffer design trades throughput for the frame buffer;
  there is no pipelined overlap between frames.

## 7. Resources (yosys `synth_gowin`, no `-family`)

| Config | LUT-class | FF | BSRAM | DSP |
|--------|-----------|-----|-------|-----|
| 32×24×8 pad0/1 P4 | ~6.0k | ~5.0k | 1 | 0 |
| 64×64×8 pad0 P4 | ~10.7k | ~9.1k | 1 | 0 |
| 128×128×8 pad0 P4 | ~23.9k | ~17.2k | 2 | 0 |
| 128×128×10 pad0 P2 | ~27.8k | ~20.4k | 2 | 0 |

LUT-class count includes LUT1–4 plus MUX2_LUT5/6 cells. The fabric-register
line buffers inside the three reused `stream_window_padded` cores
(`ram_style="registers"` is intentional there — see its header comment) and
the `crow`/`nrow`/`prow`/`curprom` scan arrays dominate FF/LUT cost and scale
with `WIDTH`; the class bitmap `fb` is BSRAM (`DPB`) and scales with `NP`.

**Budget note:** the ≤15k-LUT / ≤4-DSP guidance is met for WIDTH·HEIGHT up to
roughly 64×64. The full 128×128 bound is supported functionally and verified
in simulation but is **over the LUT guidance on this device**; fit larger
frames by lowering WIDTH/HEIGHT or accepting the documented cost.

## 8. Limitations

* Hysteresis is the bounded serpentine mode of §5 — NOT exact full-frame
  connectivity. `model.py:hysteresis_exact` quantifies the divergence per
  frame.
* Magnitude is L1 (`|Gx|+|Gy|`), not Euclidean — thresholds must be chosen on
  that scale.
* Direction quantization uses the 53/128 sector bound shared with
  `isp/gradient`; max sector-bound error ≈ 0.09° at the boundary.
* Frames serialize: no frame pipelining; input stalls during
  hysteresis+readout.
* No Scharr option (Sobel only); smoother is the fixed 3×3 Gaussian or
  bypass (no arbitrary sigma).
* Board-level (27 MHz timing, real capture) not yet run — simulation +
  `synth_gowin` evidence only.

## 9. Verification

`tests/test_canny.py` — iverilog `-g2012 -Wall`, 6 geometry/pad/pass cases ×
8 frames × 3 epochs (full speed, output-stall stress, input-gap stress),
randomized `ready`/`valid`, deterministic seeds, per-frame config replay,
illegal-config rejection pulses, config-retention check, marker-error check,
4 mutation classes per case (`data`,`sideband`,`count`,`order`), 8 illegal
static-parameter elaboration rejections. Synthesis: `synth_canny.py`.
