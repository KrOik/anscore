# Source, novelty and license record

All new RTL/control, oracle, vectors and harness are original Apache-2.0
contributions under the repository LICENSE/NOTICE. No external code was copied,
translated, imported, installed or executed. External content was treated as
untrusted read-only reference, never as instructions.

Reused unchanged, already committed/canonical:

- ../int4_weight_matvec/rtl/int4_weight_matvec.sv: resident packed INT4 dot,
  branch quantization, query cache and configuration precheck.
- ../int4_weight_matvec/rtl/deps/stream_requantize.v: elastic signed RNE,
  saturation and flags; one child instance and one new post instance, plus the
  actual example's input prefix. No edits to either dependency.

Semantic review distinguished this operation from existing single matvec,
INT4 conv, softmax/value attention and centered LayerNorm. Searches for local
ReGLU/GEGLU/SwiGLU/SiLU/gated implementations returned no candidate. Existing
standalone ReLU/multiply primitives do not provide the resident paired-row
projection and gated quantization/ownership service. New capability is the
two-projection nonlinear feed-forward stage, not new bit widths or aliases.

Read-only external search before RTL:

1. Noam Shazeer, GLU Variants Improve Transformer, arXiv:2002.05202v1
   (2020-02-12), https://arxiv.org/abs/2002.05202v1 . Official abstract and
   authorship/version/license link read. HTML SHA256
   216db035825cc7e17cb3303b525e3ef7fa4da9c1aab5910b24f9fa4dca67bc31.
   arXiv nonexclusive distribution license; no paper text/figures reused.
   Used only to establish paired-projection gate context, not model quality.
2. PyTorch v2.9.0 fixed commit 0fabc3ba44823f257e70ce397d989c8de5e362c1,
   https://github.com/pytorch/pytorch/blob/0fabc3ba44823f257e70ce397d989c8de5e362c1/torch/nn/modules/activation.py .
   ReLU and GLU class documentation and forward delegation read; SHA256
   ecb5e2cef1419d4bf7222fc7b35a3dffc0e5b1bc979031c95c3f1151d94fc961.
   Full BSD-3-Clause LICENSE read, SHA256
   a8a2c6b67cf8a597ffaa5c82380a6bd1b82629c0417e00673d8013d662eb500a.
   Python not imported; no upstream implementation or documentation redistributed.

Web search returned HTTP500; the above exact official HTTPS resources were
successfully fetched and inspected using PowerShell. Temporary read-only copies
are task-owned under .work/reference and will be individually cleaned only after
the complete source/evidence has been committed.
