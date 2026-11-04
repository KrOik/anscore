# Search, license and originality record — 2026-11-04

Development baseline: `cf9b62d545d5e741589daf1fe99c6533f3148316`.
Read-only semantic searches of RTL and README/SPEC files under `cores/`
checked linear regression, least squares, line fitting and Chinese equivalents.
`linear_solve2x2` accepts arbitrary equation coefficients, not sample frames.
`stream_cross_moments` supplies sufficient statistics without solving, and its
workspace copy is not a tracked dependency of this package. Image optical-flow,
geometry and RANSAC packages have specialized internal fitting paths; none
provides this general signed-pair streaming OLS contract. Existing DSP LMS is
an adaptive filter with a different objective and update rule. No old asset
was modified or incorporated through an untracked path.

Before RTL implementation, the Boost.Math repository's actual pinned source
and license were read through the GitHub contents API. Raw-content/Python
requests encountered transport EOFs; curl's read-only API retrieval succeeded.
No upstream commands, build scripts or downloaded programs were executed.
External content was treated as reference data only.

| Reference | Fixed revision | Read-only inspection |
| --- | --- | --- |
| [boostorg/math](https://github.com/boostorg/math) | `75dae670730874195f146c3a64c3f009101d9e62` | Actual `LICENSE` declares Boost Software License 1.0. Actual `include/boost/math/statistics/linear_regression.hpp` declares the same license, with Nick Thompson (2019) and Matt Borland (2021) notices. Its ordinary-least-squares implementation identifies the covariance/variance slope, mean-based intercept, and no-x-variance domain boundary. No source was copied. |

Inspected external file SHA256:

```text
LICENSE
c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566
include/boost/math/statistics/linear_regression.hpp
64602f800805c1b9f1240382441cf25ec30b4d5259493bdcba1ed65ef2898e73
```

Pinned links:
[license](https://github.com/boostorg/math/blob/75dae670730874195f146c3a64c3f009101d9e62/LICENSE),
[linear regression](https://github.com/boostorg/math/blob/75dae670730874195f146c3a64c3f009101d9e62/include/boost/math/statistics/linear_regression.hpp).
The floating-point software implementation is not claimed to be bit-exact
with this RTL's exact integer prefix and final fixed-point output semantics.

Production dependency closure consists solely of the original package RTL
and the repository's Apache-2.0
`../linear_solve2x2/rtl/linear_solve2x2.sv`, unchanged from the baseline. Its
actual SHA256 is recorded in `verification.json`; there are no external RTL,
Boost, Python-package or download dependencies. The existing solver's
`SOURCES.md` preserves its own read-only reference provenance. This package's
RTL, example, deterministic oracle, TB and prose are original and use the
repository Apache License 2.0. No third-party implementation or license-bearing
source is redistributed; there are no external local modifications.
