# Provenance and reuse

All new wrapper, testbench, reference/runner, example and documentation are
original ANSCORE contributions under Apache-2.0. No third-party source or build
script is imported/executed. The repository license is supplied locally.

Before implementation, read-only inspection of the official ONNX reference
[Conv implementation](https://github.com/onnx/onnx/blob/04e9ef9f7690b7a77be3c614db6f94d5e1a81a99/onnx/reference/ops/op_conv.py)
and [Apache-2.0 license](https://github.com/onnx/onnx/blob/04e9ef9f7690b7a77be3c614db6f94d5e1a81a99/LICENSE)
at commit04e9ef9f7690b7a77be3c614db6f94d5e1a81a99 informed the valid-window,
non-reversed kernel convention. Official raw GitHub/API retrieval succeeded;
web search returned HTTP500. No external Python was executed. This layer's
restricted shape and integer quantization contract are independently specified,
without a claim of arbitrary ONNX Conv operator support.

Semantic dedup reviewed fixed28x28 `cnn_infer_25k/cnn_serial_engine`, fixed
parallel `cnn_inference/cnn_engine`, banked YOLO INT8, CE-qualified systolic
`input_layer`, valid3x3 and edge-replicated image windows, sparse matvec and B33
INT4 matvec. The scalar CNN engine has fixed shape/stages; YOLO has banked/ROM
network control; the systolic input layer's documented arbitrary-gap limitation
does not suit this public ready/valid frame entry. No such mature source was
rewritten. The valid3x3 window already implements the required storage/taps, so
it is reused rather than replaced by another window extractor.

The functional increment is automatic full-frame, arbitrary-gap row buffering
and patch/channel sequencing into persistent INT4 kernels, including early
kernel preflight, cropped coordinate/marker construction and definitive frame
completion/error ownership. It is not another width variant of a dot product.

Unchanged dependencies, all listed by package-root relative path in files.f:

| Source | Baseline SHA-256 |
| --- | --- |
| ../../system/common_scaffold/image/window/img_window3x3_valid_draft.v | 16b2eb0d0ebdc5c023bd821d39c171390ff7682676da0ba737351466c46818b1 |
| ../int4_weight_matvec/rtl/int4_weight_matvec.sv | 26427a8358b31885ff3dd82756043055369dbfc155a1d4df3dcfb72bdd9ece55 |
| ../int4_weight_matvec/rtl/deps/stream_requantize.v | fdb7cb0fd3800694cd21f322c1cdfd7c8cba686d269fb7e0fe146a47cb0826a2 |

All three files were read from current a517a23c baseline before implementation.
The current finite composition tests include their exact bytes, archived under
reports/<stamp>/executed_inputs/cores/... before any model or HDL invocation.
No dependency copy, module rename or historical physical qualification is added.
Compile shared canonical modules once when combining packages.
