# C12 semantic and fixed-source preflight — 2026-11-04

Baseline: `d35ce742b34ffa7afebffe0b9f6705a825f469e1`.
Read-only semantic/source/license preflight and the contract/resource proposal
preceded new RTL. Only this private package is changed.

Repository-wide RTL/README/SPEC searches covered GLRLM, gray/grey-level run,
run-length matrix, texture runs and 灰度游程/游程长度矩阵. No matching service was
found. Actual GLCM and binary image RLE contracts were read. GLCM counts gray
values of spatial neighbor pairs; it does not identify maximal homogeneous
runs or their length distribution. Binary RLE encodes/decodes horizontal mask
tokens rather than producing a four-direction grayscale texture matrix.
LBP produces local comparison codes; entropy/GLCM are other texture descriptors.
None provides this service through width, channel or handshake adaptation.
All runtime dependencies are local; no sibling implementation is changed.

## Actual source and complete license

Read-only GitHub contents API requests resolved PyRadiomics v3.0.1 annotated
tag `c428a771c8cf682c462162b6babc836150d5d9d6` to immutable commit
`08bea7067e350303eead533b471aa60697b3b8c3`.
All bytes below were base64-decoded as text. The GLRLM class definition and
matrix construction body, the complete actual C `calculate_glrlm` function,
and the **complete license** were read before implementation.

| File | Bytes | SHA256 |
| --- | ---: | --- |
| [LICENSE.txt](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/LICENSE.txt) | 1467 | `5c1fc504fb0865a72a29e035b25ef3513e6d7e9c7169cb445eae855f03b006e2` |
| [radiomics/glrlm.py](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/glrlm.py) | 18014 | `68777ee41f3e79e6487a4e7cf7ecb73a1dc1f6cd49d5d1215814490245c9d9ac` |
| [radiomics/src/cmatrices.c](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/src/cmatrices.c) | 36445 | `3e5d49381d5acaac813685a74199b6614e0731687b27905c058eed1df16a2070` |

Git blobs are respectively `62155cc735f5f9e214307a8d880643c2ccfc860d`,
`96f86ad38946e05198f1b5d516014c976121f106` and
`f90434ccbb72ce9001104df5e48074d25c87277c`.
The BSD 3-clause license names Harvard Medical School, copyright 2017,
requires retained notices/conditions/disclaimer, and prohibits endorsement
using holder/contributor names without permission.

The reference defines a matrix cell as the number of maximal consecutive
equal-gray runs of that length in a direction. Its C function traverses
complete geometric lines with an ROI mask. It requires positive discrete
gray indices and removes a direction when every line has at most one included
element. Its Python class also has ROI, binning, weighting and feature layers.
This package defines different integration choices explicitly: zero-based MSB
bins, full rectangular image without ROI mask, all four directions retained
including singleton directions, no feature/angle weighting or clinical output.
It claims the stated matrix mathematics, not PyRadiomics API compatibility.

This RTL independently maintains provisional prefix-run histograms with
increment/decrement updates and synchronous line histories. The original
Python oracle enumerates whole geometric lines and maximal equal-value groups.
No upstream implementation, comments, tests, build code or license text was
copied, translated, adapted, imported, executed or redistributed. References
were untrusted text only, stayed in process memory and are not runtime assets.
Every curl request had a 15-second bound and every child a 20-second bound.
No remote build or installer ran.

New RTL, wrapper, oracle, TB, runner and prose are original Apache-2.0
repository work under root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE). Both manifests are complete and local. Offline use
needs no PyRadiomics/NumPy, generated table, vendor primitive, external memory,
sibling source, download, submodule or network.
