# C16 pre-RTL semantic, implementation and full-license preflight

Baseline `83b11ea30d4762c5893cf37a8303b11706321876`,2026-11-05. The actual60-package
B15 inventory was read, and production RTL/README/SPEC searches for Hausdorff,
max-min shape distance, Frechet and related geometry capabilities found no
Hausdorff service. Actual `polyline_rdp/README.md` explicitly disclaims a reverse
Hausdorff bound. The complete existing `chamfer_match` contract and relevant RTL
were read: translated directed mean squared template distance is a different
service from symmetric worst-case distance of two complete masks.

## Original repository dependency inspected before wrapper RTL

The complete existing `euclidean_distance.sv` and README were read. It computes
exact squared distance to zero-valued features and deterministic nearest feature
coordinates through separable horizontal/vertical min-plus scans. It has CE-
qualified transfers, synchronous RAMs, no outside features and distinct held
output/completion phases. Its RTL is reused unchanged, with child CE tied high,
regenerated correct markers and wrapper-controlled reset. External transfers
are ordinary ready/valid with synchronous active-high reset, not CE-qualified.

Dependency path: `../../system/common_scaffold/image/euclidean_distance/euclidean_distance.sv`
relative to this package. Its actual baseline/current raw bytes are identical:
4573bytes, SHA256 `9cea7d0c75895d9de8dea10428f9f1f496ab9536fb2dcb5732b5ee3adebe6888`.
Baseline Git blob is `1ad440ee42ae4eca3a5313c50f89aada7da20c1f`.
The dependency README is5759bytes, blob
`e557ead17586dee353af1e2c7d048fba09768c84`, SHA256
`5136f4aa1443844c7cd5020e8d5cfc820d7c8aa8d05a7059ec30e7e3e464c6ae`.
Both files last changed at repository commit
`430d42049006976683550ecec321a724ef5cea3d`; their baseline/current bytes are
identical strict UTF8/LF and require no normalization. Both are explicit offline
support exports, with no historical evidence files required by this package.
It is repository-original code under root Apache-2.0 LICENSE/NOTICE, not newly
downloaded third-party code. No inherited source is edited or promoted to new
validation scope; only this wrapper's frozen composition receives finite checks.

## Actual fixed upstream Hausdorff implementation and complete license

Before local RTL, GitHub contents-API responses at SciPy fixed commit
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a` were decoded as strict UTF8 and read
in full, using15-second HTTPS limits. No retrieved code was executed.

| Actual file | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | `117117616e806a9bb960b1f32a552c8c912b0497` |1536| `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/spatial/_hausdorff.pyx](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/spatial/_hausdorff.pyx) | `d6858beaebd05922cffbc75bc1e640cbd16c0ebb` |2253| `df44afb058d020ba9c4a5b422f6b41ede725e75ec7247305ccd74e1d69d51138` |

The complete BSD3 license names Enthought and SciPy Developers and includes all
three source/binary/name conditions plus the full warranty/liability disclaimer.
The actual Cython implementation additionally names Tyler Reddy, Richard Gowers
and Max Linke,2016. Its complete `directed_hausdorff` shuffles both point sets,
searches squared pair distances with early exits, then returns a square root and
point indices. Local hardware instead serially reuses an exact EDT twice and
reduces selected mask locations. The result is symmetric squared distance plus
both directed witnesses, with deterministic raster tie rules. No random state,
floating-point scalar, SciPy index/tie/API or empty-input compatibility is claimed.

No upstream source/comments/tests/license text/build code was copied, adapted,
translated, imported, executed or persisted. Reference bytes were read-only.
The new wrapper, TB, oracle and prose are original repository Apache-2.0 work.
Offline use needs only the manifested existing RTL, Python standard library and
repository-native Icarus/vvp; no network, NumPy/SciPy, ROM or external RAM.
