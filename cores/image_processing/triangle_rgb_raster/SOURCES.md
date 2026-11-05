# Provenance and functional deduplication

RTL, testbench, example and runner/reference are original ANSCORE Apache-2.0
code. No upstream implementation, dependency or generated table is imported.
The repository license is included locally. No external installer/build/test
was run. Python Fractions and all other test imports are standard-library only.

Read-only repository-wide searches and nearby source/contract inspection covered
common_scaffold/image, DSP/ISP, operator_library and video_compositor. Searches
for barycentric/Gouraud/triangle rasterization found no existing implementation.
`polygon_raster_mask` instead produces a complete binary parity mask with closed
boundary inclusion and no vertex-color interpolation. `bresenham_step` is a line
stepper. `sprite_blend` and `dual_osd_stream` composite already supplied pixels;
geometry samplers transform stored source images. `affine_ransac` uses triangles
only as correspondence triples, not rendering primitives. Reusing the mask then
adding a constant color would not provide this new interpolation capability.

Read-only upstream implementation/license review before authoring:

- [TinyRenderer our_gl.cpp](https://github.com/ssloy/tinyrenderer/blob/97eb7a480e762285899a93c5d21e70a79e60782e/our_gl.cpp),
  commit `97eb7a480e762285899a93c5d21e70a79e60782e`.
  Its rasterize routine demonstrates barycentric interpolation and bbox traversal.
  [Actual LICENSE.txt](https://github.com/ssloy/tinyrenderer/blob/97eb7a480e762285899a93c5d21e70a79e60782e/LICENSE.txt)
  was read: copyright Dmitry V. Sokolov, permissive use/modification/redistribution
  with origin/alteration/notice restrictions. GitHub labels it NOASSERTION;
  no SPDX license identifier is invented here. No source is copied. This core
  has exact pixel-center/top-left affine color semantics, rather than that
  renderer's floating-point perspective/depth/shader and backface-culling path.
- [Project F draw_triangle_fill.sv](https://github.com/projf/projf-explore/blob/dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708/lib/graphics/draw_triangle_fill.sv),
  commit `dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708`.
  [MIT license](https://github.com/projf/projf-explore/blob/dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708/LICENSE),
  copyright2023 Will Green, Project F, read before writing RTL. Its line-based
  flat fill helped assess an alternative architecture; no Bresenham source,
  module or interface is imported. The chosen edge-function architecture adds
  exact RGB weights and sparse ready/valid transaction ownership.

The upstream sources/licenses were read through direct HTTPS requests and fixed
commits resolved with GitHub's commits API. They are mathematical/architectural
references only, not test goldens or executed packages. Offline source and test
closure require none of these repositories.
