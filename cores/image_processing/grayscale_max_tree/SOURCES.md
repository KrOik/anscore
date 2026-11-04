# B21 provenance, fixed reading and capability boundary

Actual initial HEAD was `ed4eda4fe213da6f6fec793ef911daaabfeba2cc` before any
package file was created. Only this new package is owned by Worker C. Shared
indices, manifests, refs, old packages and root LICENSE/NOTICE remain untouched.
The first local file was `.gitattributes`; all final text assets use UTF8/LF.

Whole-repository production RTL/README searches covered max-tree, min-tree,
component tree, upper-level components, MSER/extremal regions and hierarchical
merging, including Chinese equivalents. Matches were prior area-opening
provenance, descriptive exclusions, and unrelated arithmetic min/max trees.
Actual README contracts and production ports for grayscale_area_opening,
grayscale_size_zone and binary connected_components were inspected. Watershed
and label_region_adjacency contracts were read too. Area opening emits one
area-threshold-filtered raster and explicitly has no tree; GLSZM counts equal-gray
zones; binary CCL produces one foreground partition; watershed assigns seeds;
RAG emits contact edges and explicitly does not merge regions. None preserves
the complete cross-threshold parent relation or every upper-component area.
This is a new hierarchy representation, not a width/connectivity variant of
those services. No old function or source is replaced or linked.

## Complete upstream source and license inspected read-only

Repository: https://github.com/scikit-image/scikit-image

Annotated v0.24.0 tag `8be71b82137046719f8e0f70632745f883d72586` was dereferenced
using the GitHub git/tags API to fixed commit
`a160f384523ac70173d069954b7084bee79fb68e`.

|Complete file fetched and read|Bytes|SHA256|
|---|---:|---|
|[max_tree.py](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/morphology/max_tree.py)|26983|ed9842dc253e2f8fc64eae3277f9b02cf582d71c3bfae4ff9468b9c12f3a8674|
|[_max_tree.pyx](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/morphology/_max_tree.pyx)|16372|8d7a4c96bd9c1146c58d63594b4273a3359e38c05a0d6c4995449f6e69dfea50|
|[LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt)|6553|51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0|

All bytes were fetched into memory, strictly UTF8 decoded and displayed in full;
truncated combined output was reread in bounded chunks. Reading included all
max-tree generation, find_root/recursive alternative, canonization, offset and
neighbor helpers, area/extension accumulation, direct filters, maxima, area/
diameter opening/closing wrappers and the complete multi-license file. No
upstream file was persisted, imported, compiled or executed. Root independently
read these same fixed sources/license before HDL qualification.

The applicable general file license is BSD-3-Clause, copyright2009-2022 the
scikit-image team. The full file also lists BSD-2-Clause and MIT terms for other
specified repository files/functions; all were read. The inspected max-tree
files are not among those exceptions. This package does not copy, translate,
adapt or incorporate upstream code, comments, tests or license text. It uses
public component-tree concepts with independently authored bounded hardware,
BFM and a different threshold-set oracle under repository Apache-2.0. No adopted
third-party code needs a local license copy. Root LICENSE/NOTICE retain their
raw bytes, including their existing line endings.

The upstream implementation uses NumPy stable argsort and Cython arrays, followed
by forest construction and canonization. The local architecture uses its own
bounded counting-sort schedule, six clocked single-port RAMs, explicit ownership,
scheduled path-halving reads/writes, full-frame transaction rejection and dense
tree/area records. Upstream canonical numbering is not used as the oracle;
README's minimum-raster representative and threshold-inclusion contract define
local results. No external helper/array implementation is a runtime dependency.

The independent oracle explicitly discovers every upper-level connected set,
chooses same-level minimum representatives and searches strict-containing sets
for parents. Complete threshold partitions, root and areas are certified without
the RTL's sorted activation/union-find recurrence. A separate architecture-only
work calculation sized reset child groups before first HDL and produced no
golden tree/area data. No synthesis, PnR, STA, board, inherited or expanded check
is part of this package's workflow.
