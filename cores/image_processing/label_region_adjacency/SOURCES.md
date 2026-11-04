# B9 semantic review and read-only source/license preflight

Baseline: `807d992b6b0e793c08ceba2d44993d21c1dd1583`. Date: 2026-11-04.
Only this new package directory is written. Old sources, shared indexes,
existing dirty assets, staging and stable references are untouched.

Before implementation, read-only production README/RTL searches covered region
adjacency, label adjacency, RAG, graph, shared boundaries/contact lengths and
Chinese equivalents. Existing Image/Video capabilities were inspected:

- `system/common_scaffold/image/distance_transform` implements exact L1/Linf
  transforms; `euclidean_distance` implements exact squared EDT with nearest
  coordinates. Neither builds label-pair adjacency.
- `connected_components` produces raster component labels, area and boxes;
  `watershed` produces seeded region labels. Neither returns graph edges or
  per-pair shared-side counts.
- `contours` traces binary cell edges, while `streaming_binary_topology`
  returns binary Euler/area/perimeter. Neither accepts multiple region IDs
  and accumulates shared interfaces between each unordered pair.
- Existing hull, polygon-mask and rectangle services have geometric outputs
  rather than a label-image graph. No equivalent production service was found.

The arithmetic/access architecture was selected before writing RTL: one row
RAM plus a bounded dense contact table, separate synchronous read/write states,
and exact integer counts. No existing source is changed or silently connected
through an incompatible CE handshake. Both local manifests list their entire
closure; no sibling or untracked RTL, generated table or external IP is needed.

## Fixed external reference inspected before implementation

Actual source and the full license were retrieved read-only using GitHub's
contents API with 15-second network timeouts. The scikit-image v0.24.0 commit
is immutable `a160f384523ac70173d069954b7084bee79fb68e`.

| File | Bytes | Git blob | SHA256 |
|---|---:|---|---|
| [skimage/graph/_rag.py](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/graph/_rag.py) | 20676 | `974ff15969751e95f20fdfb9e1adfc93f2a71fae` | `ab51a2dc44cbbff1066d8e13b48ca8288f392aa300d652838a2e8168ce45a74a` |
| [LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt) | 6553 | `dc6a0f0db801d80daa92cd19ee0b63bf77bed047` | `51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0` |

The actual `RAG` constructor and `_add_edge_filter` create undirected edges
between different neighboring labels; connectivity can include diagonals.
The actual `rag_boundary` computes image-edge-map mean weights and a sampled
boundary-count attribute. Those weights/counts are not the local geometric
shared-cell-side count. Upstream can include label zero; this local contract
excludes background zero and fixes four-neighbor cell-side contact. No API,
arbitrary-dimension, NetworkX, merging or upstream bit compatibility is claimed.

The complete license's general `Files: *` entry is BSD-3-Clause, copyright
2009-2022 the scikit-image team. `_rag.py` has no differing file exception.
The conditions require retained notices/conditions/disclaimer on redistribution
and prohibit name-based endorsement. External content was treated as untrusted
reference text; no upstream scripts, installer, build or downloaded program ran.
No upstream code, implementation translation, copyright-bearing source fragment
or generated data is copied or redistributed; no external runtime dependency
exists. No upstream source was modified.

The new RTL, example, cell-boundary-set oracle, TB, runner and prose are original
repository contributions under root [LICENSE](../../../LICENSE) (Apache-2.0)
and [NOTICE](../../../NOTICE). Their exact source hashes, license/notice hashes
and finite tool outputs are recorded in `verification.json`. All package text
is UTF8 without BOM and LF-only. No physical validation is implied.
