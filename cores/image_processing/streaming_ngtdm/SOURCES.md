# C15 pre-RTL source and semantic preflight — 2026-11-05

Baseline `9716da0847c26f09f4a9b856a84fc330dfb26351` contains the56 published
batch packages, including the B14 LINT-only interval candidate. Their current
inventory and B14 evidence boundaries were read before this implementation.
Production RTL, README and SPEC searches for NGTDM, neighboring gray-tone
difference, coarseness and busyness found no existing implementation.

Actual nearby implementations/contracts were inspected: common-scaffold
`distance_transform/binary_distance_transform.sv` already computes exact L1
and L-infinity maps, so that initial candidate was abandoned before RTL;
`chamfer_match` computes directed mean squared template distance. Existing
`glcm/glcm_frame.v` counts directional gray pairs, `entropy_filter` constructs
local histograms and entropy, and batch GLDM counts neighbors within an alpha
threshold. GLRLM counts directional runs and GLSZM connected zones. None
accumulates difference from the neighborhood mean. The GLDM RTL was read for
deduplication, not used as a source dependency or inherited verification.
An initial guessed `dsp_isp_library/rtl` path did not exist; the actual
`dsp_isp_library/isp` and common-scaffold image directories were searched.

## Actual fixed upstream implementation and complete license

Before any local RTL, strict-UTF8 decoded GitHub contents-API responses at
[PyRadiomics](https://github.com/AIM-Harvard/pyradiomics) fixed commit
`08bea7067e350303eead533b471aa60697b3b8c3` were read with15-second HTTPS limits.
Python AST parsing was read-only; downloaded code was never executed.

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE.txt](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/LICENSE.txt) | `62155cc735f5f9e214307a8d880643c2ccfc860d` |1467| `5c1fc504fb0865a72a29e035b25ef3513e6d7e9c7169cb445eae855f03b006e2` |
| [radiomics/ngtdm.py](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/ngtdm.py) | `fd1d876fb6e6f438328349d3f78693c1558903a4` |10918| `9d44f55d1e85bb4de7012248477aee74eaa2d5294042444437c88796743e7b1c` |
| [radiomics/src/cmatrices.c](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/src/cmatrices.c) | `f90434ccbb72ce9001104df5e48074d25c87277c` |36445| `3e5d49381d5acaac813685a74199b6614e0731687b27905c058eed1df16a2070` |

The complete1467-byte BSD3 license, copyright2017 Harvard Medical School,
all three redistribution/name conditions and full warranty/liability disclaimer
were read. Actual Python definition lines6–84 and `_calculateMatrix`96–114,
and the complete C `calculate_ngtdm`543–658 were inspected. The C function
sums valid neighbors, divides by their count, takes the absolute difference
from the center and accumulates by center gray. This local implementation
instead retains the exact rational result scaled by120 using bounded integer
arithmetic. Rectangular radius-one neighbor counts are0,1,2,3,5 or8.

Upstream supports ROI masks, multidimensional offsets, positive gray indices,
double accumulation and compressed output. Its prose describes centers with
valid neighbors, but the actual C increments the count even when neighbor
count is zero. The local1x1 contract explicitly excludes that isolated center;
gray0 is ordinary, there is no ROI, and every gray bin is emitted. No upstream
API, dtype, medical feature, full radiomics-feature or isolated-count
compatibility is claimed.

No upstream implementation, comments, tests, license text or build code was
copied, translated, adapted, imported, executed or persisted. Retrieved bytes
were read-only references. New RTL, independent direct-coordinate rational
oracle, TB and wrapper are original repository Apache-2.0 contributions under
root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE). No sibling,
network, third-party package, external memory or generated table is required.
