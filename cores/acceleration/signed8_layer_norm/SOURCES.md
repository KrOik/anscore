# Provenance and semantic boundary

Original ANSCORE Apache-2.0 controller, adapter, oracle, TB and bounded runner.
Only unchanged local helpers are instantiated. Root LICENSE applies and is
included in this package. No external implementation is copied or translated.

Before implementation, read PyTorch v2.9.0 source at the previously tag-resolved
fixed commit0fabc3ba44823f257e70ce397d989c8de5e362c1:
https://github.com/pytorch/pytorch/blob/0fabc3ba44823f257e70ce397d989c8de5e362c1/torch/nn/modules/normalization.py
LayerNorm doc/class states population variance and per-element gamma/beta.
Complete source SHA25640345630f4974fca9c6c3c40f43716a6205b4ffcabc2b48e49cc2942a70dd7c0.
Complete root LICENSE read, BSD3 with contributor notices:
https://github.com/pytorch/pytorch/blob/0fabc3ba44823f257e70ce397d989c8de5e362c1/LICENSE
SHA256a8a2c6b67cf8a597ffaa5c82380a6bd1b82629c0417e00673d8013d662eb500a.
Web access returnedHTTP500; official raw HTTPS reads succeeded. Those files were
read only, never imported/executed. Temporary copies are ignored and will be
individually removed after committed-source verification. Only mathematical
semantics were consulted; quantized staged rounding/epsilon units and singular
case are independently specified, with no PyTorch bit-identity claim.

Actual-source reuse reviewed before RTL:

- `../int4_weight_matvec/rtl/deps/stream_requantize.v`: ordinary ready/valid,
  synchronous high reset, three elastic stages, signed RNE then clamp.
- `../../signal_processing/dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv`:
  unsigned RNE root; iterative module only, synchronous low reset.
- `../../signal_processing/dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv`:
  signed RNE division with explicit divide-zero/clip; iterative module only.
- `../../system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v`:
  unsigned CSA/fold multiplier, CE-qualified, asynchronous low reset.

The resident INT4 matvec source was also inspected as an adjacent inference
service during deduplication; it is not in this package's dependency lists.
All reused helpers retain their own historic status; this composition requires
its own finite evidence.
