# Read-only upstream and independent implementation

Baseline:20e2db4aded8858ff63e132c2399fb416aa48ed0. Before any new RTL,
565 actual cores README files (2,941,466 UTF-8 bytes) were read in memory.
Repository-wide RTL/manifest/document content searches for Delaunay, incircle,
Bowyer, Voronoi, regular triangulation and circumcircle found no equivalent
point-set mesh. Actual point_convex_hull, polygon_triangulation,
minimum_enclosing_circle, minimum_area_rectangle, contours and affine_ransac
ports/transfer logic were also read. Their distinct domain/CE contracts are
recorded in README. No old module was modified or used as an implicit dependency.

The web search tool returned HTTP500. Read-only urllib HTTPS requests fetched
the following pinned files entirely into memory. Every line and the complete
licenses were read. No upstream source was imported, executed, copied or adapted;
there is no JavaScript/npm or remote dependency in this package.

Mapbox Delaunator v5.0.1 annotated tag
f1ac0bda002bb48741ffaf1a0e38f205016c1eec resolves to commit
80ac079775bbe52ffec51df1394561d0e6e6e4a9.
Repository:https://github.com/mapbox/delaunator
Pinned prefix:https://raw.githubusercontent.com/mapbox/delaunator/80ac079775bbe52ffec51df1394561d0e6e6e4a9/

| File | Bytes/lines | Raw SHA256 |
|---|---:|---|
| index.js |15619/480|57a4c5343fdcddde0ac08e5aa7092ced682e2d47e7fbdc402c5228e7ab343e82|
| LICENSE |738/15|b8878372a0d7d1c303f48659ddbd6881807cd2196e4af2f548d8da0c0f7c4d71|
| package.json |1428/56|bdd80fc63ad51184f827d4eb3134b1a960d8d64f9e9935b79707e6f04d4a7f38|

LICENSE is ISC, Copyright(c)2021 Mapbox. The complete permission, retention and
disclaimer clauses were read. Delaunator uses floating coordinates, seed-circle
distance sorting, an advancing hashed hull, half-edge topology and flips with a
fixed512-entry stack. Its local inCircle is floating point; robust-predicates
supplies orient2d. These algorithms and error/tie contracts are not copied here.
It is a technical reference, not this package's exact acceptance oracle.

The declared robust-predicates ^3.0.2 dependency was independently pinned to
v3.0.2 annotated tag1f0ddc03074ee84d002cc716544ed08cdc1b5195, resolving to
c20b0ab9ab4c4f2969f3611908c41ce76aa0e7a7.
Repository:https://github.com/mourner/robust-predicates
Pinned prefix:https://raw.githubusercontent.com/mourner/robust-predicates/c20b0ab9ab4c4f2969f3611908c41ce76aa0e7a7/

| File | Bytes/lines | Raw SHA256 |
|---|---:|---|
| src/orient2d.js |2061/68|806986734f5596f83c90ef8099562a4e63a11a7a38ee8fb7534cd41aa258071c|
| src/util.js |2934/115|2c4222782f88ec5df3bcf91dcd3be3505ad60d4f80e908d7e6b60a170fae1a38|
| compile.js |3355/99|9f16a0de8c0e931bb412f8e35337e795f736d90a82f26c906408fc666f2132b2|
| index.js |233/5|1e26fb2e616a0fa84dadb3a15633d9743671884d82f1abb124e20292fd0ab86d|
| package.json |1848/75|4b61e3f7305941b4adf95c4cc11d2a502380e3dd9f4c731fd1610a6fd2d9370b|
| LICENSE |1210/24|88d9b4eb60579c191ec391ca04c16130572d7eedc4a86daa58bf28c6e14c9bcd|

The full Unlicense/public-domain dedication, fallback terms and disclaimer were
read. The complete relevant orientation, arithmetic utilities and macro
definitions were read; compile.js was never executed. The package index was
read to verify the orientation entry path; unrelated orient3d/insphere routines
are not required by Delaunator and were not adopted.

This package independently implements bounded exhaustive exact empty-circle
facets and one global negative symbolic-height perturbation, using one shared
registered signed integer multiplier and three clocked banks. The independent
standard-library Fraction oracle groups exact circles and fans boundary rings.
Before freezing,1557 in-memory mathematical point-set probes independently
compared these constructions, including all3x3 subsets in three input orders,
full16-point grids, cocircular and signed-extreme random clouds. That research
was not HDL validation and generated no repository files. The formal finite
HDL matrix and all complete golden records are independently frozen in MATRIX.

All locally authored RTL, reference, TB, runner and documentation use the root
Apache-2.0 license. Root LICENSE and NOTICE are unchanged. No third-party source
or runtime dependency is distributed. files.f and example/files.f are complete
offline production closures, without vendor primitives, ROM data or generators.
