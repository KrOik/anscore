# ISP-08 basic_isp: BLC, WB gains, DPC, gamma LUT, AWB stats

Status: **simulation-verified** (model + RTL regression + isolated
synthesis).  No P&R, timing, board or production acceptance yet — see
`SPEC.md` §Limits.

Pipeline: `input -> isp_blc -> isp_wb_gain -> isp_dpc -> isp_gamma -> out`,
with `isp_awb_stats` observing the post-BLC bus.

## Files

- `SPEC.md` — full contract: formats, per-stage integer rules, DPC
  detection/replacement/cluster bound, gamma table source + measured
  accuracy, external-WB vs gray-world AWB split, config/reset semantics,
  latency, resource table.
- `rtl/isp_blc.sv` — per-channel unsigned offset subtract, clamp at 0.
- `rtl/isp_wb_gain.sv` — per-channel UQ4.8 gain, round-half-up + saturate.
- `rtl/isp_dpc.sv` — 3x3 REPLICATE window (CH parallel
  `infra/window/stream_window_padded`, unmodified) + median-of-8-neighbour
  detect/replace per channel (Batcher-8 sorting network).
- `rtl/isp_gamma.sv` — 32-segment PWL gamma; node ROMs in
  `rtl/gamma_table.vh` (generated, do not hand-edit).
- `rtl/isp_awb_stats.sv` — post-BLC per-channel frame sums + `awb_new`/
  `awb_frame` (statistics source for host-side gray-world estimation).
- `rtl/basic_isp_top.sv` — composition + atomic config + busy/marker glue.
- `models/reference.py` — float and bit-exact references; per-stage
  functions, end-to-end `pipeline`, `gamma_nodes`/`emit_gamma_vh` table
  generator, `gray_world_gains` estimator, pack helpers.
- `tests/test_models.py` — model self-checks + `.vh` freshness guard →
  `evidence/model_validation.json`.
- `tests/tb_basic_isp.sv`, `tests/test_rtl.py` — mem-driven RTL regression
  (8/10-bit x CH=1/3 x 1x1..64x64; defect/cluster patterns; config sweep;
  ready/valid fuzz; stall stability; 3 mid-frame-reset epochs; AWB checks;
  marker negatives; `+data`/`+sideband`/`+order`/`+count` mutations;
  illegal-parameter builds) → `evidence/sim_*/summary.json`.
- `tests/synthesize.py` — `yosys synth_gowin -noalu -family gw2a` for the
  top at five geometries plus each stage standalone →
  `evidence/synth_*/summary.json`.
- `ip_manifest.json` — machine-readable status/resources/evidence pointers.

## Quick start

```bash
python tests/test_models.py        # model contract checks (stdlib only)
python tests/test_rtl.py           # iverilog/vvp regression + negatives
python tests/synthesize.py         # isolated Gowin resource mapping
```

The testbench is driven by `input.mem`/`expected.mem`/`config.mem`/
`awb.mem`/`sched.mem` generated from the independent model — the DUT is
never used to produce expected values.

## Contract in one paragraph

Per accepted pixel one output beat (same-size stream): black-level clamped
subtract per channel, UQ4.8 white-balance gain per channel, 3x3
median-of-8-neighbours defective-pixel detect/replace per channel, and a
33-node piecewise-linear gamma LUT (encode/decode/bypass).  AWB *statistics*
(post-BLC channel sums) are produced in hardware; the gray-world gain
*estimate* is a host-side model function — external gain application and
auto estimation are explicitly separate paths.  Atomic config only while
the pipeline is empty; sticky `marker_error` on malformed SOF/EOL.

## Resource snapshot (`synth_gowin -noalu -family gw2a`, top level)

| config | LUT1-4 | FF | DSP | BRAM |
|---|---|---|---|---|
| 8b CH3 32x24 | 5789 | 4157 | 3 | 0 |
| 10b CH3 32x24 | 6736 | 5107 | 6 | 0 |
| 10b CH3 64x64 | 10379 | 9005 | 6 | 0 |
| 10b CH1 64x64 | 3571 | 3141 | 2 | 0 |

Fabric registers throughout (no CE-gated RAM reads); DSP = WB multipliers
(+ gamma interpolators at 10-bit).  Details in `evidence/synth_*/`.
