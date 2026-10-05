# ISP-12 ispstats: AE/AWB/AF zoned statistics with independent readout

Status: **simulation-verified** (model + RTL regression + isolated synthesis).
No P&R, timing, board or production acceptance yet — see `SPEC.md` §Limits.
This is a statistics core only; closed-loop AE/AWB/AF is explicitly **not**
claimed (that needs camera-interface evidence).  `models/ae_analysis.py`
provides the required *offline* exposure/gain suggestion and AWB/AF aid
functions.

## Files

- `SPEC.md` — full contract: pixel packing, zone grid semantics, focus
  operator, accumulator width derivation, config/reset behavior, readout
  contract, latency, resource table.
- `rtl/ispstats_stream.sv` — streaming statistics sink (zone accumulators +
  causal first-difference gradient energy + ping-pong result RAM).
- `models/reference.py` — float (exact-rational) and bit-exact references;
  direct floor zone map cross-checked against the RTL's Bresenham map.
- `models/ae_analysis.py` — OFFLINE host-side analysis model:
  `suggest_exposure_gain`, `awb_channel_gains`, `focus_scores`.  Not a
  control loop.
- `tests/test_models.py` — model self-checks → `evidence/model_validation.json`.
- `tests/tb_ispstats.sv`, `tests/test_rtl.py` — mem-driven RTL regression
  (all qualification sizes 1x1/2x2/7x5/32x24, gray+RGB, zone grids 1..8,
  edge/flat known answers, overexposure counting, random valid fuzz,
  readout pacing with bank overwrite protection, held readout checks,
  mid-frame resets, illegal configs, 4 checker mutations per case)
  → `evidence/sim_*/summary.json`.
- `tests/synthesize.py` — `yosys synth_gowin -noalu -family gw2a` resource
  runs → `evidence/synth_*/summary.json`.
- `ip_manifest.json` — machine-readable status/resources/evidence pointers.

## Quick start

```bash
python tests/test_models.py        # model contract checks (stdlib only)
python tests/test_rtl.py           # iverilog/vvp regression + negatives
python tests/synthesize.py         # isolated Gowin resource mapping
```

The testbench is driven by `input.mem`/`expected.mem`/`config.mem`/
`sched.mem`/`rsched.mem` generated from the independent model — the DUT is
never used to produce expected values.  Checker mutations (`+data`,
`+sideband`, `+count`, `+order` plusargs) must all fail or the run fails.

## Contract in one paragraph

Every accepted pixel feeds O(1) zone accumulators (strict input II=1):
zone `zx = floor(x*zones_x/img_w)`, `zy = floor(y*zones_y/img_h)` via a
single-carry Bresenham map.  Each zone record `{focus, oe, sum2, sum1,
sum0, count}` is pushed to a ping-pong result RAM at the zone's last pixel;
one cycle after a frame's last pixel, `res_new` pulses and the host reads
`zones_x*zones_y` records through `res_bank`/`res_addr` with one-cycle
synchronous-read latency.  A completed record set stays valid for one full
following frame.  Atomic config only between frames; illegal grids,
dimensions or out-of-range fields are rejected with `cfg_error`.
