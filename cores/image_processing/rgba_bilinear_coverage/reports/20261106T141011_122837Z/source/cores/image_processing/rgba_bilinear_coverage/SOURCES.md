# Source selection and semantic boundaries

Baseline `50b8d36a3ce65cae5c4b3ab4604fa24f3567204b`. Canonical and legacy
RTL/document searches across cores and docs checked bilinear, texture,
premultiplication, alpha-coupled filtering and subtexel semantics; report,
history, failure archives and generated images were excluded from capability
counting. Actual relevant implementations were read, rather than relying on
module names.

| Existing asset | Actual behavior and relation |
| --- | --- |
| indexed_texture_sampler | Runtime index/palette resident banks, integer point texel coordinates, straight ARGB result; reused unchanged for four dependent accesses. |
| rgba_porter_duff | Premultiplied paired composition with errors and exact /255; reused unchanged after filtering. No neighbor sampling or interpolation. |
| cip_image_scaler / FUNCTIONAL_IMAGE_ABI.md | Packed independent channels, full-frame capture/replay, CE-qualified, Q8 bilinear half-up. It has no alpha×color weighting or straight-to-premultiplied fused quantization. |
| rgba_sprite_blit | Integer rectangle traversal/flips and straight-alpha store path. No fractional UV or filtering. |
| perspective_uv_projector | Exact perspective-correct integer UV; its quantization removes subtexel fractions. No extension or modification is claimed. |
| fragment_rgb_depth_store | Straight-alpha ordered fragment updates and RGB/Z storage, no four-texel alpha-aware filter. |

Official Google Skia repository was inspected read-only at pinned commit
`e46e225442e884b537ea53ed72b11f7631399897`:
[sampling source](https://github.com/google/skia/blob/e46e225442e884b537ea53ed72b11f7631399897/src/opts/SkBitmapProcState_opts.h)
and [full license](https://github.com/google/skia/blob/e46e225442e884b537ea53ed72b11f7631399897/LICENSE).
The actual source contains four-neighbor interpolation of premultiplied
SkPMColor with four-bit coordinate weights and truncation. This informs the
sampling/coverage boundary only. Our eight-bit weights, fused straight-input
alpha products and final RNE are independently specified and implemented;
no Skia bit-exact equivalence is claimed. The full license is BSD-3-Clause.
No upstream implementation, generated data, include, import or runtime
dependency is copied, translated or executed. New package code is Apache-2.0.

Primary-source search/open tools returned HTTP500; direct official GitHub
HTTPS metadata and pinned raw source/license reads supplied the inspection.
An obsolete proposed sample-header path returned404 and is not cited as read.
No third-party source mirror or upstream program was used for the design.
