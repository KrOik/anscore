# Sources and semantic deduplication

Baseline: `a0602fb2dac20db7c524297371a19f5f580980df`. All new RTL,
oracle, testbench and runner code is original Apache-2.0. The RGB serializer/
packer follows the reviewed local B44 adapter ownership pattern, with a new
transposed-convolution child; its source is unchanged.

Local source inspection found pointwise learned DCR depth-to-space in
`int4_subpixel_upsample2x`, regular valid 3x3 convolution in
`int4_conv3x3_frame`, and per-channel valid depthwise convolution in
`int4_depthwise3x3_stream`. Those do not perform full stride2 transpose with
two-axis neighbour overlap. CNN max-pool, recurrent gates, attention and softmax
also have distinct behavior. A repo-wide canonical RTL/document text search
found no existing transposed-convolution implementation.

The actual runtime dependency closure is local and unchanged:

| Canonical file | Raw SHA256 |
| --- | --- |
| `cores/acceleration/int4_weight_matvec/rtl/deps/stream_requantize.v` | `fdb7cb0fd3800694cd21f322c1cdfd7c8cba686d269fb7e0fe146a47cb0826a2` |
| `cores/acceleration/int4_weight_matvec/rtl/int4_weight_matvec.sv` | `26427a8358b31885ff3dd82756043055369dbfc155a1d4df3dcfb72bdd9ece55` |
| `cores/acceleration/int4_subpixel_upsample2x/rtl/int4_subpixel_upsample2x.sv` | `24b4b0f357d2db5531bb767ca8fce156befe892a7ff6794eeda6d0b6ddb0b43b` |

These dependencies retain their own historical evidence. It does not establish
hardware qualification for this composition. There is no external build-time
download, module generator or pretrained model.

External discovery preceded implementation. GitHub repository search was
archived under `.git/anscore-b45-root-references/github_search.json`. References
were treated as untrusted data and no remote scripts/builds were executed.

- [ONNX ConvTranspose](https://onnx.ai/onnx/operators/onnx__ConvTranspose.html):
  public scatter/output-shape semantics; archived HTML SHA256
  `a2827b76d7633ced4387f6c1cfca88d83e640e8f8ab46201608debc6faa01b68`.
- [transposed-conv-accel](https://github.com/danielstumpp/transposed-conv-accel/tree/93461a498b32eaa45dd8664317e7aae4d43f4419):
  fixed commit `93461a498b32eaa45dd8664317e7aae4d43f4419`, MIT license read
  (SHA256 `a0b465b9c4ca42f76b4fb4191c794c9372af77a86b09298d136c065933d80f07`).
  Repository tree has no Verilog/SystemVerilog source; no code adopted.
- [transconv-fpga](https://github.com/lambdalainen/transconv-fpga/tree/3915637be4d1b5d4fb27559ee3bf8eda6521587c):
  fixed commit `3915637be4d1b5d4fb27559ee3bf8eda6521587c`, Apache-2.0 license
  read (SHA256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`).
  `transposed_convolution_test.srcs/sources_1/new/sparse_gemm.v` interface
  inspected as an architecture reference (SHA256
  `96f2fbd670cba25cd711696f4ca30e0b777508fb3bcc668d828750cfc09100f6`).
  Its BRAM/address/GEMM control differs from the resident asymmetric-U8/S4
  ready/valid matrix contract; no upstream code or data is included.

The phase table is independently derived from the stated scatter equation.
Reference generation uses direct scatter-add; packing the exported runtime
matrix is separate from that numerical oracle. No historical model, checker
or runner is imported/executed. Source planning numerical calls:0.
