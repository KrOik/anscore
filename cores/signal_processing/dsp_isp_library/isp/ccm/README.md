# ccm — ISP-14 color correction matrix + tone mapping

`rtl/ccm_stream.sv`: streaming 3x3 signed CCM + signed per-channel bias +
optional per-channel monotone PWL tone map, on the repository
`tdata/tvalid/tready` + `tuser`(SOF)/`tlast`(EOL) stream contract.

- Signed Q2.13 coefficients (16-bit fields, per-row `sum|c| <= 7.0` bound),
  signed 16-bit bias in pixel units, single quantization boundary
  (round-half-away-from-zero + clamp).
- 33-node / 32-segment per-channel tone PWLs in TWO shadow banks:
  `lin` (linear-light intent) and `enc` (encoded-domain intent); the
  committed `domain` bit picks the active table atomically.
- 16-bit shadow config port + `cfg_commit`: whole-image legality check,
  atomic apply at the next presented SOF once the pipe drains — no
  mid-frame mix ever.
- II=1, latency 5, synchronous low-active reset, zero DSP/BRAM.

Docs: `SPEC.md` (fixed-point derivation, address map, atomicity contract,
resource numbers, limitations).
Model: `models/model.py` (float + bit-exact + shadow/commit simulator).
Tests: `tests/test_ccm.py` (Icarus regression incl. negative and
backpressure cases), `tests/test_models.py`, `tests/synthesize.py`
(Yosys `synth_gowin -top ccm_stream`).
Evidence: `evidence/sim_*/`, `evidence/synth_*/`.
