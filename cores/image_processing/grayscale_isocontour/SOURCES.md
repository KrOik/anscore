# Original implementation and fixed read-only technical preflight

Repository baseline: `b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333`.
All local RTL, wrapper, fixtures, oracle, TB and runner are independently authored.
Root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE) apply. No upstream
source, script or runtime dependency is copied, adapted, imported or executed.
The following complete relevant files were fetched into memory, fully read and
hashed over HTTPS before implementation. Network access is not required to use
or check the delivered core and frozen fixtures.

## scikit-image reference

Repository: https://github.com/scikit-image/scikit-image

Annotated release tag v0.24.0 has tag object
`8be71b82137046719f8e0f70632745f883d72586`, resolving to commit
`a160f384523ac70173d069954b7084bee79fb68e`. The tag/commit relation was obtained
read-only through the GitHub API; no checkout/install/build was performed.

|Complete pinned file|Bytes|Lines|SHA256|
|---|---:|---:|---|
|[skimage/measure/_find_contours.py](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/measure/_find_contours.py)|9585|218|f5747669288df6f9745a9680d2cd7d1f33f471b88ac5dd73be0ed06a1b7e23a3|
|[skimage/measure/_find_contours_cy.pyx](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/measure/_find_contours_cy.pyx)|6681|161|76419ca0a62fde277376a1fa9f12b04a59c03e5e8c1372dc782fc31517262a34|
|[LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt)|6553|156|51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0|

The root license's wildcard covers these contour files under BSD-3-Clause,
copyright2009-2022 the scikit-image team; its entire license and exceptions were
read. Reading alone does not create a copied-source dependency. If these files
were redistributed in a future derivative, their original notice, conditions
and disclaimer would have to be retained. No such derivative is delivered here.

`_find_contours.py` validates image/configuration, calls the complete Cython
segment kernel, assembles directed float-coordinate segments into ordered
contours and optionally reverses orientation. The kernel walks2x2 samples,
linearly interpolates float64 endpoints, skips masks/NaNs and resolves both
alternating cases with a fixed `vertex_connect_high` configuration. Its local
dependency closure is the wrapper/kernel pair, NumPy/Cython and standard-library
collections; no additional local contour helper is called. Complete reading,
not excerpts or a README alone, established this boundary.

The reference supports the sampled-grid/marching-squares distinction from
binary unit-cell borders. It does **not** implement our magnitude-dependent exact
asymptotic decider, half-level domain, rational encoding, global saddle tie,
RV ownership, summary framing or bounded hardware schedule. Those rules are
derived explicitly in README.md. It is not used as the numerical oracle.

## Actual semantic deduplication and adjacent contracts

Before selecting this direction, all570 actual `cores/**/README.md` documents
(2,994,694 UTF-8 bytes, including the retained B23 failed-attempt archive) were
read, and actual cores RTL/manifests/docs were searched for marching squares,
isocontour/iso-contour, asymptotic decider, bilinear contour and level-set terms.
No equivalent scalar-grid rational contour-graph implementation was found.

The full existing `system/common_scaffold/image/contours/README.md` and actual
`contours_cell_edges.v` interface were inspected. That core takes binary unit
cells, constructs exposed integer lattice edges, emits globally ordered directed
loops with area/hole information, uses CE-qualified transfers and an independent
held DONE channel, and explicitly excludes marching squares. It cannot obtain
gray-level crossings or magnitude-dependent saddle connectivity from its binary
input. The new core supplies those independent capabilities without modifying it.

The complete `grayscale_max_tree` and `grayscale_area_opening` READMEs and actual
RTL ports/declarations were read. The former emits an upper-component hierarchy
and areas; the latter emits a4-connected area-filtered grayscale raster. Neither
emits rational crossings or bilinear branch connectivity. Both use ordinary RV
fixed-raster ownership and first-tag capture. Area-opening's raster may feed
this core through explicit level supply and error-vector reduction; old CE
streams need an adapter. No sibling source is required, changed or inherited as
qualification evidence.
