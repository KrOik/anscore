# Sources, provenance and duplicate check

Local baseline: d32ea87e268c5957b7203560a5b46864e282a6e1.
New RTL, model, tests and workflow are original Apache-2.0 repository work.
No external source code, weights, scripts, generator output or dependencies
were imported or executed. Local reuse is the exact committed
`../int4_weight_matvec/rtl/deps/stream_requantize.v`, SHA256
fdb7cb0fd3800694cd21f322c1cdfd7c8cba686d269fb7e0fe146a47cb0826a2,
Git blob773d58f98bdc39d0d1439c3505ca17711a28af46. Its dependency closure is
one module with no includes, ROMs, external files or vendor primitives.

Pre-development read-only external lookup on2026-11-06:

- Xiangyu Zhang et al., ShuffleNet, arXiv1707.01083v2,
  https://arxiv.org/abs/1707.01083v2 (HTTP200 abstract).
  Concept reference for pointwise group convolution and channel shuffle;
  it does not specify this implementation's integer quantization or interface.
- GitHub repository metadata search for ShuffleNet FPGA (HTTP200 API):
  https://api.github.com/search/repositories?q=ShuffleNet+FPGA&per_page=3
  returned jzfengziyan/shufflenetv2_hls,
  nageeb404/ShuffleNet-V2-FPGA-Accelerator and
  suki20020310/41412_FPGA_shufflenet_fire_config. All three search records
  reported license=null, so none was adopted. No repository code/build script
  was downloaded, translated, imported or executed.
- The web search connector returned HTTP500; direct HTTPS primary-source and
  repository-metadata reads above supplied the pre-development lookup.

Semantic duplicate review read existing int4_weight_matvec,
int4_conv3x3_frame, int4_depthwise3x3_stream, int4_key_attention,
int4_squeeze_excite_frame and production RTL/metadata under operator_library,
common_scaffold and ip_series. Dense matvec, depthwise kernels, full attention,
SE and pooling are retained. The independent increment here is the grouped
NHWC pointwise tensor scheduler and zero-extra-buffer shuffle computation
order; the unchanged quantizer remains shared.
