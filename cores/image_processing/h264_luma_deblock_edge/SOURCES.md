# Provenance and semantic review

Original ANSCORE RTL, testbench, Python reference/runner and example, licensed
Apache-2.0. No third-party source was imported or adapted; no upstream build,
installer, compiler or test was executed. The full repository Apache license
is included as `LICENSE`. All production source dependencies are local.

Before authoring, repository-wide RTL/README/SPEC searches for deblock, H.264,
H.265, HEVC and AVC-codec behavior found no existing boundary-filtering kernel.
Literal hexadecimal words such as `34'h264025` in historical board vectors were
excluded as false positives, not treated as codec implementations. Common
scaffold image, DSP/ISP and operator-library behavior was included: generic
blur/edge filters, quantization, seam selection, geometry and image codecs do
not perform codec-strength-gated clipped normal and asymmetric strong updates.

Read-only primary implementation and license review occurred before RTL:

- Cisco OpenH264 fixed commit `1bca62311e447fd9c39fc93de2c4b96cd5ce971c`,
  [`codec/common/src/deblocking_common.cpp`](https://github.com/cisco/openh264/blob/1bca62311e447fd9c39fc93de2c4b96cd5ce971c/codec/common/src/deblocking_common.cpp).
  Reviewed `DeblockLumaLt4_c` and `DeblockLumaEq4_c` for strict alpha/beta
  comparisons, tc0 behavior, signed right-shift rounding, and the independent
  strong-filter sides. Retrieved UTF8 bytes11462,
  SHA-256 `d7af286ef04ac48db556dcd86a802c0d04d0a666e2f0882a09cbc0755bc44da2`.
- [`LICENSE`](https://github.com/cisco/openh264/blob/1bca62311e447fd9c39fc93de2c4b96cd5ce971c/LICENSE),
  Cisco Systems2013, BSD2-clause. Read before implementation. Retrieved UTF8
  bytes1295, SHA-256
  `dd5c1c9668512530fa5a96e4c29ac4033d70a7eeb0eed7a42fddb6dd794ebdbb`.

The OpenH264 routines process strided blocks and modify memory; this original
RTL instead implements a single independent eight-sample elastic transaction,
unsigned fixed widths, explicit error/bypass behavior and opaque metadata.
The mathematical filter equations are technical references; upstream C code,
SIMD, headers and helper implementations are not included. The Python model is
also original and was not obtained by executing or translating an upstream
helper. No package-wide OpenH264 bit-equivalence or full-codec claim is made.

The web search tool returned HTTP500. Successful direct HTTPS GETs read the
upstream source and license; GitHub's commits API resolved the fixed SHA. No
external runtime access is needed for the delivered IP or its finite tests.
