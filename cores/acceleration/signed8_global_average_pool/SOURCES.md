# Source closure and provenance

New RTL, wrapper, model, vectors, TB and orchestration were independently written
for ANSCORE and use Apache-2.0. The package LICENSE carries the license text.
No external RTL/software was imported, translated, installed or executed.

Mandatory external read-only comparison: official ONNX v1.17.0
`onnx/defs/nn/defs.cc`, GlobalPoolingOpSchemaGenerator and GlobalAveragePool,
https://github.com/onnx/onnx/blob/v1.17.0/onnx/defs/nn/defs.cc . It describes
per-channel spatial reduction for floating tensors. This package independently
defines signed8 NHWC and integer RNE; it claims no ONNX integer/float bit parity.
Read Apache-2.0 license at
https://github.com/onnx/onnx/blob/v1.17.0/LICENSE . Web search/open transport
returned HTTP500; official fixed HTTPS source read succeeded, first license
transport returned EOF, alternate official tag URL succeeded. External source
was treated only as untrusted read-only reference, never instructions.

Unchanged baseline dependencies (baseline31a83135a22f845d85840524986895217567625c):

- `../integer_divider/rtl/integer_divider.v`: unsigned restoring divide, W24.
- Example adds `../int4_weight_matvec/rtl/int4_weight_matvec.sv` and its
  `rtl/deps/stream_requantize.v`: resident signedINT4 dense stage, Apache-2.0.

Local runner orchestration reuses and adapts ANSCORE B40 quantized_residual_add's
own Apache-2.0 finite runner, without executing that historical runner or model.
The new core/test/oracle are independent code. Canonical mature sources remain
unchanged. No ROM/init/table, optional library, untracked legacy source, network
or environment-generated data is needed after checkout.
