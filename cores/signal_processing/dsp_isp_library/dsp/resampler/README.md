# DSP01 rational/polyphase resampler

Resource-oriented functional reference for integer interpolation, integer
decimation and rational L/M conversion, L,M=1..8. See SPEC.md for the exact
finite convolution, rounding, flush, configuration and rate contract.

This is a serialized shared-multiplier design. **The II1 target is outstanding.**
There is no routed timing or physical board acceptance claim. The packed
coefficient port is an internal configuration interface, not a board pin mapping.

## Reproduce from repository root

```text
python cores/signal_processing/dsp_isp_library/dsp/resampler/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/resampler/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/resampler/tests/synthesize.py
```

Models use NumPy. RTL and synthesis scripts select the repository OSS CAD Suite.
`models/gen_coeffs.py --help` documents coefficient JSON generation.

## Evidence

- `evidence/model_validation.json`: independent floating-point and integer
  convolution models; quantized 128-tap filter spectra for all 64 ratios;
  pass/alias/image time-domain checks. Specified narrow passband error <0.5 dB
  and stop attenuation >40 dB passed. These bounds do not apply to arbitrary
  runtime coefficients or shorter filters.
- `evidence/rtl_20260925_041110_280265/`: 125104 cycle comparisons, 74 full-block
  cases, all 64 ratios, random input gaps and output stalls, extrema/saturation,
  maximum tap count, retained history after reset, atomic illegal updates,
  empty/nonempty flush and capacity. Seven corrupt-oracle checks detect data,
  valid, ready, clip, flush, count and output-order faults; four illegal static
  parameter checks reject unsupported bounds. The RTL suite uses MAX_TAPS=128
  and MAX_INPUTS=255; smaller static tap instances are synthesis-tested only.
- `evidence/synth_20260925_041041_298773/`: `synth_gowin -noalu -family gw2a`.

| MAX_TAPS | LUT1–4 | FF | MULT18X18 | BRAM | wide mux |
|---|---:|---:|---:|---:|---:|
| 16 | 1189 | 770 | 1 | 0 | 80 |
| 128 | 4099 | 4578 | 1 | 0 | 245 |

Coefficient and history registers are intentional in this reference. Their
resource cost is included; no synchronous BRAM or full-rate streaming claim is
made. Output latency after the last required input is 2K+1 cycles for K phase
taps, without stalls. Steady output interval is 2K_next+max(1,input_gap).

Source SHA256:
`5767502822fc56ce5e6987d878e217f404b4c1496680ca321d81a1222d68acc9`.
Historical evidence is retained. Integration, physical capture and a faster
architecture require separate acceptance.
