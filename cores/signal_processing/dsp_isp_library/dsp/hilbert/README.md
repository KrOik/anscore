# DSP12 Hilbert analytic-signal core

`hilbert_core` produces the analytic pair (I,Q), envelope, instantaneous
phase and instantaneous frequency from a signed16 real stream.
Architecture: 63-tap antisymmetric Hilbert FIR evaluated by **LANES=4
shared multipliers** (4 rounds/sample, II=5 clocks), group-delay-aligned
I path, a pipelined first-octant restoring divider + 257-entry atan LUT
for phase, a sigma=+/-1 CORDIC x-path for the envelope, and a wrapped
first-difference frequency estimator. See SPEC.md for the exact
numerical, band, zero-amplitude, unwrap and stall contracts. The DSP
reuse audit found no matching existing core (CORDIC arithmetic candidate
only; not reused because it lacks the Stream/reset contract).

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/dsp/hilbert/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/hilbert/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/hilbert/tests/synthesize.py
python cores/signal_processing/dsp_isp_library/dsp/hilbert/models/gen_coeffs.py --pairs 16
```

Pure stdlib Python 3 (no NumPy). RTL scripts use the repository
OSS CAD Suite binaries; the scripts set `PATH=<oss>/lib;<oss>/bin;System32`
because external MinGW DLLs on the caller PATH break iverilog/yosys
(0xC0000135/0xC0000139).

## Results and limits

- Models: in-band tones 0.05..0.45 cyc/sample -> envelope error <0.2%,
  phase slope error <3e-5 cyc/sample, instantaneous frequency error
  <2e-5 cyc/sample; Q vs float reference <2.3 LSB. Envelope CORDIC:
  <=0.026% rel (mag>2000); atan LUT+interp: <=1.02 brads (mag>32).
  Out-of-band envelope/frequency degradation recorded (FIR rolloff +
  residual negative-frequency image).
- RTL: **45337 cycles, 9035 accepted, 8973 emitted**, 62 aborted by
  explicit resets. Covers in-band/edge tones, DC, zero, full-scale
  saturation (clip flag), random noise, runtime pair-count/coefficient
  reconfiguration (8 and 4 pairs), retain/clear history, illegal configs
  (pairs 0,17,32,33 -> cfg_error), back-to-back accepts, random stalls,
  10 mid-stream resets. Nine corrupted fixtures/parameters rejected.
- `synth_gowin -noalu -family gw2a` (default config): **6663 LUT1-4,
  3978 FF, 4 MULT18X18 (dsp=4), 0 BRAM, 782 wide muxes** — at the <=4
  DSP-class budget and well under 15K LUT-class. LANES=2 build:
  6293 LUT, 3978 FF, 2 DSP. PAIRS=8/LANES=4: 5779 LUT, 3186 FF, 4 DSP.
  History is register storage; no BRAM claim.

Evidence:
`evidence/model_validation.json`,
`evidence/rtl_20260925_110609_216718/summary.json`,
`evidence/synth_20260925_110642_636620/summary.json`.

No P&R, frequency guarantee, chain or physical board acceptance was
performed. The 16-deep pair-product MAC critical path needs timing
qualification before integration; `-nodsp` builds map the four `*`
lanes into LUTs instead.
