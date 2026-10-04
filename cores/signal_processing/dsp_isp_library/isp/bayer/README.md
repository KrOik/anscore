# ISP-07 bayer: bilinear Bayer demosaic (RGGB/BGGR/GRBG/GBRG → RGB)

Status: **simulation-verified** (model + RTL regression + isolated
synthesis). No P&R, timing, board or production acceptance yet — see
`SPEC.md` §Limits.

## Files

- `SPEC.md` — full contract: formats, Bayer phase / ROI-origin semantics,
  interpolation kernel, boundary rule, config/reset behavior, resource table.
- `rtl/bayer_demosaic.sv` — streaming engine wrapping
  `infra/window/stream_window_padded` (K=3, REPLICATE edges, untouched
  silicon-qualified infra) with a one-stage demosaic output register.
- `models/reference.py` — float (exact-rational) and bit-exact integer
  references; pattern/origin identities and boundary taps exercised by tests.
- `tests/test_models.py` — model self-checks → `evidence/model_validation.json`.
- `tests/tb_bayer.sv`, `tests/test_rtl.py` — mem-driven RTL regression
  (all 16 phase combos, sizes 1x1..32x24 incl. 3x3 minimums, ready/valid
  fuzz, stall stability, mid-frame resets, config/mutation/illegal-parameter
  negatives) → `evidence/sim_*/summary.json`.
- `tests/synthesize.py` — `yosys synth_gowin -noalu -family gw2a` resource
  runs (RTL + window infra) → `evidence/synth_*/summary.json`.
- `ip_manifest.json` — machine-readable status/resources/evidence pointers.

## Quick start

```bash
python tests/test_models.py        # model contract checks (stdlib only)
python tests/test_rtl.py           # iverilog/vvp regression + negatives
python tests/synthesize.py         # isolated Gowin resource mapping
```

The testbench is driven by `input.mem`/`expected.mem`/`config.mem` generated
from the independent model — the DUT is never used to produce expected
values.  Marker bits, protocol fuzz and checker mutations
(`+data`/`+sideband`/`+order`/`+count` plusargs) must all behave or the run
fails.

## Contract in one paragraph

Every accepted Bayer pixel produces exactly one `{R,G,B}` output beat in the
same raster order with SOF/EOL passthrough.  The site color at `(x,y)` is set
by `pp = ((y+cfg_oy)&1, (x+cfg_ox)&1)` — the pattern (`cfg_cfa` ∈
RGGB/BGGR/GRBG/GBRG) anchored at the frame's SOF pixel and shifted by the
post-ROI origin parity.  R/B sites copy their own sample, take G from the
truncating 4-tap cross average and the other chroma from the 4-tap diagonal
average; G sites copy G and take R/B from the truncating 2-tap axial average
along whichever axis holds that color.  Edges are REPLICATE-clamped by the
window foundation — no zeros, no special cases, identical rule in the Python
reference.
