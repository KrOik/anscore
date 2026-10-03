# DSP-03: DDC / DUC (digital down/up conversion) chains

Status: RTL + bit-exact/float simulation + isolated `synth_gowin` resource
counts **passed**.  P&R, timing and board acceptance **not yet done**.

* `rtl/ddc_stream.sv` — complex mix (`x*e^{-jphi}`) -> CIC decimate R ->
  scale -> serialized symmetric compensation FIR.  N inputs produce exactly
  floor(N/R) outputs.
* `rtl/duc_stream.sv` — compensation FIR -> CIC interpolate R -> scale ->
  complex mix (`x*e^{+jphi}`).  N inputs produce exactly N*R outputs.
* `rtl/ddcduc_nco.sv` — shared 32-bit phase-accumulator NCO, quarter-wave
  case-ROM sin/cos, ~-38 dBc spur bound.
* `rtl/ddcduc_iq_fir.sv` — shared I/Q symmetric FIR, one shared multiplier
  (2*U+3 clocks per pair), taps=1 bypass or odd 3..31.
* `models/model.py` — float + bit-exact chain references, CIC-comp
  coefficient designer, DFT helpers, NCO spur bound.
* `tests/test_ddcduc.py` — iverilog -g2012 -Wall suite (19 cases, seeded).
* `tests/synthesize.py` — isolated resource mapping.
* `SPEC.md` — stage math, bit growth, gain budget, rate/II contract,
  provenance, limitations.

Per-core resources (N=3): ~5.0K LUT / ~2.1K FF / 4 DSP / 1 BSRAM (DDC FIFO);
each core alone meets the <=15K LUT, <=4 DSP image guidance.  Reproduce:

```sh
python cores/signal_processing/dsp_isp_library/dsp/ddcduc/tests/test_ddcduc.py
python cores/signal_processing/dsp_isp_library/dsp/ddcduc/tests/synthesize.py
```
