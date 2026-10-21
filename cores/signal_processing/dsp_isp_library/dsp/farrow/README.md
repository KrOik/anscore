# DSP11 cubic Farrow fractional delay

`farrow_cubic_stream` implements causal Catmull–Rom interpolation with total
nominal delay **D+1+mu** samples, D=0..31 and mu=U/4096, U=0..4096.
It has a five-stage, globally stalled pipeline: **II1, latency 5** in RTL
simulation without backpressure. History advances only for accepted samples.
See SPEC.md for the exact polynomial, rounding-width proof, startup and dynamic
configuration contract. The DSP reuse audit found no matching existing core.

This single-input/single-output delay core is **not ASRC**. Rate estimation,
asynchronous buffer management and sample-rate control remain unimplemented.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/dsp/farrow/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/farrow/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/farrow/tests/synthesize.py
```

Models require NumPy. RTL scripts use repository OSS CAD Suite binaries.

## Results and limits

- Models: 32 independent floating-vs-integer sequences, 4096 samples each;
  worst difference 0.502220 LSB. Floating model evaluates four basis weights;
  integer model rounds three guarded Horner stages and final saturation.
- Ideal polynomial frequency grid: all 4097 mu values, 1025 frequency points
  in **0..0.1 cycles/input**. Maximum magnitude error 0.030756 dB and group-delay
  error 0.019622 samples. These are sampled narrow-band polynomial metrics,
  not a full-Nyquist or physical frequency-response qualification.
- Continuity: all mu codes swept on three fixed windows, including full-scale
  alternating signs; fixed-point movement follows the saturated floating
  response within 0.51 LSB. Equivalent (D,mu=1)/(D+1,mu=0) endpoints agree.
  Arbitrary delay jumps can intentionally create discontinuities.
- RTL: **49439 cycles, 24507 accepted**, 24473 emitted and exactly 34 aborted
  by explicit reset. 433 configuration requests cover all integer delays,
  endpoint/interior and random fractional codes, retention/clear, busy updates,
  illegal requests, random stalls, long stalls and 13 reset edges. Seven
  deliberately corrupted oracle fields/orders were rejected.
- `synth_gowin -noalu -family gw2a`: **5095 LUT1–4, 846 FF, 0 DSP, 0 BRAM,
  170 wide muxes**. Three balanced logic multipliers trade LUTs for DSP budget.
  History is explicitly register storage; no BRAM claim.

Evidence:
`evidence/model_validation.json`,
`evidence/rtl_20260925_042109_267269/summary.json`,
`evidence/synth_20260925_041841_110880/summary.json`.

Source SHA256:
`25cff21ace4bdd592409bc14e43ae7e9fdc52da01e141719dc352baea4dcbbc2`.
No P&R, frequency guarantee, chain or physical board acceptance was performed.
The combinational logic multipliers need timing qualification before integration.
