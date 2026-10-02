# Biquad / SOS resource-oriented reference

Complete DF-II Transposed cascade with runtime1..4 sections, signed18 Q3.15
coefficients, signed16 data, atomic updates, explicit clear/retain state policy,
Jury stability screening and nearest-even/saturating conversion. `SPEC.md` defines
all interfaces and bounds. The shared multiplier configuration has latency/II
7*S+1 cycles: 8/15/22/29. **II=1 target remains unqualified.**

Reproduce from repository root:

```
python cores/signal_processing/dsp_isp_library/dsp/biquad/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/biquad/tests/test_frequency.py
python cores/signal_processing/dsp_isp_library/dsp/biquad/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/biquad/tests/synthesize.py
python cores/signal_processing/dsp_isp_library/dsp/biquad/models/gen_coeffs.py --cutoff 2000 --sections 4
```

Independent DF-I float and DF-I integer recurrences cross-check the integer
DF-II-T model. `evidence/model_validation_signed.json`: 48 vectors x4096 samples,
signed coefficient extremes, stable poles near both margin boundaries, cascade,
continuous saturation, reset and retain-switch transient. Zero-tail peaks after
16000 zeros include lowpass4 LSB, four-section lowpass16 LSB and near-margin
first-order512 LSB. These are real measured quantization deadbands, not exact-zero
settling claims. Larger precision is a future option. Arbitrary coefficient
switching or overload stability is not proven by a linear Jury check.

`evidence/frequency_validation.json`: eight steady-state tones, analytic complex
transfer function versus bit-exact waveform, absolute gain error <0.003.
Coefficient generator validates quantized stability and emits atomic payload;
multiple identical sections change combined cutoff and are reported explicitly.

RTL `evidence/rtl_20260925_032757_874431/summary.json`: MAX_SOS1/2/3/4 each
36000 cycles, all active section counts, randomized handshake, busy config,
reset interruption, clear/retain, invalid coefficient/count rejection and six
executable negative checker fixtures. Static MAX_SOS0/5 are also rejected.
Golden vectors are generated before simulator runs; no DUT output creates oracle.

Isolated `synth_gowin -noalu` evidence in
`evidence/synth_20260925_032655_363788/summary.json`:

| MAX_SOS | LUT1–4 | FF | MULT18X18 | BRAM | wide mux (separate) |
|---|---:|---:|---:|---:|---:|
| 1 | 488 | 299 | 1 | 0 | 36 |
| 4 | 1579 | 787 | 1 | 0 | 187 |

Source SHA-256 `1b2339f709a74abab86c379636ee7f6018fba0e346b5f290716c6418daf94c20`.
Packed config is an internal integration interface; its synthesized top-level
I/O buffers are not a pin-compatible board wrapper. P&R, actual board timing,
production packaging and II1 configuration are still open. No shared files or
hardware were changed by this task.
