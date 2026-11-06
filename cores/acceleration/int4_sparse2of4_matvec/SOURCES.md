# Sources, license and offline dependencies

Original RTL/model/TB/wrapper under Apache-2.0; LICENSE is retained locally.
No external source, binary, table or generated weights were adopted.

Read-only concept references checked 2026-11-07 (Asia/Shanghai):

- NVIDIA TensorRT, Data Formats and Tensors, Sparsity:
  https://docs.nvidia.com/deeplearning/tensorrt/latest/inference-library/data-formats-tensors.html
  HTTP200. Describes at least two zeros in each four-entry reduction group and
  warns that forced pruning can lose accuracy. This implementation is a generic
  independent FPGA integer format, not TensorRT/GPU execution or binary-format
  compatibility. No NVIDIA document/code is redistributed.
- PyTorch v2.6.0, torch/sparse/semi_structured.py:
  https://github.com/pytorch/pytorch/blob/v2.6.0/torch/sparse/semi_structured.py
  and LICENSE at https://github.com/pytorch/pytorch/blob/v2.6.0/LICENSE.
  Exact version-tagged raw files were read with HTTP200 (28,053 and 3,384 bytes).
  BSD-style three-condition license was inspected before authoring; its GPU
  subclass/backend dependencies are unsuitable for this standalone FPGA core.
  No PyTorch source or license text is included because no code was copied.

The web connector returned HTTP500; known primary URLs were fetched read-only
with bounded Invoke-WebRequest. No remote script, install or build was run.

Actual existing dependencies, unchanged at baseline
3a58c99bda6f6f62a34d1c20247d3b42d8d89006:

- ../int4_weight_matvec/rtl/deps/stream_requantize.v is an existing exact-byte
  canonical alias of ../stream_requantize/rtl/stream_requantize.v. It supplies
  signed nearest-even rounding and saturation. The existing dependency alias
  preserves its original bytes; no new copied source/bridge is introduced.
- ../stream_topk/rtl/stream_topk.v, example only, supplies stable signed ranking.

Their current hashes and tool/runtime dependencies are pinned by FINITE_PLAN
and SOURCE_SEAL before execution. Existing historical evidence does not qualify
this new composite. The model reconstructs dense rows before dot products and
uses Python integers/divmod; it does not reproduce the RTL gather scheduler.
