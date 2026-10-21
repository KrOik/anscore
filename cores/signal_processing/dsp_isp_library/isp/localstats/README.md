# ISP-10 localstats: integral image, local statistics, adaptive threshold

Status: **simulation-verified** (model + RTL regression + isolated synthesis).
No P&R, timing, board or production acceptance yet — see `SPEC.md` §Limits.

## Files

- `SPEC.md` — full contract: formats, window semantics, accumulator width
  derivation, config/reset behavior, latency/II, resource table.
- `rtl/integral_stats.sv` — streaming engine (integral image + column/row
  sliding sums + sideband statistics + binary output stream).
- `rtl/adaptive_threshold.sv` — combinational mean/var quantizer and exact
  `(pixel+C)*area > wsum` threshold decision.
- `models/reference.py` — float (exact-rational) and bit-exact references;
  integral-path and direct-path window sums cross-checked in tests.
- `tests/test_models.py` — model self-checks → `evidence/model_validation.json`.
- `tests/tb_localstats.sv`, `tests/test_rtl.py` — mem-driven RTL regression
  (all qualification sizes, rectangular windows 1..15, patterns, C sweep,
  ready/valid fuzz, stall stability, mid-frame resets, config/mutation/
  illegal-parameter negatives) → `evidence/sim_*/summary.json`.
- `tests/synthesize.py` — `yosys synth_gowin -noalu -family gw2a` resource
  runs → `evidence/synth_*/summary.json`.
- `ip_manifest.json` — machine-readable status/resources/evidence pointers.

## Quick start

```bash
python tests/test_models.py        # model contract checks (stdlib only)
python tests/test_rtl.py           # iverilog/vvp regression + negatives
python tests/synthesize.py         # isolated Gowin resource mapping
```

The testbench is driven by `input.mem`/`expected.mem`/`config.mem`/`sched.mem`
generated from the independent model — the DUT is never used to produce
expected values. Marker bits, protocol fuzz and checker mutations
(`+data`/`+sideband`/`+order`/`+count` plusargs) must all behave or the run
fails.

## Contract in one paragraph

Every accepted pixel produces exactly one output beat (same-size, strict
II=1, no drain): the trailing clipped window `rows max(0,y-WH+1)..y ×
cols max(0,x-WW+1)..x` yields `wsum/wsq/area/mean=floor/var/bin` where
`bin = (pixel+C)*area > wsum` is the exact mean-C decision and `m_tdata`
is the all-ones/zero binary image. Sidebands expose the integral image
(`isum`,`isq`) and all statistics. Atomic config only between frames.
