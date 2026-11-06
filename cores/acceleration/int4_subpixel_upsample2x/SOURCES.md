# Source and license record

Baseline:2e7a6fb51f32e525c1026c28d1f2f45e36545ebc. Independently authored Apache2
RTL/model/TB/control. Offline closure uses the existing int4_weight_matvec and
its private stream_requantize dependency without edits or oracle imports.

Semantic read-only search covered acceleration, ip_series, extended_library and
common_scaffold/signal_video. The existing cip_image_super_resolution is a
four-layer gray8/hidden-U16 Q8 CNN with whole-frame and three hidden-map memories,
fixed single-channel output and shared CE. It already performs PixelShuffle2;
no claim is made to invent that operation. It cannot provide this reusable
runtime NHWC multi-input/multi-output INT4 layer or its one-lower-row storage
and ordinary RV lifecycle. The old matrix is only a vector/row primitive, and
the old int4_conv3x3_frame is single-source-channel valid convolution with
cropping. Both lack the learned expanding raster service. Fixed CNN maxpool,
depthwise1D and generic integer interpolation similarly do not provide it.

Official external reference, read2026-11-06:
https://github.com/onnx/onnx/blob/v1.17.0/onnx/defs/tensor/defs.cc
DepthToSpace schema13, mode DCR, blocksize2. This is a tensor permutation
reference; the fixed integer quantization is the local documented contract,
not ONNX operator-level bit-exact compatibility. Canonical raw HTTPS bytes:
SHA256042d2f2e3a79f9999ec576bbe12dcd8f9eb0984779918ec5e990872e578d9b23,
162472characters in the decoded response. Official Apache2 license at
https://github.com/onnx/onnx/blob/v1.17.0/LICENSE,
SHA256cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30.
The web browsing endpoint returned HTTP500; fixed raw.githubusercontent.com
HTTPS read-only requests supplied the actual schema and complete license.
No external source was copied, translated, installed, imported or executed.

The finite runner archives exact current RTL, docs, model, TB, control and mature
dependency bytes before any preparation/tool call. The receipt's source hash
map is the authoritative execution binding; no old runner or model is imported.
