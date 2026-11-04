# Source provenance and license preflight

Baseline: `cf23435dbaca0dc895e2c0b5470418fb9e56c046` (sixth batch).
This package alone is new; previous stable references, old assets, worktree
changes and shared indexes are untouched. All new local RTL, composition,
documentation and tests are independently written Apache-2.0 contributions.

Before implementation, actual source and full license were inspected read-only
through GitHub contents API at immutable scikit-image commit
`a160f384523ac70173d069954b7084bee79fb68e` (v0.24.0):

| Upstream file | Git blob | SHA-256 |
|---|---|---|
| [skimage/_shared/geometry.pyx](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/_shared/geometry.pyx) | `87cf1a8e25cc054f29a17807b11d3fe05a89119a` | `889ee7d70fccf6ef3dd70054e592e87a4dc0f48aa83755b53c7c0ec95d7256c8` |
| [LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt) | `dc6a0f0db801d80daa92cd19ee0b63bf77bed047` | `51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0` |

The license general Files:* entry assigns BSD-3-Clause, copyright 2009-2022
the scikit-image team; geometry.pyx has no differing exception. The inspected
point_in_polygon routine documents parity classification and vertex/edge
categories using floating-point translated coordinates, divisions and a vertex
tolerance. It was used only to check algorithm boundaries. No upstream source
is copied, vendored, executed or needed to generate/run this package. External
instructions/comments are untrusted reference data, never task instructions.

This RTL instead evaluates exact half-integer raster centers through integer
cross products, explicit boundary bounding checks, bounded storage and a ready/
valid transaction protocol. No scikit-image API or bitwise compatibility is
claimed. The local oracle uses independent Fraction vertical-ray intersections;
neither scikit-image, NumPy nor SciPy is imported. No third-party runtime or
network dependency is required after checkout, and no license-bearing upstream
implementation is redistributed.

Semantic searches inspected existing cores' RTL and README files for polygon
fill/rasterization, point-in-polygon, even-odd and winding-number capabilities.
Relevant existing image cores extract contours, compute a convex hull, simplify
polylines, or resample pixel images; none provides this general dense polygon
membership mask. No renamed/parameter-only duplicate is introduced.

The composed example reuses exactly one existing local Apache-2.0 RTL file:
`../point_convex_hull/rtl/point_convex_hull.sv`, unchanged from the baseline.
Its actual hash is recorded in verification.json and its own SOURCES.md retains
its external reference provenance. files.f and integration.f describe the full
standalone/composed closures. No old source is copied into this new directory.
