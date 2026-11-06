# Deduplication and provenance

Baseline: `a68ca46815777c15c638c42a03899c83385bf052`.

Semantic search read existing resident INT4 matvec/conv3x3, key attention,
centered signed8 LayerNorm, ReGLU, standalone stream_requantize, fixed CNN
engines and `ips_series_nn_front`. They supply products, affine outputs,
normalization, gates or a fixed network. None provides an independently stalled
two-branch join with per-channel asymmetric scales, exact pre-round cancellation
and a single shared rounding point. Existing graphics alpha interpolation has
different unsigned color/coverage semantics and no tensor channel configuration.
No existing RTL is changed or renamed as a new capability.

Read-only official external reference, fetched2026-11-06 from fixed v2.16.1:

- TensorFlow Lite reference ADD:
  https://raw.githubusercontent.com/tensorflow/tensorflow/v2.16.1/tensorflow/lite/kernels/internal/reference/add.h
  SHA256 `9e7d747c9ccd7d55458e80c3ca43351c6eaec713c23c24948422ef939f30a128`.
- License:
  https://raw.githubusercontent.com/tensorflow/tensorflow/v2.16.1/LICENSE
  SHA256 `71c6915d04265772a0339bed47276942c678b45cc01534210ebe6984fd1aec65`.

The Apache2.0 reference confirms the engineering use of independent input
offsets/scales, output offset and activation interval. It has additional staged
fixed-point rounding; this package defines its own exact single-round operation,
so no TFLite/ONNX bit equivalence or model accuracy is claimed. No upstream code
was copied, translated, imported, installed or executed. HTTPS content was read
in memory; no upstream source dependency exists. Web search returned HTTP500;
the fixed official source and license URLs were read directly.

New original RTL/model/TB/wrapper/runner use the repository Apache2.0 license.
The unchanged dependency is
`../int4_weight_matvec/rtl/deps/stream_requantize.v`, SHA256
`fdb7cb0fd3800694cd21f322c1cdfd7c8cba686d269fb7e0fe146a47cb0826a2`.
This is byte-identical to the standalone original stream_requantize RTL and is
already in the canonical offline dependency closure. Only one copy is compiled.
