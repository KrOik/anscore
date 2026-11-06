# Provenance and semantic review

Original ANSCORE Apache-2.0 controller, boot example, independent integer oracle,
TBs and finite runner. The repository license is included. No external code
was imported, translated or executed.

Repository RTL, README, SPEC and catalog search before implementation found no
complete attention service. Existing `int4_weight_matvec` supplies resident
packed low-precision scores but no softmax/value reduction. Existing
`ips_softmax_fixed` consumes three repeated CE-qualified logit passes and has no
resident key/query/value interface. Sparse matvec and YOLO convolution do not
perform content-dependent token mixing. Actual source inspection established
numeric formats, LUTs, CE retention and transaction boundaries before authoring.
ARCHITECTURE.md records the pre-implementation tradeoff and bounded resource plan.

Unchanged dependency bytes, anchored to baseline
`8ba6835fe51ad285b926cd24e3ba4d172aefce26`:

| Source | SHA256 |
|---|---|
| `../int4_weight_matvec/rtl/int4_weight_matvec.sv` |26427a8358b31885ff3dd82756043055369dbfc155a1d4df3dcfb72bdd9ece55 |
| `../int4_weight_matvec/rtl/deps/stream_requantize.v` |fdb7cb0fd3800694cd21f322c1cdfd7c8cba686d269fb7e0fe146a47cb0826a2 |
| `../integer_divider/rtl/integer_divider.v` |e09b6e9501a02fbcb0a89be50b5a0b787c71e9180b934b32d446601a299c5f6c |
| `../../system/ip_series/src/ips_softmax_fixed.v` |fea4476aca92817c9907aa249c63021148d289a9875868577e90609be0b17b4f |

The matvec/quantizer were already in B35's canonical list. B35 exposed a
byte-identical package-local divider copy at
`cores/image_processing/grayscale_anisotropic_diffusion/rtl/deps/integer_divider.v`.
B36 keeps that standalone copy and its inherited package object intact, records
an exact-byte alias, and uses the original acceleration divider path once in the
combined canonical export. The original divider path was untracked at baseline;
B36 adds only that source file, proven byte-identical to the committed local
copy, without importing its unrelated legacy package. The existing softmax source is also added to export
closure, with no source edits or historical status upgrade. Its constants remain
inline; no model import or generation is needed offline. Historical matvec and
softmax claims remain in their own packages; only this composition's named
finite checks qualify the new behavior.

Read-only external primary-source inspection before RTL used PyTorch v2.9.0,
resolved through the official GitHub tag API to commit
`0fabc3ba44823f257e70ce397d989c8de5e362c1`. Inspected
[`torch/nn/functional.py`](https://github.com/pytorch/pytorch/blob/0fabc3ba44823f257e70ce397d989c8de5e362c1/torch/nn/functional.py)
scaled_dot_product_attention documentation and its score -> softmax -> value
ordering, plus the actual root
[`LICENSE`](https://github.com/pytorch/pytorch/blob/0fabc3ba44823f257e70ce397d989c8de5e362c1/LICENSE)
(BSD3 conditions and contributor notices, read completely). Source SHA256
`5e96bb0880a4c6f4c0ae34c00a894e152412e68f6ffd073d2b442907eedeb5fa`;
license `a8a2c6b67cf8a597ffaa5c82380a6bd1b82629c0417e00673d8013d662eb500a`.
The web search tool returnedHTTP500; official API/raw HTTPS reads succeeded.
Only technical behavior was consulted. This design's score quantizer, LUT
approximation, actual-P division and bounded single-query interface are explicit
independent choices; no PyTorch bit-equivalence or drop-in operator claim exists.
No upstream installer, build or script was run. Temporary read-only reference
copies are ignored and removed after committed-source audit.
