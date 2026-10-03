# FIXNOTE: fold of sqrt_pipeline16 into production statistics_stream

Date: 2026-09-25 (task fold; simulation only, no board access).

## What changed

`rtl/statistics_stream.sv` was restructured from a monolithic core with a
combinational 16-iteration `sqrt_floor()` call inside the `m_tdata` register
path into:

- `statistics_leaf` — the identical algorithm, emitting a zero RMS field and
  keeping the raw 32-bit rounded mean power in `m_tdata[95:64]`.
- `statistics_stream` (top, unchanged port list and `LOGIC_SQUARE`
  parameter) — the leaf followed by a 16-stage elastic restoring-square-root
  pipeline, one binary iteration per register stage. The remaining result
  fields and `tuser` travel as metadata and the root is merged into
  `m_tdata[47:32]` at the last stage.

Code is taken verbatim (module rename only) from the physically qualified
candidate `candidates/sqrt_pipeline16/` (`generation.json`:
`original_sha256=0905eca6…`, `stats_latency=17`), which passed the physical
DC→statistics chain test twice (11 cases each) after the combinational root
and the shallower radix-4 pipeline both failed on GW2A silicon.

## Contract changes

- Output latency: 1 → 17 cycles from producing input to `m_tvalid` (II=1,
  unchanged throughput).
- Result buffering: 1 → 17 slots (elastic); `s_tready` now stalls input only
  when the pipe is full instead of on a single held result.
- `cfg_ready` now also waits for all 17 pipeline slots to drain before a
  config is accepted (was: single output register empty).
- Numerical contract unchanged: RMS is still `floor(sqrt(mean_power))`; all
  packing, flags, rounding and tie rules are identical.

## Verification after fold

- `tests/test_rtl.py` — updated the cycle oracle to the 17-slot elastic
  model; added an RMS-field corruption negative test and coverage asserts
  (reset with in-flight results, config blocked on drain). PASS:
  `evidence/rtl_20260925_163647_186023/summary.json`, 39,000 cycles, 84 legal
  configs, 7 corrupted fixtures rejected.
- `tests/test_models.py` — PASS, unchanged (588 cases).
- `tests/synth_variants.py` — PASS:
  `evidence/synth_variants_20260925_163749_283445/summary.json`.
  LOGIC_SQUARE=0: 5544 LUT1–4 / 3820 FF / 2 MULT18X18 (was 4987/1409/2).
  LOGIC_SQUARE=1: 6606 LUT1–4 / 3820 FF / 0 DSP (was 6175/1409/0).
- `chains/dc_statistics/test_chain.py` — `--stats-latency` default updated
  1→17 (choices now 1/5/17); PASS at `chains/dc_statistics/evidence/
  sim_20260925_163928_345544/` with dc_latency=2, sliding_latency=19.

## Known follow-ups (not done in this task)

- `board/dsp_chain_harness/run.py` defaults `--stats-latency` to 1 when the
  production source is used; running that flow against the new production
  RTL requires an explicit `--stats-latency 17`. Not modified (board script).
- `requirements.json` untouched per task scope; DSP-04 ledger entries still
  reference the superseded latency-1 evidence directories.
