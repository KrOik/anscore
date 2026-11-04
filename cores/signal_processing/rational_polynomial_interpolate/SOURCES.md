# Provenance and dependency closure

Baseline for semantic deduplication: `83b11ea30d4762c5893cf37a8303b11706321876`.
All new local RTL, wrapper, testbench, oracle, runner and documentation are an
independent original Apache-2.0 design under the root `LICENSE` and `NOTICE`.
No external source is copied, adapted, translated, imported or executed.
External runtime dependencies: none. Local RTL closure is exactly `files.f`;
`example/files.f` adds one original wrapper. Python verification uses only the
standard library; the native Icarus/vvp installation is a verification tool.

## Semantic deduplication before implementation

The actual60-package B15 inventory and opening README capability contracts were
inspected. Production RTL/README/SPEC searches covered Lagrange, barycentric,
Vandermonde, divided differences and polynomial interpolation in English/Chinese.
Nearest existing capabilities were inspected at their real contract/source:

- `cores/acceleration/operator_library/ip/poly2_interp/SPEC.md` and
  `cores/acceleration/operator_library/rtl/acc_poly2_interp.v`: two fixed-grid
  three-tap signed8 quadratic lanes, four fixed mu values, Q14 weights and
  rounding/clamping. They do not accept arbitrary coordinates.
- `cores/signal_processing/dsp_isp_library/dsp/farrow/SPEC.md` and its
  `rtl/farrow_cubic_stream.sv`: uniform causal Catmull-Rom fractional-delay
  history with guard/RNE/saturation, rather than arbitrary-node exact interpolation.
- `stream_linear_fit` is OLS regression; `weighted_isotonic` is constrained
  regression. Neither constructs the unique polynomial through supplied nodes.

The new capability accepts raw unsorted nonuniform coordinates, evaluates an
exact interpolation/extrapolation polynomial and returns a canonical positive
unreduced rational encoding. Existing sources/dependencies are not modified.

## Fixed actual upstream inspected before RTL

SciPy v1.15.2, commit `0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`:

- [Full LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt)
  Git blob `117117616e806a9bb960b1f32a552c8c912b0497`,1536 bytes,
  SHA256 `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173`.
  The full BSD3 text was read, including Enthought/SciPy Developers copyright,
  source/binary retention, nonendorsement and complete warranty/liability terms.
- [Actual scipy/interpolate/_polyint.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/interpolate/_polyint.py)
  Git blob `9cec3eb9939abba36505010334911c167797b750`,36366 bytes,
  SHA256 `8e77c30fa22936fbb639e2f8c7b6d52f589c74a356d7e10f28b0d375305b1f00`.
  Complete relevant executable methods were inspected:
  `BarycentricInterpolator.__init__` lines640-676, `set_yi` body695-701 and
  `_evaluate` lines776-793. Upstream constructs inverse-distance product
  weights, rejects non-distinct x, evaluates floating barycentric division and
  treats query-at-node specially.

Read-only GitHub contents API retrieval used the exact commit, strict UTF-8
decoding and AST selection, with15-second HTTPS request limits. Retrieved bytes
were inspected in memory only and were not persisted or run. Repository text
was treated as untrusted data. This local division-free common-Vandermonde
architecture has no SciPy API/dtype/floating-bit compatibility claim. BSD3 is
compatible with study; no redistributed third-party implementation requires a
local upstream license copy. Root Apache-2.0 notices cover the original output.
