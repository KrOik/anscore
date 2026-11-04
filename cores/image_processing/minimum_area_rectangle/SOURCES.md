# Provenance and independent design boundary

Baseline:897cf84f5861f5fada3c1a5d64127e64cdb9af92. This directory is new;
no old implementation, shared document or root license was changed.

Before RTL development, the complete following files were fetched read-only
from fixed OpenCV4.12.0 commit
`49486f61fb25722cbcf586b7f4320921d46fb38e` and actually read:

| File | Bytes | SHA256 |
|---|---:|---|
| modules/imgproc/src/rotcalipers.cpp |12956|bdc631e069f14836ddd5c811d56b0d7e71e8cb7383b4f272e87576d9ea9f65a0|
| LICENSE |11358|cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30|

Repository:https://github.com/opencv/opencv

Fixed source:https://github.com/opencv/opencv/blob/49486f61fb25722cbcf586b7f4320921d46fb38e/modules/imgproc/src/rotcalipers.cpp

Fixed license:https://github.com/opencv/opencv/blob/49486f61fb25722cbcf586b7f4320921d46fb38e/LICENSE

The repository LICENSE is the complete Apache License2.0. The selected source
also contains its own complete historical BSD-style Intel/OpenCV copyright,
redistribution terms and disclaimer; that source-specific header was read and
is not mislabeled as MIT or silently replaced by the repository license.
The source uses floating normalized hull-edge calipers, hull conversion,
square roots and angle conversion. Its wrappers and all functions in the file
were read. No upstream code, comment text, build script, headers, library,
binary, generated data or license text is copied/adapted/translated into this
package, imported, installed, persisted locally or executed. It is algorithmic
context only. External text was treated as untrusted data, not agent commands.

Local RTL is independently authored: exhaustive original point-pair directions,
exact unnormalized integer projections, a shared serial magnitude multiplier,
full cross products, bounded synchronous point RAM and ordinary ready/valid
ownership. It does not port floating rotating calipers or call a hull library.
The independent local oracle builds a monotone convex hull, minimizes rational
edge-aligned boxes, then resolves the explicitly documented input-order tie.
Generic Fraction Gaussian elimination audits corner/center reconstruction.
No OpenCV, NumPy, external geometry library or network access is needed offline.

Semantic deduplication covered actual point_convex_hull, minimum_enclosing_circle,
segment_box_clip, polygon_raster_mask, max_binary_rectangle and polyline_rdp
contracts and repository-wide production/README terms for minimum-area,
oriented/rotated bounding rectangles and minAreaRect. Hull boundary generation,
minimum enclosing circle, axis-aligned raster interior maximization and clipping
against a given rectangle do not implement the new oriented enclosing objective.
No existing package is linked or modified. No third-party runtime/HDL dependency
or adopted source requires an added third-party license file; root LICENSE and
NOTICE retain their exact bytes.
