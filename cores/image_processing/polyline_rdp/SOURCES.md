# Source and license preflight

Baseline: `cf9b62d545d5e741589daf1fe99c6533f3148316` (fifth batch).
Only this new package is changed. Existing assets and shared indexes remain
untouched. All local RTL, frontend, documentation and finite tests are original
Apache-2.0 ANSCORE contributions. No third-party source is copied or executed.

Before implementation, the following actual upstream blobs and full license
were inspected read-only using GitHub HTTPS API/raw downloads. The annotated
v0.24.0 tag resolves to immutable commit
`a160f384523ac70173d069954b7084bee79fb68e` in
[scikit-image/scikit-image](https://github.com/scikit-image/scikit-image).

| File at fixed commit | Git blob | SHA-256 |
|---|---|---|
| [skimage/measure/_polygon.py](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/measure/_polygon.py) | `23aa1cea463226d06ab91f9ef602032bbcf8eead` | `26a27d89545d158f6b542857297995639b251ed3af0428c8c86a56c84928aabe` |
| [LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt) | `dc6a0f0db801d80daa92cd19ee0b63bf77bed047` | `51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0` |

The license's general `Files: *` entry assigns BSD-3-Clause and copyright
2009-2022 the scikit-image team. `_polygon.py` has no differing file exception.
Its `approximate_polygon` establishes the RDP algorithm reference, finite-segment
projection distinction, endpoint handling and first-maximum selection. The
upstream Python implementation depends on NumPy/SciPy and uses floating-point
trigonometry/distances. No upstream Python, dependency or build process is run,
vendored, needed to generate this RTL, or needed at offline runtime.

This independent integer hardware uses exact squared rational comparisons,
bounded storage, explicit stream framing/masking/overflow and a shared multiplier.
Unlike upstream, epsilon zero still simplifies redundant collinear vertices.
No bitwise/API compatibility with scikit-image is claimed. The local oracle is
independent recursive Fraction point-to-segment computation and does not import
scikit-image. External README/comments were treated only as untrusted reference
data, never instructions. No network access is used by `run_tests.py`.

Semantic deduplication inspected existing image capability directories and RTL/
README searches for Ramer/Douglas/Peucker/polyline/polygon/distance transform.
Relevant neighboring capabilities are `cores/image_processing/point_convex_hull`,
`cores/system/common_scaffold/image/contours`, `.../geometry`,
`.../distance_transform`, and `.../euclidean_distance`. None provides ordered
epsilon-bounded finite-segment polyline simplification; no width-only variant
or renamed duplicate is introduced. No sibling RTL dependency is required.
