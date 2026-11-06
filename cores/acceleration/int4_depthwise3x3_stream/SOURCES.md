# Provenance and semantic boundary

Baseline09de72c578b3099d4e867c739118faa7607f663d. New RTL, adapter, tensor
model, TB and runner are independently authored for ANSCORE, Apache-2.0.

Semantic review included hidden/unindexed workspace sources. Existing
int4_conv3x3_frame is a single input-channel window feeding multiple output
channels, and does not provide independent NHWC channel windows. Existing
ips_conv1d_depthwise consumes host-supplied taps, has4 fixed INT8 coefficient
rows, CE pulse output and different rounding. Existing yolo_conv has genuine
2D depthwise grouping, but is a specialized whole-feature-map banked engine
with128 MAC lanes and parameter ROMs. This package adds a standalone runtime
multichannel two-row streaming dataflow, independent channel kernels and RV
backpressure. Weight width alone is not its functional distinction.

Unmodified local production dependencies:

- cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v: generic byte-write
  synchronous read-first request/response RAM, used for both rows, kernels and
  metadata. Its CE is permanently one; active-low child reset is !public rst.
- cores/acceleration/int4_weight_matvec/rtl/deps/stream_requantize.v: existing
  exact RNE elastic quantizer, instantiated64-to16. Provenance/rights remain in
  the existing repository; this package does not relicense those dependencies.

Exact dependency SHA256 values are sealed in FINITE_PLAN.json and copied into
each execution archive. No mature source was modified or copied into a new
canonical RTL path. Offline files.f closures use the existing local paths.

External primary source was inspected read-only before implementation:
TensorFlow v2.18.0, Apache License2.0, source
https://github.com/tensorflow/tensorflow/blob/v2.18.0/tensorflow/lite/kernels/internal/reference/depthwiseconv_uint8.h
SHA25671c6915d04265772a0339bed47276942c678b45cc01534210ebe6984fd1aec65,
license https://github.com/tensorflow/tensorflow/blob/v2.18.0/LICENSE
SHA256b34087aac91150e83ea7210491044723b6e67e81dbbfbdeb7e8c7d2ddde74fa6.
Fixed raw HTTPS downloads succeeded after web search returned HTTP500. Inert
read-only downloads live under .git/anscore-b44-root-references; no external
code was executed, imported, adapted or included in formal RTL. The source's
channel indexing and convolution loops were technical references. Its rounding
policies differ; our explicit nearest-even integer contract is independent.
