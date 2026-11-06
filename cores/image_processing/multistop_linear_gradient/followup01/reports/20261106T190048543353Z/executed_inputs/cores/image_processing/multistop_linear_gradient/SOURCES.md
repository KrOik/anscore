# Semantic and public-source review

Baseline05b9614c3962e9d4ae934c4b9c7bd315cc01aed4, source-only2026-11-07.
The B47 canonical411-source inventory and actual graphics RTL/examples were
read; B48 adds no gradient-paint function. `block_shi_tomasi` uses image spatial
derivatives, not gradient paint. `triangle_rgb_raster` interpolates affine RGB
on triangle coverage; `perspective_uv_projector` computes perspective UV;
`indexed_texture_sampler` does integer point lookup; `rgba_bilinear_coverage`
filters four texture texels; `rgba_porter_duff` combines already supplied paint;
`subpixel_rect_coverage` provides coverage and a constant-paint example. None
projects an arbitrary point onto runtime endpoints and searches multiple paint
stops with spread semantics. This new independent behavior is not a port/width
wrapper. Mature dependencies are referenced once at their canonical paths.

The primary behavior references were read with native HTTP only, without remote
code execution. The web search/open tool returned HTTP500. Pixman's upstream
returned an anti-bot challenge, so no Pixman implementation was reviewed or used.

* [W3C SVG2 paint servers](https://www.w3.org/TR/SVG2/pservers.html): linear
  endpoint geometry, pad/repeat/reflect, terminal color extension, duplicate
  stops and coincident-endpoint last-stop behavior.
* [W3C CSS Images3](https://www.w3.org/TR/css-images-3/#coloring-gradient-line):
  interpolation in premultiplied RGBA and duplicate-stop hard transitions.
* [Google Skia fixed commit](https://github.com/google/skia/tree/f533d40349006b96193948901fa9d1bffafe33fb),
  exact commit API and actual files read: LICENSE (BSD3-clause),
  `src/shaders/gradients/SkLinearGradient.cpp`,
  `src/shaders/gradients/SkGradientBaseShader.cpp`,
  `src/opts/SkRasterPipeline_opts.h`, `include/effects/SkGradient.h`.
  Linear endpoint-to-unit transform, stop interval handling, premultiplication
  option and floor-based repeat/mirror stages informed behavioral review.
  Skia is floating point and supports many color spaces/fixups; those algorithms
  and code are not translated or redistributed. In particular its degenerate
  repeating-gradient average differs from this explicitly selected last-stop
  policy, and this core rejects malformed stops instead of silently fixing them.

This package claims its documented integer policy, not full SVG/CSS/Skia
conformance. RNE byte quantization is an original exact arithmetic contract.
All new files are original Apache-2.0 contributions under the copied root
LICENSE. No external implementation source is required offline. The runner's
bounded child lifecycle reuses the workspace's reviewed direct-file pattern;
it neither imports nor launches another package's helper.

Dependencies are unchanged original Apache-2.0 workspace RTL: serial multiplier,
integer divider, synchronous single-port RAM and Porter-Duff. DEPENDENCY_PROOFS
binds each actual raw Git blob to the37021-path baseline tree capture. File
existence alone is not treated as baseline inclusion. No support bridge or
baseline normalization is introduced. Physical properties remain HW_UNVERIFIED.
