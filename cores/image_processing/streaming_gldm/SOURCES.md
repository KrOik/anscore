# B14 source, semantic and license preflight

Baseline: `01b92bf2f8d81fff097f1965de61edf81604ae4f` (published52-IP B13).

## Actual semantic inspection before RTL

Repository-wide searches for GLDM, gray/grey-level dependence, dependence matrix
and Chinese equivalents found no implementation. Nearby actual contracts and
source were inspected:

- `system/extended_library/src/feat_lbp.v`: threshold ring>=center produces a
  bitcode/uniform flag from a supplied window, not a symmetric alpha dependence
  count conditional on center gray or its whole-image histogram. Its published
  wrapper is an embedded selftest.
- `system/common_scaffold/image/glcm`: directional pair frequencies and feature
  numerators, not the per-center joint number of similar neighbors.
- `image_processing/streaming_glrlm`: maximal linear same-gray runs.
- `image_processing/grayscale_size_zone`: maximal connected equal-gray regions.

This new service preserves each center's full local dependence count before
histogram aggregation, a statistic not recoverable from directional pair totals
alone. None of the52 existing package objects or older assets was modified.

## Fixed actual implementation and full license read before RTL

Repository: <https://github.com/AIM-Harvard/pyradiomics>

Immutable commit: `08bea7067e350303eead533b471aa60697b3b8c3` (v3.0.1 tree).
Actual decoded Python mathematical class and `_calculateMatrix` implementation,
complete `calculate_gldm` C function, and the entire license were fetched/read
from fixed raw-file URLs before writing this RTL. Nothing external was
installed, imported, executed, copied, translated or persisted as a local asset.

| File | Bytes | Git blob | SHA-256 |
| --- | ---: | --- | --- |
| [LICENSE.txt](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/LICENSE.txt) | 1467 | `62155cc735f5f9e214307a8d880643c2ccfc860d` | `5c1fc504fb0865a72a29e035b25ef3513e6d7e9c7169cb445eae855f03b006e2` |
| [radiomics/gldm.py](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/gldm.py) | 14843 | `f39e63a87b4bde5159c3eda76aba08aeebb8df60` | `fd7b51770dd13f957c084bf00b5793c980626933f1be6536e198784ca834c1fa` |
| [radiomics/src/cmatrices.c](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/src/cmatrices.c) | 36445 | `f90434ccbb72ce9001104df5e48074d25c87277c` | `3e5d49381d5acaac813685a74199b6614e0731687b27905c058eed1df16a2070` |

Copyright2017 Harvard Medical School. Complete BSD3 terms were inspected:
source/binary redistribution requires retention of copyright/conditions/
disclaimer; holder/contributor names cannot endorse derived products without
permission. The full warranty and liability disclaimer was read. License
decision: reference-only mathematical/behavioral comparison is acceptable.
No upstream source/docstring/comment/test/license text is redistributed here.
Original RTL/TB/runner/docs use repository Apache-2.0 LICENSE/NOTICE.

The C source counts qualifying in-mask neighbors with abs(gray difference)
<=alpha, stores the histogram at zero-based neighbor-count index, and the
Python dependence vector is1-based, thus including the center. Upstream allows
ROI/ND masks, multiple distances, positive gray bins and removal of unused
rows/columns. Locally the domain is a full2D rectangle, Chebyshev radius1,
MSB quantization with gray0, integer first-pixel alpha, and all fixed gray/d1..9
bins. No PyRadiomics API, medical feature, dtype or clinical compatibility is
claimed. The architecture is independent line-streaming RTL; the oracle uses
direct coordinate sets rather than upstream angle/stride loops or line history.

## Offline dependency decision

One local RTL source and one local example wrapper; no sibling RTL, external
RAM, generated table, memory initialization file, vendor IP or network build.
The finite runner uses only Python's standard library and local Icarus tools.
NumPy/radiomics/deprecated helpers used upstream are not runtime dependencies.
Root LICENSE/NOTICE and older verification scopes are preserved unchanged.
