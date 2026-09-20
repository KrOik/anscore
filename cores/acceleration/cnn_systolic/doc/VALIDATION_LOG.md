# CNN_FPGA on GW2A-18C — Validation Log

## 2026-09-25: spatial-sum depths 1/2 repaired and board-qualified

Added pending-write forwarding and explicit collision bypass to the short-row
path of production lprnet_spatial_sum.v. Existing synchronous RAM, first-row
zeroing, three-edge output latency, row-marker timing and clk_en/reset behavior
are preserved; depths >=3 use the prior path.

48 independent parameter/stall/reset cases PASS. Full sixteen-unit selftest,
original UART report, 13 output accumulation regressions and board harness
simulations PASS. Original SSUM digest remains 77330EC1.

New raw-results board: original 212 identical incorrect frames; fixed 213 and
reprogrammed fixed 212 complete frames PASS (10,200 checked signed values).
Legacy SSUM-only image passes two complete reports. No expected values or
verifier acceptance rules were relaxed. Board UART is observed on A11 at
115200 baud using fresh 4 MHz sigrok captures.

Board wrapper resources: 1276 -> 1368 routed LUT4, 909 -> 912 FF,
4 BRAM / 0 DSP unchanged; routed Fmax estimates 207.00 -> 179.28 MHz,
both above 27 MHz. Isolated depth-8 resources are unchanged. This is a
correctness repair, not an area optimization or measured Fmax improvement.

Evidence, commands and hashes: `artifacts/ip_optimization_20260925/spatial_sum_fix/`.
Final SRAM is `board_legacy/spatial_sum.fs`, mask 0x4000 (SSUM only).
Earlier entries documenting the unfixed short-row failure are historical.

## 2026-09-25: pending CNN candidate board qualification

Fresh `artifacts/ip_optimization_20260925/physical/` captures after USB
reconnection qualify three previously simulated/built changes at 27 MHz:

- PAGES=10 output original: 303 identical incorrect frames; candidate and
  reprogrammed candidate: 303 complete correct frames each. Legacy OL
  46E9E19D / LAYR 9A9AEA61: two full reports PASS.
- Input gaps: baseline 68 incorrect frames, first payload byte 03 vs 04
  matching simulation. Candidate 69 frames, reprogrammed candidate 68 frames
  PASS including captured edge fragments. Legacy IL 41C4C21F / LAYR
  9A9AEA61: two reports PASS with serial digest harness.
- Activation auto, logic and reprogrammed logic: 87 complete blocks each,
  all 8192 addresses checked. Existing routed metrics: 2154 vs 2142 LUT4,
  4 vs 0 BRAM, no DSP. No silicon Fmax claim.

Rejected captures and original failure records are retained; initial UART
synchronization failures were resolved by new captures, not relaxed checks.
No COM24 evidence was used. Input and activation RTL remain isolated even
though their board candidates passed. See central IP_OPTIMIZATION_STATUS.md
for acceptance scope and pending integration. Last SRAM image: activation
logic ALT1 scan. No new synthesis or production RTL changes this session.

The next spatial-sum audit independently reproduces wrong three-row sums at
BRAM depths 1 and 2 (4 FAIL / 8 PASS in the 12-case matrix). It has not been
repaired or physically qualified. See `scripts/test_cnn_spatial_sum.ps1` and
`artifacts/ip_optimization_20260925/spatial_sum_repro/`.

Source: `external/CNN_FPGA` (`rtl_pds` branch of modules), adapted for
Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7, 27 MHz on-board oscillator).

## Board validation result — PASS (16/16 units)

The full 16-unit selftest exceeds placement capacity (LUT4 19105/20736, 92%),
so it is split by the compile-time `UNIT_EN` mask into two bitstreams:

| bitstream | mask | units | board UART result |
|---|---|---|---|
| `build_oss/cnn_systolic_20k_m00ff.fs` | `16'h00ff` | 0–7 | all P — `doc/board_uart_m00ff.txt` |
| `build_oss/cnn_systolic_20k_mff00.fs` | `16'hff00` | 8–15 | all P — `doc/board_uart_mff00.txt` |

Report format: `U<idx> <name> <P/F/S> D=<FNV-1a digest>`. `S` = unit skipped
by mask (digest stays at FNV offset basis `811C9DC5`).

### Golden digests (cross-checked by `tools/golden_model.py`)

PE/PED `B865EC67`, DM `783B6C25`, WM `6A9E1AC5`, RAM `2339D078`,
FIFO `D0C7C975`, COL `D149A670`, PAGE `C5BAB594`, POOL `35A02396`,
ALUT `830A5F5F`, IL `41C4C21F`, OL `46E9E19D`, LAYR `9A9AEA61`,
EXTR `931885AA`, SSUM `77330EC1`, CTC `ED74208A`.

### Resource utilization (nextpnr, `doc/utilization_ab.txt`)

| mask | LUT4 | ALU | DFF | BSRAM | DSP |
|---|---|---|---|---|---|
| 00ff | 8506/20736 (41%) | 2318 | 1453 | 1/46 | 1 |
| ff00 | 11164/20736 (53%) | 3036 | 4489 | 28/46 | 1 |

## Timing fix history

1. First board run: WM (`U3`) reported `D7AD69A5` instead of `6A9E1AC5`.
   A diagnostic top (`sim/diag_wm_top.v`, `build_oss/diag_wm.fs`,
   `build_oss/wm_dump.txt`) proved the raw `W_out` byte stream on hardware
   was exactly correct — the corruption was in the selftest's nested
   32-bit FNV fold: ~8 chained `fnv()` calls form a ~40-level add tree that
   cannot settle in one 27 MHz clock.
2. Fix: `ce` clock-enable divider in `cnn_selftest.v` — one logical beat per
   16 clocks; all DUT `clk_en` pins get `ce || !rst_n` (free-run during reset
   keeps pipeline warm-up identical to the original), all stimulus/capture
   `always` blocks are `ce`-gated. FNV prime `0x01000193` is expanded to
   shift-add form (same digest, no DSP inference).
3. Regression found by sim: `input_layer.line_out_valid` was the only
   register not gated by `clk_en`; its 1-clock delay collapsed to 0 beats
   in ce-space and shifted kernel window data by one column (x propagation,
   IL/LAYR digests unknown). Fixed by `else if (clk_en)` in
   `src/input_layer.v:80-86`.
4. Rebuilt both bitstreams; board re-run: **all units P** on both halves.

## Simulation status

- `sim/tb_cnn_selftest.v`: PASS for `UNIT_EN` = `FFFF` / `00FF` / `FF00`.
- `sim/tb_top_uart_report.v`: PASS vs `sim/expected_report_a.mem`,
  `sim/expected_report_b.mem` (544-byte reports).
- TB verdict hardened: `RESULT: PASS` requires
  `all_done && all_pass && !any_fail`; `pass_r`/`done_w` compared with
  `===`/`!==` so unknown digests fail rather than slip through.

## Known limitations

- nextpnr-gowin does not run timing analysis for this flow; the ce divider
  is the mitigation. Critical path observed ~25 ns at 27 MHz.
- `layer` (non-direct variant with hard-coded `mem_data/` paths) is excluded
  from synthesis via `` `ifndef SYNTHESIS ``; simulation still covers it.
- `sim/diag_wm_top.v` is a diagnostic top kept for reference (not part of
  the shipping bitstreams).

## On-board timing + dataflow measurement (cnn_meas_top)

Dedicated measurement harness `src/cnn_meas_top.v` runs `lprnet_layer_direct`
(full conv layer: input_layer + pe_page + output_layer) and a standalone
`input_layer` in parallel at FULL clock rate (`clk_en=1`, no ce divider),
fed with the same 6x8x2ch stimulus as selftest unit 12. Hardware counters
record cycle-accurate timing; raw output streams are captured in BSRAM and
reported verbatim on UART (954-byte report: 64B header + "IL>" + 720B +
"LY>" + 160B).

### Measured timing (clk cycles, identical sim vs board @27 MHz)

| Field | Value | Meaning |
|---|---|---|
| T[0] | 41 (0x29) | first data_input_valid -> first IL window_valid |
| T[1] | 59 (0x3B) | first data_input_valid -> first layer output_valid |
| T[2] | 150 (0x96) | IL window_valid span (40 windows) |
| T[3] | 151 (0x97) | layer output_valid span (80 beats) |
| G | 1 / 19 | min / max gap between consecutive output_valid |
| N | 40 / 80 / 5 | IL windows / layer beats / new_line_out pulses |
| F | 212 (0xD4) | full frame: first nl -> done |

Header captured on board: `MEAS T=0029,003B,0096,0097 G=0001,0013 N=0028,0050,0005 F=00D4`
(byte-identical to simulation header -> RTL and hardware agree cycle-for-cycle).

### Dataflow verification

- IL stream: 40 windows x 18B = 720 bytes, byte-exact vs
  `tools/golden_model.py` functional model (zero-padding 3x3 stride-1).
- LY stream: 80 beats x 2B = 160 bytes, byte-exact vs golden model
  (all-1 weights, bias=8, >>4 rounding, ReLU, sat8, CPO=2 dup beats).
- Both streams verified byte-for-byte on the physical board:
  `doc/board_meas_capture.bin` (954 B).

### Timing margin check @54 MHz (rPLL 27->54)

`USE_PLL=1` variant multiplies the core clock to 54 MHz via rPLL
(`src/meas_pll.v`, gowin_pll params IDIV=0/FBDIV=1/ODIV=16).
Board result: `doc/board_meas54_capture.bin` — all 880 payload bytes
byte-exact, all counters identical except T[0]=42 vs 41 (one dclk of
async-reset-release phase jitter, expected and benign). The CNN datapath
is byte-exact at 2x the required clock -> >100% timing margin at 27 MHz.

### Resources (nextpnr, cnn_meas_top @27 MHz)

LUT4 3565/20736 (17%), DFF 3633/15552 (23%), BSRAM 29/46 (63%), DSP 0.

### Notes

- Capture buffers sit in BSRAM: mem ports must live in pure `posedge clk`
  blocks (no async reset), reads need a dedicated address register, and
  widths must match Gowin BRAM port widths (36b banks + 18b pad). 
- Files: `src/cnn_meas_top.v`, `src/meas_pll.v`, `src/cnn_meas.cst`,
  `sim/tb_cnn_meas.v` (PASS), `tools/gen_meas_golden.py`,
  `sim/meas_expected_{il,ly}.mem`, `build_oss/cnn_meas{,54}.fs`.

## 2026-09-23 Logic analyzer channel calibration (fx2lafw 8ch)

Probe bitstream `build_oss/la_probe.fs` (`src/la_probe_top.v`):
one-hot rotating 65536-clk time slots on dock pins A11,B11,N6,D11,N9,N7,
L9,N8. Captured 50 ms @1 MHz via sigrok-cli (device = USB fx2lafw
1D50:608C, not a COM port). Decoded `doc/la_probe_capture.bin`:

| LA ch | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 |
|---|---|---|---|---|---|---|---|---|
| pin | A11 | B11 | N6 | D11 | N9 | N7 | L9 | N8 |

8/8 sequential mapping, no cross/silent channels. Details + decode
script in `doc/logic_analyzer.md`.

## 2026-09-23 Remote CPU-only P&R (Slurm, cpu8358/52cores) — COMPLETED

Resource class: **CPU-only** per project policy — partition `cpu8358`,
QoS `52cores`, account `yuema02_rbe309`, 16 CPUs/job, no GPU. Earlier
GPU-queue submissions (2984959–61) were cancelled; first CPU batch
(2984967/69/70) FAILED because remote `yowasp-nextpnr-gowin` is the
legacy gowin backend — its GW2A-18 device model lacks SPX9 BELs for
himbaechel-format netlists ("no BELs remaining to implement cell type
'SPX9'" -> wasm `unreachable` trap).

Fix: deployed OSS CAD Suite linux-x64 2026-09-22 to
`~/tools/oss-cad-suite/` (same toolchain as local;
`yowasp-nextpnr-himbaechel` does not exist on PyPI and the IIC-OSIC
sif only ships ice40). `remote_fpga_pnr.py` gained `--nextpnr` (himbaechel
`--vopt` arg syntax auto-selected by binary name) and plain-sbatch
`--cpu` mode.

Final CPU jobs, all `COMPLETED` + `0:0` (sacct), manifests + routed
JSON + logs fetched to `build_oss/remote_*/`:

| job | task | runtime | post-route max freq (final) | @27 MHz |
|---|---|---|---|---|
| 2984984 | cnn-meas-hb | 55 s | **56.77 MHz** | PASS |
| 2984985 | cnn-m00ff-hb | 55 s | **36.45 MHz** | PASS |
| 2984986 | cnn-mff00-hb | 125 s | **19.00 MHz** | **FAIL** |

Key readings:

- **meas**: post-route STA 56.77 MHz is consistent with the 54 MHz rPLL
  board test passing byte-exact — remote STA and physical margin agree.
- **m00ff (A half)**: STA-clean at 27 MHz (36.45 MHz).
- **mff00 (B half)**: STA fails at 27 MHz (19 MHz) — the critical path
  is the deep `selftest.digests[*]` FNV ALU carry chain (~52 ns). The
  bitstream still passes on board **because `ce`÷16 gives every
  combinational settle 16 clock periods**; STA assumes single-cycle
  paths. This is direct post-route evidence that the ce architecture is
  required, and that unit-level IP data paths (not the selftest digest
  harness) are what carry timing guarantees.
- Remote nextpnr-himbaechel run gives post-route STA (local wrapper
  flow reports none) — use remote P&R as the STA evidence step.

Caveat: `post_route_max_frequency` in the three manifests is null — the
manifest regex in the job template had a double-escaped `\s` in the
raw-string template (fixed in `remote_fpga_pnr.py`; the fetched
`nextpnr.log` files above are the authoritative record).

## 2026-09-24: single-output-slot accumulation repair

`output_layer` lost earlier input slots when CYCLE_PERIOD_OUT=1 and
CYCLE_PERIOD_IN>1 because feedback was forced to zero. A new independent
signed-sum test expects -21 but the preserved original returns the last-slot
sum 3. Physical baseline capture confirms that exact error. The repaired core
uses the preceding accumulator directly for CPO=1 and keeps the existing
clear condition and multi-output-slot delayed feedback.

`scripts/test_cnn_output_optimization.ps1 -OutputDir <fresh-directory>` passes
eight parameter configurations, signed sums, column alignment, enable stalls,
all 16 original digests, the complete full-mask UART report and two full-rate
raw-output UART frames. An initial driver mismatch used a half-mask report
fixture with a full-mask DUT; the corrected driver generates the correct mask
from the original constants in its fresh output directory. No historical
golden values, source fixtures or baseline logs were rewritten.

Two physical 27 MHz / clk_en=1 captures across reprogramming pass 604 frames
and 9664 signed values (CPO=1, CPI=3, pages=2, columns=2). A separate legacy
mask-0x1800 image passes five complete reports with OL `46E9E19D` and LAYR
`9A9AEA61`; its other units are explicitly skipped. Full-mask coverage for
the other units is simulation, not a new all-unit board claim.

Same-tool -noalu raw-output top: routed LUT4 478 -> 600, FF 524 -> 557,
DSP/BSRAM 0/0. Fixed raw-output top post-route estimate 138.29 MHz; actual
operation tested at 27 MHz. Integrated OL/LAYR image: 3130 routed LUT4,
2868 FF, 0 DSP, 12 BSRAM, post-route estimate 105.27 MHz. Resource gates PASS.
This is a correctness repair with area cost, not an area reduction.

Sources, scripts, `.fs`, `.sr`, decoded UART and verdicts are under
`artifacts/ip_optimization_20260924/cnn_output/` from repository root. Exact
commands and changed files are in `docs/IP_OPTIMIZATION_STATUS.md`.
Use `build_cnn_output_optimization.ps1` for fresh budget-gated -noalu images;
the historical build script is retained unchanged. The new script checks both
the synthesis count and routed LUT4 count (storage packing can increase it).

A second FTDI adapter caused default openFPGALoader selection to fail during
this session. USB scan plus `--busdev-num 1:2 --detect` identified the actual
GW2A(R)-18(C) target (ID 0x81b), and explicit selection restored access without
driver changes. Bus addresses must be rediscovered if enumeration changes.
The board ends this phase running the verified mask-0x1800 image.

## Pending follow-up: output-layer page counts above nine

An independent 10-page test found that the old fixed three-by-three partial
sum groups drop page index 9 onward (-44 instead of -33 in the reproducer).
The working core now sizes three contiguous groups to cover all pages while
retaining the original groups for <=9 pages and preserving pipeline timing.
Thirteen signed-sum/parameter cases (including 9/10/12/16 pages and saturation),
all 16 original digests, full-mask UART and the 10-page raw-UART bench pass.

Ready -noalu images: 10-page baseline 964 LUT4 / 645 FF, repair 1117 LUT4 /
681 FF (both zero DSP/BSRAM); OL/LAYR image 3114 LUT4 / 2910 FF / 0 DSP /
12 BSRAM. Actual parameter-specialized top modules were selected and resource
gates rechecked; the build script now rejects a missing top instead of counting
zero resources. Physical validation has NOT passed and no new image was
programmed: FactoryAIOT JTAG USB bulk transfers failed before initialization.
Low-speed retry and libusb reset did not recover access; Windows interface
restart was denied. User cable reconnection was requested. Logs, snapshots,
bitstreams and the released pending-session lock are under
`artifacts/ip_optimization_20260924/cnn_output_pages/`. Resume the baseline,
candidate/reprogram and legacy capture checks after USB recovery; do not
extend earlier two-page physical claims to this pending implementation.
