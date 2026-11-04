# C11 semantic and fixed-source preflight — 2026-11-04

Baseline: `c778301aa12d1b9bf4290b1a982f4c6325713fcd`.
The numerical/interface/resource proposal and actual external-source reading
preceded new RTL. Only this private package is edited.

Repository-wide RTL/README/SPEC searches covered area opening/closing,
component tree, max-tree/min-tree, attribute filtering, 面积开/闭 and 连通面积.
No equivalent grayscale connected-area image filter was found. Actual neighboring
READMEs and source boundaries were inspected. Existing binary CCA labels a
single thresholded mask and reports area/bboxes; it does not produce the
gray-level connected opening. Grayscale reconstruction consumes a marker and
mask under an iteration limit, with no area attribute. Fixed-footprint morphology,
hole filling, watershed and thinning have different mathematical outputs.
Reusing the old CCA would require a new frame-level threshold/replay coordinator,
its label/stat protocol and component capacity, rather than a width/ABI adapter.
This bounded serial design directly preserves a component's member queue for
area-qualified replay and needs no label table or component-budget failure.

## Actual immutable source and complete license

Read-only GitHub contents API requests resolved scikit-image v0.24.0's annotated
tag `8be71b82137046719f8e0f70632745f883d72586` to immutable commit
`a160f384523ac70173d069954b7084bee79fb68e`.
Complete source bytes were decoded and read, including actual `_compute_area`,
`_direct_filter` and `_max_tree` bodies, and the complete license was read.

| File at that commit | Bytes | SHA256 |
| --- | ---: | --- |
| [LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt) | 6553 | `51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0` |
| [max_tree.py](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/morphology/max_tree.py) | 26983 | `ed9842dc253e2f8fc64eae3277f9b02cf582d71c3bfae4ff9468b9c12f3a8674` |
| [_max_tree.pyx](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/morphology/_max_tree.pyx) | 16372 | `8d7a4c96bd9c1146c58d63594b4273a3359e38c05a0d6c4995449f6e69dfea50` |

Git blob IDs are respectively `dc6a0f0db801d80daa92cd19ee0b63bf77bed047`,
`d385b0e4d13c4e570d928371665864939d1dfa03` and
`0850774be961158956fa1ad855e2e457f07e7101`.
The complete license includes file-specific BSD2/MIT exceptions; these two
morphology source files fall under its default BSD-3-Clause, copyright
2009–2022 the scikit-image team. BSD3 requires retained notices/conditions and
disclaimer and prohibits endorsement without permission. No exception source
was adopted.

The reference describes gray-level area opening as connected bright-component
filtering across upper-level sets, area 1 identity, and 4/8 connectivity. Its
implementation computes a sorted max-tree, accumulates areas and propagates
parent levels. This RTL independently enumerates occupied positive thresholds,
uses a FIFO flood and replays qualified members. The independent local oracle
uses descending pixel activation with disjoint sets and unresolved membership.
Neither copies the upstream max-tree implementation, helper code or tests.

The web-search tool returned a service HTTP500; Python HTTPS encountered TLS
EOF; a bounded raw URL request also failed. Bounded curl contents-API requests
succeeded and supplied the actual bytes above. A first Cython body-extraction
attempt used the wrong `def` prefix (`cpdef` was actual); the subsequent complete
body read succeeded. No external Python/Cython was imported or executed; no
remote installer/build ran. Each network request was bounded to 15 seconds
and each child to 20 seconds. Reference bytes stayed in process memory; no
downloaded source is retained in the package.

All new RTL, wrapper, TB, oracle, runner and prose are original Apache-2.0
repository work under root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE). Both manifests contain only local authored RTL;
there are no old/sibling or third-party runtime dependencies, generated
tables, external RAM interfaces, vendor primitives or network requirements.
