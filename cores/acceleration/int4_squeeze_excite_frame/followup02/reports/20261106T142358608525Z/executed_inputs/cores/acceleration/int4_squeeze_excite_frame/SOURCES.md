# Sources, novelty and provenance

Baseline: `50b8d36a3ce65cae5c4b3ab4604fa24f3567204b` (B45 closeout).
The new controller, integer hard-sigmoid/replay, example, oracle and testbench are
independently written Apache-2.0 source. No external project code was copied,
translated, imported or executed.

Read-only external research on2026-11-06:

- [SE paper](https://arxiv.org/abs/1709.01507), author primary abstract/metadata:
  channel interdependence and global squeeze/excitation. Version4 is2019-05-16.
- [Author SENet](https://github.com/hujie-frank/SENet), pinned commit
  `0262d43d44c561fd53c3dba210cc8bacfc60500d`; official GitHub repository API
  reports Apache-2.0. Used for conceptual comparison only, no source dependency.
- [PyTorch primary Hardsigmoid definition](https://github.com/pytorch/pytorch/blob/main/torch/nn/modules/activation.py),
  class mathematical docstring read via official raw HTTPS: clamp(x/6+1/2,0,1).
  This is a technical reference, not a vendored implementation or fixed code
  dependency. The local z/32 and Q0.8 contract is independently derived.
- Official GitHub repository search `squeeze excitation verilog` returned zero
  repositories at retrieval. This narrow result is not a universal novelty
  or patent claim. The web-search connector returned HTTP500; primary HTTPS
  reads succeeded without running downloaded content.

Whole-repository semantic inspection found standalone pool/classifier, INT4
matvec, quantized residual addition, ReGLU and token/key attention. The pool's
classifier discards spatial data; ReGLU gates corresponding hidden elements;
key attention mixes tokens. None computes spatial-global per-channel gates and
replays the cached input frame. This is neither a different-width alias nor a
claim that existing submodules are new capabilities.

Unchanged canonical dependencies, listed once in files.f:

| Repository path | SHA256 |
|---|---|
| cores/acceleration/int4_weight_matvec/rtl/int4_weight_matvec.sv | 26427a8358b31885ff3dd82756043055369dbfc155a1d4df3dcfb72bdd9ece55 |
| cores/acceleration/int4_weight_matvec/rtl/deps/stream_requantize.v | fdb7cb0fd3800694cd21f322c1cdfd7c8cba686d269fb7e0fe146a47cb0826a2 |
| cores/acceleration/integer_divider/rtl/integer_divider.v | e09b6e9501a02fbcb0a89be50b5a0b787c71e9180b934b32d446601a299c5f6c |
| cores/acceleration/signed8_global_average_pool/rtl/signed8_global_average_pool.sv | 96e5ddadd657ce9e307e3fdcc4c162e72e3cbf3c2f76d4764b30daffcf3e87dc |

All carry Apache-2.0 SPDX notices in the existing repository. The package LICENSE
retains the full Apache-2.0 text. No vendor IP, trained weights, float runtime,
network access or generated ROM is required for offline use. Prior physical
qualifications of dependencies do not qualify this new composition.
