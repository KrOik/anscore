# Read-only upstream NLM / morphology reference audit

Checked 2026-10-17 using HTTP GET only. No upstream source was downloaded to
the workspace, copied, or modified.

## Pinned source and license evidence

- Repository: [opencv/opencv](https://github.com/opencv/opencv)
- Release tag: `4.10.0`; GitHub annotated-tag API resolves it to commit
  `71d3237a093b60a27601c20e9ee6c3e52154e8b1`.
- The tag API reports `verification.verified=false` (`unsigned`); the audit
  therefore pins the commit SHA rather than treating the tag as signed.
- The repository root `LICENSE` at this commit is Apache License 2.0,
  SHA256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`.
- The audited legacy source files carry an in-file Intel License Agreement
  notice with source/binary notice-retention conditions, a non-endorsement
  clause, and warranty/liability disclaimers (the familiar BSD-3-Clause-style
  terms). Their individual headers remain relevant; do not assume the root
  license is the only notice applicable to every file.

Pinned raw-file SHA256 values:

| File | SHA256 |
|---|---|
| `modules/photo/src/denoising.cpp` | `34978ffc8cf0441b91d582fdae75a4330dc596686d5d11bd980eaa436b87a4fd` |
| `modules/photo/src/fast_nlmeans_denoising_invoker.hpp` | `cff610416b159363577fadf5f3b63d19c7977db943622dd7d6cab64c9dd99b0c` |
| `modules/photo/src/fast_nlmeans_denoising_invoker_commons.hpp` | `fce7673b47e6cca53bdeab87589a1baed968d2549ebe6205e0cb35b5eb7f13f7` |
| `modules/imgproc/src/morph.dispatch.cpp` | `f22b48a0e0e5bb13a1e10e717f6a9de9ea7e04f6c8e4dd4071e8bbc09610de23` |
| `modules/imgproc/src/morph.simd.hpp` | `705cebdf6bc833f48d0f25f8b1ad670b40ee65ca7f8be83a70a136301c6effd0` |

## Selected implementation points

- In `fast_nlmeans_denoising_invoker.hpp`, lines 117-140 pad the input, derive
  a fixed-point accumulator scale, and precompute a distance-to-weight table.
  Lines 236-251 accumulate weighted candidates and normalize the result.
- In `fast_nlmeans_denoising_invoker_commons.hpp`, lines 133-144 compute the
  squared-distance weight as `exp(-dist*dist / (h*h*channels))`, round it into
  a fixed-point value, and suppress weights below `0.001`.
- In `morph.dispatch.cpp`, lines 102-109 split a fully populated rectangular
  structuring element into row and column filters; lines 1196-1203 define
  opening as erosion then dilation and closing as dilation then erosion.
- In `morph.simd.hpp`, lines 488-538 and 544-590 implement row and column
  morphology filters with vector-operation hooks and scalar tails.

Source URLs are stable at this commit, for example:

- <https://raw.githubusercontent.com/opencv/opencv/71d3237a093b60a27601c20e9ee6c3e52154e8b1/modules/photo/src/fast_nlmeans_denoising_invoker.hpp>
- <https://raw.githubusercontent.com/opencv/opencv/71d3237a093b60a27601c20e9ee6c3e52154e8b1/modules/imgproc/src/morph.dispatch.cpp>
- <https://raw.githubusercontent.com/opencv/opencv/71d3237a093b60a27601c20e9ee6c3e52154e8b1/modules/imgproc/src/morph.simd.hpp>

## Relevance and differences from the local FPGA source

OpenCV is a mature software reference for patch-distance NLM and morphology,
with fixed-point weighting, precomputed weight tables, CPU parallelism, and
SIMD morphology kernels. The local engine has a different hardware contract:
bounded 64x64 frames, synchronous frame memories, serial search/patch walks, a
Q0.16 exponential LUT, limited radii, and a 9-bit 3x3 structuring element.
Its edge behavior, arithmetic quantization, and throughput must continue to be
judged against the local frozen integer vectors and RTL regression; the C++ is
not a drop-in implementation or an FPGA correctness proof.

Current local production SHA256 differs from the frozen v103 candidate for
both `img_filter_frame_engine.v` and `img_filter_exp_weight.v`. v103 would
therefore require a controlled production-source update after all integration
gates pass. This audit made no production change and imported no third-party
code. Any future reuse should first audit the exact file headers and preserve
the applicable attribution/license notices.
