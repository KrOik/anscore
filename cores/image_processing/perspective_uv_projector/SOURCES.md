# Semantic prior art, external comparison and license boundaries

Repository semantic deduplication considered actual RTL/interfaces, not only names:

- `triangle_rgb_raster` supplies exact top-left coverage and Gouraud RGB, not
  reciprocal-W-correct UV. Its actual unchanged source is instantiated here.
- `indexed_texture_sampler` supplies runtime resident index/palette lookup.
  Its existing `indexed_triangle_frame` integration explicitly interpolates UV
  affinely. Its actual unchanged sampler RTL is instantiated here.
- `system/common_scaffold/image/geometry` performs full-frame inverse host-matrix
  projective warp and nearest/bilinear image sampling. It does not provide sparse
  triangle vertex reciprocal-W attribute interpolation.
- Existing four-plane/streaming lens shading, CLAHE, Retinex and frame-adaptive
  tone mapping were excluded as already implemented capability families.
- Whole-repository targeted searches for perspective-correct texture / reciprocal-W
  / u_over_w / v_over_w found no equivalent implementation (documentation mentions
  in affine sampler and unrelated registration material do not establish capability).

Primary external sources were fetched read-only over official GitHub API/raw URLs
because the web search backend returned HTTP500. No external repository was cloned
or executed. No GPL implementation source was copied or incorporated.

1. Project F `projf/projf-explore`, pinned commit
   `dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708`, MIT. The actual
   [draw_triangle_fill.sv](https://github.com/projf/projf-explore/blob/dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708/lib/graphics/draw_triangle_fill.sv)
   was read. It sorts vertices and drives edge/horizontal line engines to fill a
   triangle. This is a coverage architecture comparison; it does not implement
   perspective-correct UV. Fetched UTF8 source SHA256:
   `09cbf07f3e2acde7d7c179b71e7095420a21267d060f8b6d80b324112ff50f61`.
   [Pinned license](https://github.com/projf/projf-explore/blob/dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708/LICENSE).
2. RasterIX `ToNi3141/RasterIX`, pinned commit
   `3e2ee5aa5214b829c2a824250c445ce799ac8dc0`, GPL3-or-later per its
   [README](https://github.com/ToNi3141/RasterIX/blob/3e2ee5aa5214b829c2a824250c445ce799ac8dc0/README.md).
   Its README documents perspective-correct attribute interpolation and fixed/
   floating variants. This establishes the capability's practical rendering value;
   its broader3D renderer is not the architecture or source of this implementation.
   README fetched UTF8 SHA256:
   `feb2d18fea12fa258df2589cdb0a30ce34273720c2b56085758b2c04163f4dab`.
   [Pinned license](https://github.com/ToNi3141/RasterIX/blob/3e2ee5aa5214b829c2a824250c445ce799ac8dc0/LICENSE).

The new RTL and independent reference/TB are original Apache2 work. The execution
controller is adapted from the repository's Apache2 B44 tetrahedral package, with
new source/plan/gate/profile bindings and no inherited execution evidence. Only
unchanged local Apache2 raster/sampler RTL is composed. External comparisons are
documentary references, not dependencies. No external code adoption is necessary.
